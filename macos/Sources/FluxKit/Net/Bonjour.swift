import dnssd
import Foundation

/// mDNS through Bonjour. fluxd announces _flux._udp.
/// This device announces itself the same way, so that a computer that blocks
/// incoming connections finds it and connects. A found host gets a unicast
/// identity, and the host then connects.
///
/// The C callbacks get this object unretained. The owner calls `stop`
/// before it drops the object, and `deinit` ends every service that is
/// left, on the queue of the callbacks, so that no callback outlives it.
public final class Bonjour: @unchecked Sendable {
    static let serviceType = "_flux._udp"
    /// The most lookups that run at the same time.
    static let maxLookups = 16

    private let queue = DispatchQueue(label: "org.omarchy.flux.bonjour")
    /// Marks the queue, so that deinit knows when it runs on it.
    private let onQueue = DispatchSpecificKey<Bool>()
    private var registration: DNSServiceRef?
    private var browser: DNSServiceRef?
    private var resolving: [DNSServiceRef] = []
    /// The service names that the current browse resolved, each once.
    private var resolved: Set<String> = []
    /// True after the current browse reported that the local network is
    /// not allowed, until it finds a service.
    private var browseDenied = false
    private let selfId: String
    private let found: @Sendable (String) -> Void
    private let denied: @Sendable (Bool) -> Void

    /// found receives the IPv4 address of each desktop that the browser
    /// resolves. denied receives true when the user did not allow access
    /// to the local network, and false when the browse works.
    public init(selfId: String, found: @escaping @Sendable (String) -> Void, denied: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.selfId = selfId
        self.found = found
        self.denied = denied
        queue.setSpecific(key: onQueue, value: true)
    }

    deinit {
        if DispatchQueue.getSpecific(key: onQueue) == true {
            endAll()
        } else {
            queue.sync { endAll() }
        }
    }

    /// Announces this device. The service name is the device ID. The port is the TCP link port.
    public func publish(name: String, type: String, port: Int) {
        queue.async { [self] in
            if let r = registration { DNSServiceRefDeallocate(r); registration = nil }
            var txt = TXTRecordRef()
            TXTRecordCreate(&txt, 0, nil)
            defer { TXTRecordDeallocate(&txt) }
            for (k, v) in [("id", selfId), ("name", name), ("type", type), ("protocol", String(protocolVersion))] {
                let bytes = Array(v.utf8)
                TXTRecordSetValue(&txt, k, UInt8(bytes.count), bytes)
            }
            var ref: DNSServiceRef?
            let err = DNSServiceRegister(
                &ref, 0, 0, selfId, Self.serviceType, nil, nil, UInt16(port).bigEndian,
                TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), nil, nil
            )
            guard err == kDNSServiceErr_NoError, let ref else {
                FluxLog.net.warning("Bonjour register failed: \(err)")
                if err == kDNSServiceErr_PolicyDenied { denied(true) }
                return
            }
            DNSServiceSetDispatchQueue(ref, queue)
            registration = ref
        }
    }

    /// Browses for desktops. While a browse runs, it reports its denied
    /// state again, so that the owner can clear the state before each call.
    public func browse() {
        queue.async { [self] in
            guard browser == nil else {
                if browseDenied { denied(true) }
                return
            }
            browseDenied = false
            var ref: DNSServiceRef?
            let context = Unmanaged.passUnretained(self).toOpaque()
            let err = DNSServiceBrowse(&ref, 0, 0, Self.serviceType, nil, { _, flags, iface, err, name, type, domain, ctx in
                guard let ctx else { return }
                let me = Unmanaged<Bonjour>.fromOpaque(ctx).takeUnretainedValue()
                // iOS and macOS report a denied Local Network permission here.
                if err == kDNSServiceErr_PolicyDenied {
                    me.browseDenied = true
                    me.denied(true)
                    return
                }
                guard err == kDNSServiceErr_NoError, flags & kDNSServiceFlagsAdd != 0,
                      let name, let type, let domain else { return }
                me.browseDenied = false
                me.denied(false)
                me.resolve(name: String(cString: name), type: String(cString: type), domain: String(cString: domain), iface: iface)
            }, context)
            guard err == kDNSServiceErr_NoError, let ref else {
                FluxLog.net.warning("Bonjour browse failed: \(err)")
                if err == kDNSServiceErr_PolicyDenied { denied(true) }
                return
            }
            DNSServiceSetDispatchQueue(ref, queue)
            browser = ref
        }
    }

    /// Ends the browse and the lookups that it started. The service of this
    /// device stays, so that computers still find it.
    public func stopBrowsing() {
        queue.sync {
            if let b = browser { DNSServiceRefDeallocate(b) }
            resolving.forEach { DNSServiceRefDeallocate($0) }
            browser = nil
            browseDenied = false
            resolving = []
            resolved = []
        }
    }

    /// Ends the service of this device, the browse, and the lookups.
    public func stop() {
        queue.sync { endAll() }
    }

    /// Ends every service. It runs on the queue.
    private func endAll() {
        if let r = registration { DNSServiceRefDeallocate(r) }
        if let b = browser { DNSServiceRefDeallocate(b) }
        resolving.forEach { DNSServiceRefDeallocate($0) }
        registration = nil
        browser = nil
        browseDenied = false
        resolving = []
        resolved = []
    }

    private func finish(_ ref: DNSServiceRef?) {
        guard let ref, let i = resolving.firstIndex(of: ref) else { return }
        resolving.remove(at: i)
        DNSServiceRefDeallocate(ref)
    }

    private func resolve(name: String, type: String, domain: String, iface: UInt32) {
        // A name that comes again, for example on each interface, needs no
        // new lookup, and a flood of names cannot open a socket each.
        guard name != selfId, !resolved.contains(name), resolving.count < Self.maxLookups else { return }
        resolved.insert(name)
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let err = DNSServiceResolve(&ref, 0, iface, name, type, domain, { sdRef, _, iface, err, _, host, _, _, _, ctx in
            guard let ctx else { return }
            let me = Unmanaged<Bonjour>.fromOpaque(ctx).takeUnretainedValue()
            // The ref owns the host text, so it is copied first. The resolve
            // then ends, so that its lookup fits in the limit.
            let hostName = err == kDNSServiceErr_NoError ? host.map { String(cString: $0) } : nil
            me.finish(sdRef)
            guard let hostName else { return }
            me.lookup(host: hostName, iface: iface)
        }, context)
        guard err == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        resolving.append(ref)
    }

    private func lookup(host: String, iface: UInt32) {
        guard resolving.count < Self.maxLookups else { return }
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let err = DNSServiceGetAddrInfo(&ref, 0, iface, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host, { sdRef, flags, _, err, _, addr, _, ctx in
            guard let ctx else { return }
            let me = Unmanaged<Bonjour>.fromOpaque(ctx).takeUnretainedValue()
            if flags & kDNSServiceFlagsMoreComing == 0 { me.finish(sdRef) }
            guard err == kDNSServiceErr_NoError, let addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { return }
            var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count)) != nil else { return }
            let ip = String(cString: buf)
            if ip.hasPrefix("127.") { return }
            me.found(ip)
        }, context)
        guard err == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        resolving.append(ref)
    }
}
