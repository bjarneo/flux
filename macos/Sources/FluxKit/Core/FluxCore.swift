import Crypto
import Foundation
#if os(macOS)
import IOKit.ps
import SystemConfiguration
#endif

/// A snapshot of the core for the UI.
public struct CoreState: Sendable, Equatable {
    public var deviceName = ""
    public var deviceId = ""
    public var devices: [DeviceSnapshot] = []
    public var listeningUdp = true
    public var tcpPort = 0
    public var enabled = true
    /// True while a search for computers runs.
    public var searching = false

    /// True when the user did not allow Flux to use the local network.
    /// Discovery and links then fail.
    public var localNetworkDenied = false

    public init() {}
}

/// Where Flux keeps its identity and settings.
public struct FluxPaths: Sendable {
    public var data: URL
    public var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }
    let suite: String

    /// ~/Library/Application Support/Flux, or FLUX_DATA_DIR. FLUX_DATA_DIR
    /// also moves the settings to a separate defaults domain, the same for
    /// each launch with the same directory.
    public static func standard(_ env: [String: String] = ProcessInfo.processInfo.environment) -> FluxPaths {
        if let dir = env["FLUX_DATA_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            return FluxPaths(data: url, suite: testSuite(url.path))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FluxPaths(data: base.appendingPathComponent("Flux", isDirectory: true), suite: "org.omarchy.flux")
    }

    public init(data: URL, suite: String) {
        self.data = data
        self.suite = suite
    }

    /// The defaults domain for a data directory. String.hashValue changes
    /// with each launch, so the name comes from a SHA-256 of the path.
    static func testSuite(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "org.omarchy.flux.test." + digest
    }
}

/// The process-wide state of Flux: the certificate, the paired devices, the
/// live links, and the actions that the UI calls. Device state changes happen
/// inside `locked`, which publishes a new state at the end.
public final class FluxCore: @unchecked Sendable {
    public let local: LocalCertificate
    public let tls: FluxTLS
    public let trust: TrustStore
    public let paths: FluxPaths
    public let defaults: UserDefaults
    public let lanConfig: LanConfig
    public let plugins: [FluxPlugin]

    private let lock = NSRecursiveLock()
    private var devices: [String: Device] = [:]
    private var order: [String] = []
    private var backend: LanBackend?
    private var bonjour: Bonjour?
    /// Counts the searches, so that the end of an old search does not end a new one.
    private var searchCount = 0
    private var searching = false
    private var routes: [String: [FluxPlugin]] = [:]
    /// The last state that went to onChange.
    private var published: CoreState?

    /// True after Bonjour reported that the local network is not allowed.
    private var localNetworkDenied = false

    /// The hosts whose last incoming pairing request ended without a pairing.
    private var pairCooldown = PairCooldown()
    /// How long an incoming pairing request stays open. A test sets a shorter time.
    var incomingPairSeconds = incomingPairTimeout

    /// The most devices that are not paired and have a link. A new link
    /// closes the oldest one, so that strangers cannot fill the list.
    static let maxUnpairedLinks = 8
    /// How long the link of a device that is not paired stays open without
    /// a pairing, in seconds. fluxd closes such a link after the same time.
    static let unpairedIdleSeconds: Double = 120

    /// Called on the main queue after each state change.
    public var onChange: (@Sendable (CoreState) -> Void)?
    /// Called on the main queue with a short message for the user.
    public var onToast: (@Sendable (String) -> Void)?
    /// Called on the main queue when a device asks to pair.
    public var onPairRequest: (@Sendable (DeviceSnapshot) -> Void)?

