import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// Ports and discovery scope of the LAN backend.
public struct LanConfig: Sendable {
    /// The UDP port that receives identity broadcasts.
    public var udpPort = 12100
    /// The UDP port of peers that this device announces itself to.
    public var peerUDPPort = 12100
    /// The TCP port range for links.
    public var tcpPorts: ClosedRange<Int> = 12100...12108
    /// The TCP ports of computers that this device dials after a UDP
    /// identity. fluxd listens on 12100 to 12108. In loopback mode the dial
    /// goes to any port on 127.0.0.1, for a headless fluxd in a test.
    public var peerTcpPorts: ClosedRange<Int> = 12100...12108
    /// Announces only to 127.0.0.1, for tests against a headless fluxd.
    public var loopbackOnly = false
    /// Sends identities to broadcast addresses. iOS needs the multicast
    /// entitlement for broadcasts, so the iPhone announces itself only to
    /// known and Bonjour-resolved computers.
    #if os(iOS)
    public var sendsBroadcast = false
    #else
    public var sendsBroadcast = true
    #endif

    public init() {}

    /// Reads FLUX_UDP_PORT, FLUX_PEER_UDP_PORT, and FLUX_LOOPBACK=1.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LanConfig {
        var c = LanConfig()
        if let v = env["FLUX_UDP_PORT"].flatMap(Int.init) { c.udpPort = v }
        if let v = env["FLUX_PEER_UDP_PORT"].flatMap(Int.init) { c.peerUDPPort = v }
        c.loopbackOnly = env["FLUX_LOOPBACK"] == "1"
        return c
    }
}

/// What the backend asks of the core.
public protocol LanBackendDelegate: AnyObject, Sendable {
    /// Returns the pinned certificate of a trusted device, or nil.
    func trustedCertificate(deviceId: String) -> [UInt8]?
    /// Reports whether a live link to the device exists.
    func hasLink(deviceId: String) -> Bool
    /// Reports whether a UDP identity from the device may start a dial:
    /// a trusted device, or any computer while a search runs.
    func dialsFrom(deviceId: String) -> Bool
    /// Receives a new link after TLS and the identity check.
    func onLink(_ link: Link)
    /// Returns the addresses of trusted devices to contact directly.
    func knownAddresses() -> [String]
}

/// The LAN backend. It broadcasts the identity over UDP, accepts
/// TCP links, connects to devices that broadcast, and runs the TLS handshake.
public final class LanBackend: @unchecked Sendable {
    public let tls: FluxTLS
    public let config: LanConfig
    let group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    let identity: @Sendable (Int) -> Identity
    /// Held strongly. The core's delegate refers back to the core without retaining it.
    let delegate: LanBackendDelegate?

    private struct State {
        var running = false
        var tcpPort = 0
        var listeningUdp = false
        var server: Channel?
        var udp: Channel?
        var lastAttempt: [String: Date] = [:]

        /// The connections before their link starts, oldest first: accepted
        /// and dialed connections in the identity or the TLS phase.
        var pending: [(id: ObjectIdentifier, channel: Channel)] = []
        /// The dials that did not connect yet.
        var dials = 0
        /// Counts the starts, so that a start that a stop overtook keeps nothing.
        var generation = 0
    }
    private let state = NIOLockedValueBox(State())

    /// The most connections before their link starts. A new connection
    /// closes the oldest one, so that idle connections cannot block a
    /// computer that connects.
    static let maxHandshakes = 16
    /// The most dials that did not connect yet.
    static let maxDials = 8
    /// The shortest time between 2 dials to 1 device, in seconds.
    static let dialInterval: TimeInterval = 1
    /// The most device IDs that the dial interval remembers.
    static let maxDialTargets = 256

