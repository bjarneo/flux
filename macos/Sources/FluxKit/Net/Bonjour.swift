import dnssd
import Foundation

/// mDNS through Bonjour. KDE Connect desktops announce _kdeconnect._udp.
/// This device announces itself the same way, so that a computer that blocks
/// incoming connections finds it and connects. A found host gets a unicast
/// identity, and the host then connects.
public final class Bonjour: @unchecked Sendable {
    static let serviceType = "_kdeconnect._udp"

    private let queue = DispatchQueue(label: "org.omarchy.flux.bonjour")
    private var registration: DNSServiceRef?
    private var browser: DNSServiceRef?
    private var resolving: [DNSServiceRef] = []
    private let selfId: String
    private let found: @Sendable (String) -> Void

    /// found receives the IPv4 address of each desktop that the browser resolves.
    public init(selfId: String, found: @escaping @Sendable (String) -> Void) {
        self.selfId = selfId
        self.found = found
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
                return
            }
            DNSServiceSetDispatchQueue(ref, queue)
            registration = ref
        }
    }

    /// Browses for desktops.
    public func browse() {
        queue.async { [self] in
            guard browser == nil else { return }
            var ref: DNSServiceRef?
            let context = Unmanaged.passUnretained(self).toOpaque()
            let err = DNSServiceBrowse(&ref, 0, 0, Self.serviceType, nil, { _, flags, iface, err, name, type, domain, ctx in
                guard err == kDNSServiceErr_NoError, flags & kDNSServiceFlagsAdd != 0,
                      let ctx, let name, let type, let domain else { return }
                let me = Unmanaged<Bonjour>.fromOpaque(ctx).takeUnretainedValue()
                me.resolve(name: String(cString: name), type: String(cString: type), domain: String(cString: domain), iface: iface)
            }, context)
            guard err == kDNSServiceErr_NoError, let ref else {
                FluxLog.net.warning("Bonjour browse failed: \(err)")
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
            resolving = []
        }
    }

    public func stop() {
        queue.sync {
            if let r = registration { DNSServiceRefDeallocate(r) }
            if let b = browser { DNSServiceRefDeallocate(b) }
            resolving.forEach { DNSServiceRefDeallocate($0) }
            registration = nil
            browser = nil
            resolving = []
        }
    }

    private func finish(_ ref: DNSServiceRef?) {
        guard let ref, let i = resolving.firstIndex(of: ref) else { return }
        resolving.remove(at: i)
        DNSServiceRefDeallocate(ref)
    }

    private func resolve(name: String, type: String, domain: String, iface: UInt32) {
        guard name != selfId else { return }
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let err = DNSServiceResolve(&ref, 0, iface, name, type, domain, { sdRef, _, iface, err, _, host, _, _, _, ctx in
            guard let ctx else { return }
            let me = Unmanaged<Bonjour>.fromOpaque(ctx).takeUnretainedValue()
            defer { me.finish(sdRef) }
            guard err == kDNSServiceErr_NoError, let host else { return }
            me.lookup(host: String(cString: host), iface: iface)
        }, context)
        guard err == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        resolving.append(ref)
    }

    private func lookup(host: String, iface: UInt32) {
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