    public init(paths: FluxPaths = .standard(), lanConfig: LanConfig = .fromEnvironment(), plugins: [FluxPlugin]) throws {
        self.paths = paths
        self.defaults = paths.defaults
        self.lanConfig = lanConfig
        self.plugins = plugins
        try FileManager.default.createDirectory(at: paths.data, withIntermediateDirectories: true)
        local = try LocalCertificate.loadOrCreate(directory: paths.data.appendingPathComponent("identity", isDirectory: true))
        tls = try FluxTLS(local: local)
        trust = TrustStore(url: paths.data.appendingPathComponent("trusted.json"))
        for t in trust.all() {
            let identity = Identity(deviceId: t.id, deviceName: t.name, deviceType: t.type, protocolVersion: protocolVersion,
                                    incoming: t.isFlux ? [PacketType.fluxTunnel] : [], outgoing: [])
            // Older versions paired with any device, for example phones and
            // other Macs. Drop those pairings.
            guard identity.isFlux else {
                FluxLog.core.info("removed the pairing with \(t.name, privacy: .public), which is not an Omarchy computer")
                trust.remove(t.id)
                continue
            }
            // TrustStore drops an entry whose certificate does not read. A
            // device without a pinned certificate is not paired.
            guard let pinned = t.certificateDER else { continue }
            let d = Device(core: self, identity: identity)
            d.pairState = .paired
            d.lastIp = t.lastIp
            d.certificate = pinned
            devices[t.id] = d
            order.append(t.id)
        }
        for p in plugins {
            for type in p.handledTypes { routes[type, default: []].append(p) }
        }
        for p in plugins { p.attach(core: self) }
    }

    // MARK: Identity