    /// The TCP keepalive of fluxd: the first probe after 10 idle seconds,
    /// then 1 probe each 5 seconds. After 3 probes without an answer, the
    /// kernel closes the link. The Darwin default waits 2 hours, so a link
    /// that a network change broke stays open, and no new dial starts.
    /// The kernel sends the probes, so they also go while iOS suspends Flux.
    static let keepAliveIdle: SocketOptionValue = 10
    static let keepAliveInterval: SocketOptionValue = 5
    static let keepAliveCount: SocketOptionValue = 3
    /// Darwin names the idle time `TCP_KEEPALIVE`.
    static let tcpKeepIdle = NIOBSDSocket.Option(rawValue: TCP_KEEPALIVE)
    static let tcpKeepInterval = NIOBSDSocket.Option(rawValue: TCP_KEEPINTVL)
    static let tcpKeepCount = NIOBSDSocket.Option(rawValue: TCP_KEEPCNT)

    public init(tls: FluxTLS, config: LanConfig, identity: @escaping @Sendable (Int) -> Identity, delegate: LanBackendDelegate) {
        self.tls = tls
        self.config = config
        self.identity = identity
        self.delegate = delegate
    }

    public var tcpPort: Int { state.withLockedValue { $0.tcpPort } }
    /// True when this app owns the UDP port and hears broadcasts.
    public var listeningUdp: Bool { state.withLockedValue { $0.listeningUdp } }
    var localDeviceId: String { tls.local.deviceId }
    /// True between start and stop.
    var isRunning: Bool { state.withLockedValue { $0.running } }

    public func start() async {
        let generation = state.withLockedValue { s -> Int? in
            if s.running { return nil }
            s.running = true
            s.generation += 1
            return s.generation
        }
        guard let generation else { return }
        let server = await openServer()
        let (udp, listening) = await openUdp()
        let kept = state.withLockedValue { s -> Bool in
            // A stop during the binds wins. The new sockets close.
            guard s.running, s.generation == generation else { return false }
            s.server = server
            s.tcpPort = server?.localAddress?.port ?? 0
            s.udp = udp
            s.listeningUdp = listening
            return true
        }
        guard kept else {
            server?.close(promise: nil)
            udp?.close(promise: nil)
            return
        }
        broadcast()
    }

    /// Closes the listeners and every connection before its link. The core
    /// closes the links.
    public func stop() {
        let (server, udp, pending) = state.withLockedValue { s -> (Channel?, Channel?, [Channel]) in
            s.running = false
            defer {
                s.server = nil
                s.udp = nil
                s.tcpPort = 0
                s.pending = []
                s.lastAttempt = [:]
            }
            return (s.server, s.udp, s.pending.map { $0.channel })
        }
        server?.close(promise: nil)
        udp?.close(promise: nil)
        pending.forEach { $0.close(promise: nil) }
    }

    /// Tracks a connection until its link starts. It returns false when the
    /// backend stopped. With too many connections, the oldest one closes.
    fileprivate func track(_ ch: Channel) -> Bool {
        let id = ObjectIdentifier(ch)
        let (kept, evicted) = state.withLockedValue { s -> (Bool, Channel?) in
            guard s.running else { return (false, nil) }
            s.pending.append((id, ch))
            guard s.pending.count > Self.maxHandshakes else { return (true, nil) }
            return (true, s.pending.removeFirst().channel)
        }
        evicted?.close(promise: nil)
        guard kept else { return false }
        ch.closeFuture.whenComplete { [weak self] _ in self?.untrack(ch) }
        return true
    }

    private func untrack(_ ch: Channel) {
        let id = ObjectIdentifier(ch)
        state.withLockedValue { $0.pending.removeAll { $0.id == id } }
    }

    /// Gives a new link to the core, unless the backend stopped.
    fileprivate func handOver(_ link: Link) {
        guard isRunning else {
            link.close()
            return
        }
        untrack(link.channel)
        delegate?.onLink(link)
    }

