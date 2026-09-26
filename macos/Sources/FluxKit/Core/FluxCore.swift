import Foundation
import IOKit.ps
import SystemConfiguration

/// A snapshot of the core for the UI.
public struct CoreState: Sendable, Equatable {
    public var deviceName = ""
    public var deviceId = ""
    public var devices: [DeviceSnapshot] = []
    public var listeningUdp = true
    public var tcpPort = 0
    public var enabled = true

    public init() {}
}

/// Where Flux keeps its identity and settings.
public struct FluxPaths: Sendable {
    public var data: URL
    public var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }
    let suite: String

    /// ~/Library/Application Support/Flux, or FLUX_DATA_DIR. FLUX_DATA_DIR
    /// also moves the settings to a separate defaults domain.
    public static func standard(_ env: [String: String] = ProcessInfo.processInfo.environment) -> FluxPaths {
        if let dir = env["FLUX_DATA_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            return FluxPaths(data: url, suite: "org.omarchy.flux.test." + String(url.path.hashValue, radix: 36))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FluxPaths(data: base.appendingPathComponent("Flux", isDirectory: true), suite: "org.omarchy.flux")
    }

    public init(data: URL, suite: String) {
        self.data = data
        self.suite = suite
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
    private var rebroadcast: DispatchSourceTimer?
    private var routes: [String: [FluxPlugin]] = [:]

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
            let d = Device(core: self, identity: identity)
            d.pairState = .paired
            d.lastIp = t.lastIp
            d.certificate = t.certificateDER
            devices[t.id] = d
            order.append(t.id)
        }
        for p in plugins {
            for type in p.incoming { routes[type, default: []].append(p) }
        }
        for p in plugins { p.attach(core: self) }
    }

    // MARK: Identity

    /// The computer name from System Settings > General > Sharing.
    public var deviceName: String {
        cleanName((SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac")
    }

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

    public var incomingCapabilities: [String] { unique(plugins.flatMap(\.incoming)) }
    public var outgoingCapabilities: [String] { unique(plugins.flatMap(\.outgoing)) }

    private func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    public func identity(tcpPort: Int) -> Identity {
        Identity(deviceId: local.deviceId, deviceName: deviceName, deviceType: Self.deviceType, protocolVersion: protocolVersion,
                 incoming: incomingCapabilities, outgoing: outgoingCapabilities, tcpPort: tcpPort)
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
        let b: LanBackend = lock.withLock {
            if let b = backend { return b }
            let identityFn: @Sendable (Int) -> Identity = { [unowned self] port in self.identity(tcpPort: port) }
            let b = LanBackend(tls: tls, config: lanConfig, identity: identityFn, delegate: BackendDelegate(core: self))
            backend = b
            return b
        }
        Task.detached { [self] in
            await b.start()
            if !lanConfig.loopbackOnly {
                let bonjour = Bonjour(selfId: local.deviceId) { [weak self] ip in self?.announceTo(ip) }
                bonjour.publish(name: deviceName, type: Self.deviceType, port: b.tcpPort)
                bonjour.browse()
                lock.withLock { self.bonjour = bonjour }
            }
            startRebroadcast()
            publish()
        }
    }

    /// Closes every link and stops discovery.
    public func stop() {
        let (b, bj, timer, links) = lock.withLock { () -> (LanBackend?, Bonjour?, DispatchSourceTimer?, [Link]) in
            defer { backend = nil; bonjour = nil; rebroadcast = nil }
            return (backend, bonjour, rebroadcast, devices.values.compactMap(\.link))
        }
        timer?.cancel()
        bj?.stop()
        b?.stop()
        links.forEach { $0.close() }
        publish()
    }

    /// Paired devices that are offline get the identity again every 30
    /// seconds, so that they reconnect after a network change.
    private func startRebroadcast() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let anyOffline = self.lock.withLock { self.devices.values.contains { $0.paired && !$0.online } }
            if anyOffline { self.rediscover() }
        }
        timer.resume()
        lock.withLock {
            rebroadcast?.cancel()
            rebroadcast = timer
        }
    }

    /// Sends the identity again, for example after the network changes.
    public func rediscover() {
        lock.withLock { backend }?.broadcast()
        publish()
    }

    /// Sends the identity to one host, for example one that mDNS found.
    public func announceTo(_ ip: String) {
        lock.withLock { backend }?.announceTo(ip)
    }

    fileprivate func attach(_ link: Link) {
        locked {
            let id = link.identity.deviceId
            let existing = devices[id]
            let old = existing?.link
            if let old, old.isOpen, old !== link, old.peerCertificate != link.peerCertificate {
                // Only the same certificate may replace a live link.
                link.close()
                return
            }
            let d: Device
            if let existing {
                d = existing
            } else {
                d = Device(core: self, identity: link.identity)
                devices[id] = d
                order.append(id)
            }
            d.identity = link.identity
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
                onPacket: { [weak self, weak d] p in
                    guard let self, let d else { return }
                    self.locked { self.dispatch(d, p) }
                },
                onClose: { [weak self, weak d] in
                    guard let self, let d else { return }
                    self.detach(d, link)
                }
            )
            if d.paired { onConnected(d) }
        }
    }

    private func detach(_ d: Device, _ link: Link) {
        locked {
            guard d.link === link else { return }
            d.link = nil
            if d.pairState == .requested || d.pairState == .incoming { d.pairState = .none }
            if d.paired {
                for p in plugins { p.onDisconnected(d) }
            } else {
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
            return s
        }
    }

    public func publish() {
        guard let onChange else { return }
        let snapshot = state
        DispatchQueue.main.async { onChange(snapshot) }
    }

    public func toast(_ message: String) {
        FluxLog.core.info("\(message, privacy: .public)")
        guard let onToast else { return }
        DispatchQueue.main.async { onToast(message) }
    }

    public func device(_ id: String) -> Device? { lock.withLock { devices[id] } }

    public func connectedPaired() -> [Device] { lock.withLock { order.compactMap { devices[$0] }.filter { $0.paired && $0.online } } }

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

/// Connects the backend to the core without a retain cycle.
private final class BackendDelegate: LanBackendDelegate, @unchecked Sendable {
    unowned let core: FluxCore

    init(core: FluxCore) { self.core = core }

    func trustedCertificate(deviceId: String) -> [UInt8]? { core.trust.get(deviceId)?.certificateDER }
    func hasLink(deviceId: String) -> Bool { core.device(deviceId)?.online == true }
    func onLink(_ link: Link) { core.attach(link) }
    func knownAddresses() -> [String] { core.trust.all().map(\.lastIp).filter { !$0.isEmpty } }
}