    #if os(macOS)
    /// The computer name from System Settings > General > Sharing.
    public var deviceName: String {
        cleanName((SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac")
    }

    /// The name of this app in the identity.
    public static let appName = "macos"

    /// "laptop" when the Mac has an internal battery, else "desktop".
    public static let deviceType: String = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return "desktop" }
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType { return "laptop" }
        }
        return "desktop"
    }()
    #else
    /// The name that the user gives the iPhone in Flux, else "iPhone". iOS
    /// gives apps only the generic device name.
    public var deviceName: String {
        cleanName(defaults.string(forKey: Self.deviceNameKey) ?? "", fallback: "iPhone")
    }

    /// The iPhone is a phone.
    public static let deviceType = "phone"

    /// The name of this app in the identity.
    public static let appName = "ios"

    /// Stores the device name. An empty name goes back to "iPhone". The new
    /// name goes out through Bonjour and to known computers. A computer reads
    /// the name only when a link starts, so the open links close, and the
    /// computers connect again with the new name.
    @MainActor
    public func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = deviceName
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.deviceNameKey)
        } else {
            defaults.set(trimmed, forKey: Self.deviceNameKey)
        }
        guard deviceName != old else { return }
        let (b, bj, links) = lock.withLock { (backend, bonjour, devices.values.compactMap(\.link)) }
        links.forEach { $0.close() }
        if let b {
            bj?.publish(name: deviceName, type: Self.deviceType, port: b.tcpPort)
            b.broadcast()
        }
        publish()
    }
    #endif

    /// The defaults key of the device name that the user sets on iOS.
    public static let deviceNameKey = "deviceName"

    public var incomingCapabilities: [String] { unique(plugins.flatMap(\.incoming)) }
    public var outgoingCapabilities: [String] { unique(plugins.flatMap(\.outgoing)) }

    private func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    public func identity(tcpPort: Int) -> Identity {
        Identity(deviceId: local.deviceId, deviceName: deviceName, deviceType: Self.deviceType, protocolVersion: protocolVersion,
                 incoming: incomingCapabilities, outgoing: outgoingCapabilities, tcpPort: tcpPort,
                 app: Self.appName, appVersion: Self.appVersion)
    }

    /// The version of this app, from CFBundleShortVersionString. The build
    /// sets it from the last release tag.
    public static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    /// Sends the identity again to each connected, paired computer, after
    /// the capabilities changed. fluxd takes the new capabilities from it.
    public func sendIdentity() {
        let port = lock.withLock { backend?.tcpPort ?? 0 }
        let p = identity(tcpPort: port).packet()
        lock.withLock {
            for d in devices.values where d.paired { d.send(p) }
        }
    }

    // MARK: Settings

    /// False after the user turns Flux off. Flux then uses no network.
    public var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "enabled")
            if newValue { start() } else { stop() }
            publish()
        }
    }

    // MARK: Network

    /// Starts discovery and the link listener unless the user turned Flux off.
    public func start() {
        guard enabled else { return }
        let started: LanBackend? = lock.withLock {
            if backend != nil { return nil }
            let identityFn: @Sendable (Int) -> Identity = { [unowned self] port in self.identity(tcpPort: port) }
            let b = LanBackend(tls: tls, config: lanConfig, identity: identityFn, delegate: BackendDelegate(core: self))
            backend = b
            return b
        }
        guard let b = started else { return }
        Task.detached { [self] in
            await b.start()
            // A stop during the start wins: the backend and its Bonjour end.
            guard lock.withLock({ backend === b }) else {
                b.stop()
                return
            }
            if !lanConfig.loopbackOnly {
                let bonjour = Bonjour(selfId: local.deviceId, found: { [weak self] ip in self?.announceTo(ip) },
                                      denied: { [weak self] denied in self?.setLocalNetworkDenied(denied) })
                bonjour.publish(name: deviceName, type: Self.deviceType, port: b.tcpPort)
                let (current, old) = lock.withLock { () -> (Bool, Bonjour?) in
                    guard backend === b else { return (false, nil) }
                    defer { self.bonjour = bonjour }
                    return (true, self.bonjour)
                }
                old?.stop()
                guard current else {
                    bonjour.stop()
                    return
                }
            }
            search()
        }
    }

    private func setLocalNetworkDenied(_ denied: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard localNetworkDenied != denied else { return false }
            localNetworkDenied = denied
            return true
        }
        guard changed else { return }
        if denied { FluxLog.net.error("the local network is not allowed for Flux") }
        publish()
    }

    /// True while the network runs.
    public var isRunning: Bool { lock.withLock { backend != nil } }

    /// Brings the network back when the app returns to the screen. A stopped
    /// network starts. A running one announces this device again and
    /// searches, so that the computers connect at once. iOS stops the network
    /// after the app leaves the screen.
    public func resume() {
        guard enabled else { return }
        let (b, bj) = lock.withLock { (backend, bonjour) }
        guard let b else {
            start()
            return
        }
        bj?.publish(name: deviceName, type: Self.deviceType, port: b.tcpPort)
        search()
    }

    /// Closes every link and stops discovery.
    public func stop() {
        let (b, bj, links) = lock.withLock { () -> (LanBackend?, Bonjour?, [Link]) in
            defer { backend = nil; bonjour = nil; searching = false; searchCount += 1 }
            return (backend, bonjour, devices.values.compactMap(\.link))
        }
        bj?.stop()
        b?.stop()
        links.forEach { $0.close() }
        publish()
    }

    /// How long a search for computers runs.
    static let searchSeconds: Double = 10

    /// Looks for computers for 10 seconds: Bonjour browses, and the identity
    /// goes out at once and again after 3 and 6 seconds. Flux does not search
    /// all the time. After a search ends, a paired computer still gets a dial
    /// from this device when its UDP identity arrives. A computer that is
    /// not paired finds this device through its Bonjour service and connects.
    ///
    /// A search clears the Local Network warning. The browse sets it again
    /// when the access is still off, for example after a visit to Settings.
    public func search() {
        let (b, bj, count) = lock.withLock { () -> (LanBackend?, Bonjour?, Int) in
            searchCount += 1
            searching = backend != nil
            if backend != nil { localNetworkDenied = false }
            return (backend, bonjour, searchCount)
        }
        guard let b else { return }
        bj?.browse()
        b.broadcast()
        publish()
        for delay in [3.0, 6.0] {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.lock.withLock({ self.searchCount == count }) else { return }
                b.broadcast()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.searchSeconds) { [weak self] in
            guard let self else { return }
            // A newer search keeps the state. Without Bonjour the search ends too.
            let (ended, bonjour) = self.lock.withLock { () -> (Bool, Bonjour?) in
                guard self.searchCount == count else { return (false, nil) }
                self.searching = false
                return (true, self.bonjour)
            }
            guard ended else { return }
            bonjour?.stopBrowsing()
            self.publish()
        }
    }

    /// Sends the identity to one host, for example one that mDNS found.
    public func announceTo(_ ip: String) {
        lock.withLock { backend }?.announceTo(ip)
    }

    fileprivate func attach(_ link: Link) {
        guard link.identity.isFlux else {
            FluxLog.core.info("closed the link from \(link.identity.deviceName, privacy: .public), which is not an Omarchy computer")
            link.close()
            return
        }
        locked {
            // Flux is off, or a newer start replaced the backend.
            guard backend != nil else {
                link.close()
                return
            }
            // A link came through, so the local network works.
            localNetworkDenied = false
            let id = link.identity.deviceId
            if let refusal = refusal(of: link) {
                FluxLog.core.error("closed the link from \(link.identity.deviceName, privacy: .public): \(refusal, privacy: .public)")
                link.close()
                return
            }
            let existing = devices[id]
            let old = existing?.link
            let d: Device
            if let existing {
                d = existing
            } else {
                evictUnpairedLink()
                d = Device(core: self, identity: link.identity)
                devices[id] = d
                order.append(id)
            }
            d.identity = link.identity
            // A pairing is bound to the link on which it started. fluxd ends
            // its side when a new link replaces that link, so this side ends
            // too, before the new link can accept it.
            if let old, old !== link, d.pairState == .requested || d.pairState == .incoming {
                FluxLog.core.info("ended the pairing with \(d.name, privacy: .public): a new link replaced its link")
                // The reset of an incoming pairing makes its host wait.
                let incoming = d.pairState == .incoming
                d.resetPair()
                toast(Device.pairStoppedText(computer: d.name, incoming: incoming))
            }
            // Set the new link first, so that closing the old link does not
            // mark the device offline.
            d.link = link
            if let old, old !== link { old.close() }
            d.certificate = link.peerCertificate
            d.lastIp = link.address
            if trust.get(id) != nil {
                d.pairState = .paired
                trust.update(id) {
                    $0.name = link.identity.deviceName
                    $0.lastIp = d.lastIp
                    $0.isFlux = link.identity.isFlux
                }
            }
            link.start(
                onPacket: { [weak self, weak d, weak link] p in
                    guard let self, let d, let link else { return }
                    // Only a pair packet changes the state. Plugin packets
                    // skip the publish. A packet counts only when it comes
                    // on the current link of the device.
                    if p.type == PacketType.pair {
                        self.locked { if d.link === link { self.dispatch(d, p) } }
                    } else {
                        self.lock.withLock { if d.link === link { self.dispatch(d, p) } }
                    }
                },
                onClose: { [weak self, weak d] in
                    guard let self, let d else { return }
                    self.detach(d, link)
                }
            )
            if d.paired {
                onConnected(d)
            } else {
                closeWhenIdle(link, id: id)
            }
        }
    }

    /// Closes the link of a device that is not paired when no pairing runs
    /// on it after `unpairedIdleSeconds`. A pairing that runs moves the
    /// check to later, and a pairing that ends it.
    private func closeWhenIdle(_ link: Link, id: String) {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.unpairedIdleSeconds) { [weak self, weak link] in
            guard let self, let link else { return }
            let state = self.lock.withLock { () -> PairState? in
                guard let d = self.devices[id], d.link === link else { return nil }
                return d.pairState
            }
            // The link closed, or it is no longer the link of the device.
            guard let state else { return }
            switch state {
            case .paired:
                return
            case .requested, .incoming:
                self.closeWhenIdle(link, id: id)
            case .none:
                FluxLog.core.info("closed the link from \(link.identity.deviceName, privacy: .public): no pairing in \(Int(Self.unpairedIdleSeconds)) seconds")
                link.close()
            }
        }
    }

    /// The reason to refuse a new link, or nil. The lock is held. A paired
    /// device must show its pinned certificate, and a device with an open
    /// pairing or a live link must show the certificate that it has. The
    /// backend checks the pin too, but the device can pair between that
    /// check and this call.
    private func refusal(of link: Link) -> String? {
        let id = link.identity.deviceId
        let d = devices[id]
        var live: [UInt8]?
        if let old = d?.link, old.isOpen, old !== link { live = old.peerCertificate }
        // An entry whose certificate does not read matches no certificate.
        return Self.linkRefusal(new: link.peerCertificate, pinned: trust.get(id).map { $0.certificateDER ?? [] },
                                pairState: d?.pairState ?? PairState.none, pairCertificate: d?.pairCertificate, live: live)
    }

    /// The reason to refuse a new link that shows the certificate `new`, or
    /// nil. `pinned` is the certificate of the trust entry, `pairState` and
    /// `pairCertificate` are the pairing of the device, and `live` is the
    /// certificate of its other open link. nil means that there is none.
    static func linkRefusal(new: [UInt8], pinned: [UInt8]?, pairState: PairState, pairCertificate: [UInt8]?, live: [UInt8]?) -> String? {
        if let pinned, pinned != new {
            return "the certificate differs from the paired one"
        }
        if let live, live != new {
            return "a live link has another certificate"
        }
        // A pairing is bound to the certificate behind its key.
        if pairState == .requested || pairState == .incoming, pairCertificate != new {
            return "a pairing with another certificate is open"
        }
        return nil
    }

    /// Drops the oldest device that is not paired and has a link, when the
    /// list holds too many of them. A device without an open pairing goes
    /// first. The device leaves the list at once, because its link can take
    /// seconds to close. The lock is held.
    private func evictUnpairedLink() {
        let unpaired = order.compactMap { devices[$0] }.filter { !$0.paired && $0.link != nil }
        guard unpaired.count >= Self.maxUnpairedLinks,
              let d = unpaired.first(where: { $0.pairState == .none }) ?? unpaired.first else { return }
        FluxLog.core.info("closed the link from \(d.name, privacy: .public): too many devices that are not paired")
        d.cancelPair()
        let link = d.link
        // Without its link, the device ignores the packets and the close of the old link.
        d.link = nil
        devices.removeValue(forKey: d.id)
        order.removeAll { $0 == d.id }
        link?.close()
    }

    private func detach(_ d: Device, _ link: Link) {
        locked {
            guard d.link === link else { return }
            d.link = nil
            if d.pairState == .requested || d.pairState == .incoming { d.pairState = .none }
            if d.paired {
                for p in plugins { p.onDisconnected(d) }
            } else if devices[d.id] === d {
                devices.removeValue(forKey: d.id)
                order.removeAll { $0 == d.id }
            }
        }
    }

    // MARK: State

    /// Runs the block under the core lock and publishes the new state.
    @discardableResult
    public func locked<T>(_ block: () throws -> T) rethrows -> T {
        let r = try lock.withLock { try block() }
        publish()
        return r
    }

    public var state: CoreState {
        lock.withLock {
            var s = CoreState()
            s.deviceName = deviceName
            s.deviceId = local.deviceId
            s.devices = order.compactMap { devices[$0]?.snapshot() }
            s.listeningUdp = backend?.listeningUdp ?? true
            s.tcpPort = backend?.tcpPort ?? 0
            s.enabled = enabled
            s.searching = searching
            s.localNetworkDenied = localNetworkDenied
            return s
        }
    }

    /// Sends the state to onChange when it differs from the last state that
    /// went out. The lock keeps the snapshots in order on the main queue.
    public func publish() {
        guard let onChange else { return }
        lock.withLock {
            let snapshot = state
            guard snapshot != published else { return }
            published = snapshot
            DispatchQueue.main.async { onChange(snapshot) }
        }
    }

    public func toast(_ message: String) {
        // Toasts can name files and hold text from the computer.
        FluxLog.core.info("\(message, privacy: .private)")
        guard let onToast else { return }
        DispatchQueue.main.async { onToast(message) }
    }

    public func device(_ id: String) -> Device? { lock.withLock { devices[id] } }

    /// Reads fields of a device under the core lock, without a publish. The
    /// core lock guards every field of a device, so a feature reads them
    /// here, for example `core.withDevice(id) { $0.name }`.
    public func withDevice<T>(_ id: String, _ body: (Device) -> T) -> T? {
        lock.withLock { devices[id].map(body) }
    }

    /// True while a search for computers runs.
    var isSearching: Bool { lock.withLock { searching } }

    /// True when a device other than `id` has an open incoming request.
    /// The lock is held.
    func hasIncomingPair(except id: String) -> Bool {
        devices.values.contains { $0.id != id && $0.pairState == .incoming }
    }

    /// Makes the host of the device wait after its incoming request ended
    /// without a pairing, see `PairCooldown`. The lock is held.
    func incomingPairEnded(_ d: Device) {
        pairCooldown.add(id: d.id, ip: d.link?.address ?? d.lastIp, at: ProcessInfo.processInfo.systemUptime)
    }

    /// True while the host of the device waits after its last incoming
    /// request. The lock is held.
    func pairCooldownBlocks(_ d: Device) -> Bool {
        pairCooldown.blocks(id: d.id, ip: d.link?.address ?? d.lastIp, at: ProcessInfo.processInfo.systemUptime)
    }

    public func connectedPaired() -> [Device] { lock.withLock { order.compactMap { devices[$0] }.filter { $0.paired && $0.online } } }

    /// The IDs of the connected, paired devices, and with `accepting` only
    /// those that accept the packet type. It reads the devices under the lock.
    public func connectedPairedIds(accepting type: String? = nil) -> [String] {
        lock.withLock {
            order.compactMap { devices[$0] }
                .filter { d in d.paired && d.online && (type.map { d.accepts($0) } ?? true) }
                .map(\.id)
        }
    }

    public func plugin<T: FluxPlugin>(_ type: T.Type) -> T? { plugins.lazy.compactMap { $0 as? T }.first }

    // MARK: Events

    /// Handles one packet from a device. The core lock is held.
    func dispatch(_ d: Device, _ p: Packet) {
        if p.type == PacketType.pair {
            d.onPairPacket(p)
            return
        }
        guard d.paired else {
            FluxLog.core.debug("ignored \(p.type, privacy: .public) from unpaired \(d.name, privacy: .public)")
            return
        }
        for plugin in routes[p.type] ?? [] { plugin.handle(p, from: d) }
    }

    func onPaired(_ d: Device) { onConnected(d) }

    func didUnpair(_ d: Device) {
        for p in plugins { p.onDisconnected(d) }
    }

    /// Tells every plugin that a paired device is ready.
    private func onConnected(_ d: Device) {
        for p in plugins { p.onConnected(d) }
    }

    func notifyPairRequest(_ d: Device) {
        guard let onPairRequest else { return }
        let snapshot = d.snapshot()
        DispatchQueue.main.async { onPairRequest(snapshot) }
    }

    // MARK: Actions

    public func previewKey(_ id: String, timestamp: Int64) -> String { lock.withLock { devices[id]?.previewKey(timestamp: timestamp) ?? "" } }
    public func pair(_ id: String, timestamp: Int64) { locked { devices[id]?.requestPair(timestamp: timestamp) } }
    public func acceptPair(_ id: String) { locked { devices[id]?.acceptPair() } }
    public func cancelPair(_ id: String) { locked { devices[id]?.cancelPair() } }

    public func unpair(_ id: String) {
        locked {
            guard let d = devices[id] else { return }
            let wasPaired = d.paired
            d.unpair()
            if wasPaired { didUnpair(d) }
            if !d.online {
                devices.removeValue(forKey: id)
                order.removeAll { $0 == id }
            }
        }
    }

    /// Sends a packet to a paired, connected device. It returns false when
    /// the device is offline or not paired.
    @discardableResult
    public func send(_ p: Packet, to id: String) -> Bool { lock.withLock { devices[id]?.send(p) ?? false } }
}

/// Connects the backend to the core without a retain cycle. The backend can
/// outlive the core for a moment, so the reference is weak.
private final class BackendDelegate: LanBackendDelegate, @unchecked Sendable {
    weak var core: FluxCore?

    init(core: FluxCore) { self.core = core }

    func trustedCertificate(deviceId: String) -> [UInt8]? { core?.trust.get(deviceId)?.certificateDER }
    func hasLink(deviceId: String) -> Bool { core?.withDevice(deviceId) { $0.online } ?? false }
    func dialsFrom(deviceId: String) -> Bool {
        guard let core else { return false }
        return core.trust.get(deviceId) != nil || core.isSearching
    }
    func onLink(_ link: Link) {
        guard let core else {
            link.close()
            return
        }
        core.attach(link)
    }
    func knownAddresses() -> [String] { core?.trust.all().map(\.lastIp).filter { !$0.isEmpty } ?? [] }
}