    private func openServer() async -> Channel? {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_keepalive), value: 1)
            .childChannelOption(.tcpOption(Self.tcpKeepIdle), value: Self.keepAliveIdle)
            .childChannelOption(.tcpOption(Self.tcpKeepInterval), value: Self.keepAliveInterval)
            .childChannelOption(.tcpOption(Self.tcpKeepCount), value: Self.keepAliveCount)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [weak self] ch in
                ch.eventLoop.makeCompletedFuture {
                    guard let self, self.track(ch) else { throw FluxError("backend stopped") }
                    try ch.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDecoder(max: maxIdentityLine)), name: PlainIdentityHandler.decoderName)
                    try ch.pipeline.syncOperations.addHandler(PlainIdentityHandler(backend: self))
                }
            }
        for port in config.tcpPorts {
            if let ch = try? await bootstrap.bind(host: "0.0.0.0", port: port).get() { return ch }
        }
        FluxLog.net.error("no free TCP port in \(self.config.tcpPorts.description, privacy: .public)")
        return nil
    }

    private func openUdp() async -> (Channel?, Bool) {
        func bootstrap() -> DatagramBootstrap {
            var b = DatagramBootstrap(group: group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
            if config.sendsBroadcast { b = b.channelOption(.socketOption(.so_broadcast), value: 1) }
            return b.channelInitializer { [weak self] ch in
                ch.eventLoop.makeCompletedFuture {
                    guard let self else { throw FluxError("backend stopped") }
                    try ch.pipeline.syncOperations.addHandler(UDPHandler(backend: self))
                }
            }
        }
        do {
            return (try await bootstrap().bind(host: "0.0.0.0", port: config.udpPort).get(), true)
        } catch {
            FluxLog.net.warning("UDP \(self.config.udpPort) is in use: \(String(describing: error), privacy: .public). Flux only announces itself.")
        }
        return (try? await bootstrap().bind(host: "0.0.0.0", port: 0).get(), false)
    }

    /// Sends the identity to every broadcast address and to known devices.
    /// Without broadcasts it goes to known devices only.
    public func broadcast() {
        let targets = Self.broadcastTargets(
            loopbackOnly: config.loopbackOnly, sendsBroadcast: config.sendsBroadcast,
            interfaces: config.loopbackOnly || !config.sendsBroadcast ? [] : Self.broadcastAddresses(),
            known: config.loopbackOnly ? [] : delegate?.knownAddresses() ?? [])
        for t in targets { announceTo(t) }
    }

    /// The addresses that an announcement goes to, each once.
    static func broadcastTargets(loopbackOnly: Bool, sendsBroadcast: Bool, interfaces: [String], known: [String]) -> [String] {
        if loopbackOnly { return ["127.0.0.1"] }
        var targets: [String] = []
        if sendsBroadcast { targets = ["255.255.255.255"] + interfaces }
        targets += known
        var seen = Set<String>()
        return targets.filter { seen.insert($0).inserted }
    }

    /// Sends the identity to one address, for example a host that mDNS found.
    public func announceTo(_ ip: String) {
        let (udp, port) = state.withLockedValue { ($0.udp, $0.tcpPort) }
        guard let udp, port > 0, let address = try? SocketAddress(ipAddress: ip, port: config.peerUDPPort) else { return }
        let data = identity(port).packet(withPort: true).serialize()
        var buffer = udp.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        udp.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: buffer)).whenFailure { error in
            FluxLog.net.debug("UDP send to \(ip, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func broadcastAddresses() -> [String] {
        guard let devices = try? System.enumerateDevices() else { return [] }
        return devices.compactMap { d -> String? in
            guard case .v4? = d.address, let b = d.broadcastAddress, case .v4 = b else { return nil }
            return b.ipAddress
        }
    }

    func onDatagram(_ data: ByteBuffer, from address: SocketAddress) {
        guard isRunning, let p = Packet.parse(Data(data.readableBytesView)), let id = Identity.from(p),
              id.deviceId != localDeviceId, id.isFlux, let ip = address.ipAddress,
              Self.dialAllowed(ip: ip, port: id.tcpPort, config: config),
              let delegate, delegate.dialsFrom(deviceId: id.deviceId), !delegate.hasLink(deviceId: id.deviceId) else { return }
        let now = Date()
        let allowed = state.withLockedValue { s -> Bool in
            s.lastAttempt = s.lastAttempt.filter { now.timeIntervalSince($0.value) < Self.dialInterval }
            guard s.lastAttempt[id.deviceId] == nil, s.lastAttempt.count < Self.maxDialTargets else { return false }
            s.lastAttempt[id.deviceId] = now
            return true
        }
        if allowed { connect(host: ip, port: id.tcpPort, udpIdentity: id) }
    }

    /// Reports whether a UDP identity may make this device dial the port.
    /// The address is the source of the datagram, which a LAN host can
    /// fake, so the dial goes only to the ports of fluxd. In loopback mode
    /// it goes only to 127.0.0.1.
    static func dialAllowed(ip: String, port: Int, config: LanConfig) -> Bool {
        if config.loopbackOnly { return ip.hasPrefix("127.") && (1...65535).contains(port) }
        return config.peerTcpPorts.contains(port)
    }

    /// Connects to a device that sent its identity over UDP. This side sends
    /// its identity in plain text and is then the TLS server.
    public func connect(host: String, port: Int, udpIdentity: Identity?) {
        // NIO stops the process for a port outside 0 to 65535.
        guard (1...65535).contains(port) else { return }
        let admitted = state.withLockedValue { s -> Bool in
            guard s.running, s.dials < Self.maxDials else { return false }
            s.dials += 1
            return true
        }
        guard admitted else { return }
        let plain = identity(0).packet(target: udpIdentity).serialize()
        ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelOption(.tcpOption(Self.tcpKeepIdle), value: Self.keepAliveIdle)
            .channelOption(.tcpOption(Self.tcpKeepInterval), value: Self.keepAliveInterval)
            .channelOption(.tcpOption(Self.tcpKeepCount), value: Self.keepAliveCount)
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { [weak self] ch in
                ch.eventLoop.makeCompletedFuture {
                    guard let self, self.track(ch) else { throw FluxError("backend stopped") }
                    let limit = LineLimit(maxUnpairedLine)
                    let sync = ch.pipeline.syncOperations
                    try sync.addHandler(self.tls.serverHandler())
                    try sync.addHandler(ByteToMessageHandler(LineDecoder(limit: limit)))
                    try sync.addHandler(SecureIdentityHandler(backend: self, plain: udpIdentity, limit: limit))
                }
            }
            .connect(host: host, port: port)
            .flatMapThrowing { ch in
                // The identity goes out in plain text below the TLS handler.
                let ctx = try ch.pipeline.syncOperations.context(handlerType: NIOSSLServerHandler.self)
                var buffer = ch.allocator.buffer(capacity: plain.count)
                buffer.writeBytes(plain)
                ctx.writeAndFlush(NIOAny(buffer), promise: nil)
            }
            .whenComplete { [weak self] result in
                self?.state.withLockedValue { $0.dials -= 1 }
                if case .failure(let error) = result {
                    FluxLog.net.info("link to \(host, privacy: .public):\(port) failed: \(String(describing: error), privacy: .public)")
                }
            }
    }

    /// Checks the identity after TLS and makes the link. The core checks the
    /// pinned certificate again under its lock.
    func finish(channel: Channel, identity id: Identity, limit: LineLimit) throws -> Link {
        guard let cert = channel.peerCertificateDER() else { throw FluxError("peer sent no certificate") }
        let cn = commonName(der: cert)
        guard cn == id.deviceId else { throw FluxError("certificate CN \(cn ?? "none") does not match \(id.deviceId)") }
        if let pinned = delegate?.trustedCertificate(deviceId: id.deviceId), pinned != cert {
            throw FluxError("\(id.deviceName) presented a different certificate")
        }
        return Link(channel: channel, identity: id, peerCertificate: cert, limit: limit)
    }
}

/// Receives identity broadcasts.
final class UDPHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    /// Weak, because a datagram can arrive after the core dropped the backend.
    weak var backend: LanBackend?

    init(backend: LanBackend) { self.backend = backend }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        backend?.onDatagram(envelope.data, from: envelope.remoteAddress)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        FluxLog.net.debug("UDP: \(String(describing: error), privacy: .public)")
    }
}

/// Handles a TCP connection that a device opened. The device sends its
/// identity in plain text. This side is then the TLS client.
final class PlainIdentityHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    /// Weak, because the bytes can arrive after the core dropped the backend.
    weak var backend: LanBackend?
    static let decoderName = "plainIdentityDecoder"
    private var timeout: Scheduled<Void>?
    private var done = false

    init(backend: LanBackend) {
        self.backend = backend
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        timeout = context.eventLoop.scheduleTask(in: .seconds(10)) { channel.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        timeout?.cancel()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { return }
        done = true
        guard let backend, backend.isRunning else {
            context.close(promise: nil)
            return
        }
        let line = unwrapInboundIn(data)
        do {
            guard let packet = Packet.parse(Data(line.readableBytesView)), let plain = Identity.from(packet) else {
                throw FluxError("bad identity")
            }
            if plain.deviceId == backend.localDeviceId {
                context.close(promise: nil)
                return
            }
            // A device that answers a broadcast names the device it wants.
            if let target = packet.string("targetDeviceId"), target != backend.localDeviceId {
                throw FluxError("identity is for \(target)")
            }
            let limit = LineLimit(maxUnpairedLine)
            let sync = context.pipeline.syncOperations
            try sync.addHandler(try backend.tls.clientHandler())
            try sync.addHandler(ByteToMessageHandler(LineDecoder(limit: limit)))
            try sync.addHandler(SecureIdentityHandler(backend: backend, plain: plain, limit: limit))
            context.pipeline.removeHandler(name: Self.decoderName, promise: nil)
            context.pipeline.removeHandler(context: context, promise: nil)
        } catch {
            FluxLog.net.info("incoming link from \(context.remoteAddress?.ipAddress ?? "?", privacy: .public) failed: \(String(describing: error), privacy: .public)")
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Exchanges the identity inside TLS, checks the certificate, and then turns
/// the channel into a link.
final class SecureIdentityHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    /// Weak, because the handshake can end after the core dropped the backend.
    weak var backend: LanBackend?
    let plain: Identity?
    /// The line limit of the decoder, which the link takes over.
    let limit: LineLimit
    private var timeout: Scheduled<Void>?
    private var finished = false

    init(backend: LanBackend, plain: Identity?, limit: LineLimit) {
        self.backend = backend
        self.plain = plain
        self.limit = limit
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        timeout = context.eventLoop.scheduleTask(in: .seconds(10)) { channel.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        timeout?.cancel()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent {
            guard let backend, backend.isRunning else {
                context.close(promise: nil)
                return
            }
            // Both sides write the identity at once, so that neither side
            // waits for the other.
            let data = backend.identity(0).packet().serialize()
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.writeAndFlush(NIOAny(buffer), promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else {
            context.fireChannelRead(data)
            return
        }
        let line = unwrapInboundIn(data)
        guard let packet = Packet.parse(Data(line.readableBytesView)), let id = Identity.from(packet) else {
            fail(context: context, FluxError("bad identity after TLS"))
            return
        }
        if let plain, plain.deviceId != id.deviceId {
            fail(context: context, FluxError("device ID changed after TLS"))
            return
        }
        if let plain, plain.protocolVersion != id.protocolVersion {
            fail(context: context, FluxError("protocol version changed after TLS"))
            return
        }
        complete(context: context, identity: id)
    }

    private func complete(context: ChannelHandlerContext, identity: Identity) {
        finished = true
        guard let backend, backend.isRunning else {
            context.close(promise: nil)
            return
        }
        do {
            let link = try backend.finish(channel: context.channel, identity: identity, limit: limit)
            try context.pipeline.syncOperations.addHandler(LinkHandler(link: link), position: .after(self))
            context.pipeline.removeHandler(context: context, promise: nil)
            backend.handOver(link)
        } catch {
            fail(context: context, error)
        }
    }

    private func fail(context: ChannelHandlerContext, _ error: Error) {
        FluxLog.net.info("link from \(context.remoteAddress?.ipAddress ?? "?", privacy: .public) failed: \(String(describing: error), privacy: .public)")
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(context: context, error)
    }
}
