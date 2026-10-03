import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// The TCP port range for payload servers and tunnels.
public let payloadPorts: ClosedRange<Int> = 12070...12099

/// How long a tunnel listener waits for the computer.
public let tunnelTimeout: TimeAmount = .seconds(30)

/// Lets through at most 1 progress report per interval. A fast transfer
/// otherwise redraws the UI hundreds of times per second. The caller sends
/// the final report itself.
struct ProgressThrottle {
    /// The shortest time between 2 reports, in nanoseconds.
    static let interval: UInt64 = 100_000_000

    private var last: UInt64?

    /// True when a report is due now, in nanoseconds of uptime.
    mutating func due(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        if let last, now < last + Self.interval { return false }
        last = now
        return true
    }
}

/// An open TLS byte stream: one payload transfer or one tunnel.
public final class TLSStream: Sendable {
    public let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
    /// The certificate that the peer presented, when this side is the TLS server.
    public let peerCertificate: [UInt8]?

    init(channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>, peerCertificate: [UInt8]?) {
        self.channel = channel
        self.peerCertificate = peerCertificate
    }

    /// Runs body with the inbound and outbound halves, then closes the stream.
    public func executeThenClose<R: Sendable>(
        _ body: (NIOAsyncChannelInboundStream<ByteBuffer>, NIOAsyncChannelOutboundWriter<ByteBuffer>) async throws -> R
    ) async throws -> R {
        try await channel.executeThenClose { inbound, outbound in try await body(inbound, outbound) }
    }

    /// Closes a stream that is not used. NIO requires that the writer of
    /// each stream finishes, and executeThenClose finishes it.
    public func discard() async {
        do {
            try await executeThenClose { _, _ in }
        } catch {
            FluxLog.net.info("an unused stream did not close cleanly: \(String(describing: error), privacy: .public)")
        }
    }

    /// Reads size bytes into the file, or until the peer closes when size is
    /// negative, and closes the stream.
    public func receive(into handle: FileHandle, size: Int64, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        let done: Int64 = try await executeThenClose { inbound, _ in
            var done: Int64 = 0
            var throttle = ProgressThrottle()
            for try await var buffer in inbound {
                var chunk = buffer.readableBytes
                if size >= 0 { chunk = Int(min(Int64(chunk), size - done)) }
                if let bytes = buffer.readBytes(length: chunk) {
                    try handle.write(contentsOf: bytes)
                }
                done += Int64(chunk)
                if throttle.due() { progress(done) }
                if size >= 0 && done >= size { break }
            }
            return done
        }
        progress(done)
        if size >= 0 && done < size { throw FluxError("payload ended at \(done) of \(size) bytes") }
    }

    /// Writes size bytes from the file, or the file to its end when size is
    /// negative, and closes the stream.
    public func send(from handle: FileHandle, size: Int64, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        let done: Int64 = try await executeThenClose { _, outbound in
            var done: Int64 = 0
            var throttle = ProgressThrottle()
            while size < 0 || done < size {
                let want = size < 0 ? 64 * 1024 : Int(min(64 * 1024, size - done))
                guard let data = try handle.read(upToCount: want), !data.isEmpty else { break }
                try await outbound.write(ByteBuffer(bytes: data))
                done += Int64(data.count)
                if throttle.due() { progress(done) }
            }
            outbound.finish()
            return done
        }
        progress(done)
        if size >= 0 && done < size { throw FluxError("file ended at \(done) of \(size) bytes") }
    }
}

/// A listener that accepts 1 TLS connection. This side is the TLS server, and
/// the peer must present the expected certificate.
///
/// A connection that fails its handshake, that shows another certificate,
/// or that comes after the peer closes alone. The listener waits for the
/// peer until the timeout, so a port scan or a stranger cannot take the
/// transfer. A connection becomes an async channel only after the
/// certificate check, so a closed connection never leaves a writer that
/// NIO requires to finish.
public final class PayloadServer: Sendable {
    public let port: Int
    private let server: Channel
    private let waiter: PayloadWaiter

    /// How long a connection may take for its TLS handshake.
    static let handshakeTimeout: TimeAmount = .seconds(10)
    /// The most connections in their handshake. A new one closes the oldest.
    static let maxPending = 8

    private init(server: Channel, port: Int, waiter: PayloadWaiter) {
        self.server = server
        self.port = port
        self.waiter = waiter
    }

    /// Opens a listener on the first free port in the payload range.
    public static func open(tls: FluxTLS, expected: [UInt8], ports: ClosedRange<Int> = payloadPorts) async throws -> PayloadServer {
        let group = MultiThreadedEventLoopGroup.singleton
        let waiter = PayloadWaiter(promise: group.next().makePromise(of: TLSStream.self))
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    guard waiter.track(ch) else { throw FluxError("the payload listener is closed") }
                    try ch.pipeline.syncOperations.addHandler(tls.serverHandler())
                    try ch.pipeline.syncOperations.addHandler(PayloadGate(expected: expected, waiter: waiter))
                }
            }
        for port in ports {
            if let server = try? await bootstrap.bind(host: "0.0.0.0", port: port).get() {
                return PayloadServer(server: server, port: port, waiter: waiter)
            }
        }
        waiter.end(FluxError("no free payload port"))
        throw FluxError("no free payload port in \(ports)")
    }

    /// Waits for the peer, then closes the listener and the other connections.
    public func accept(timeout: TimeAmount = .seconds(60)) async throws -> TLSStream {
        let timer = server.eventLoop.scheduleTask(in: timeout) { [waiter] in
            waiter.end(FluxError("the computer did not connect in time"))
        }
        defer {
            timer.cancel()
            server.close(promise: nil)
            waiter.end(FluxError("the payload listener is closed"))
        }
        return try await waiter.future.get()
    }

    public func close() {
        server.close(promise: nil)
        waiter.end(FluxError("canceled"))
    }
}

/// The state of 1 payload listener: the connections in their handshake and
/// the 1 stream that it delivers.
private final class PayloadWaiter: @unchecked Sendable {
    private let promise: EventLoopPromise<TLSStream>
    private let lock = NIOLock()
    // Guarded by lock.
    private var done = false
    private var pending: [(id: ObjectIdentifier, channel: Channel)] = []

    init(promise: EventLoopPromise<TLSStream>) { self.promise = promise }

    var future: EventLoopFuture<TLSStream> { promise.futureResult }

    /// Tracks a new connection. It returns false after the listener ended.
    /// With too many connections in their handshake, the oldest closes.
    func track(_ ch: Channel) -> Bool {
        let id = ObjectIdentifier(ch)
        let (kept, evicted) = lock.withLock { () -> (Bool, Channel?) in
            guard !done else { return (false, nil) }
            pending.append((id, ch))
            guard pending.count > PayloadServer.maxPending else { return (true, nil) }
            return (true, pending.removeFirst().channel)
        }
        evicted?.close(promise: nil)
        guard kept else { return false }
        ch.closeFuture.whenComplete { [weak self] _ in self?.untrack(ch) }
        return true
    }

    private func untrack(_ ch: Channel) {
        let id = ObjectIdentifier(ch)
        lock.withLock { pending.removeAll { $0.id == id } }
    }

    /// Delivers the connection of the peer. It runs on the event loop of the
    /// connection, right after the handshake, before any data. A connection
    /// after the first, or after the end, closes.
    func deliver(_ ch: Channel, certificate: [UInt8]) {
        let id = ObjectIdentifier(ch)
        let first = lock.withLock { () -> Bool in
            guard !done else { return false }
            done = true
            pending.removeAll { $0.id == id }
            return true
        }
        guard first else {
            ch.close(promise: nil)
            return
        }
        do {
            let stream = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: ch)
            promise.succeed(TLSStream(channel: stream, peerCertificate: certificate))
        } catch {
            ch.close(promise: nil)
            promise.fail(error)
        }
        closePending()
    }

    /// Ends the wait with the error, unless a stream went out, and closes
    /// the connections in their handshake.
    func end(_ error: Error) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { promise.fail(error) }
        closePending()
    }

    private func closePending() {
        let open = lock.withLock { () -> [Channel] in
            defer { pending = [] }
            return pending.map { $0.channel }
        }
        open.forEach { $0.close(promise: nil) }
    }
}

/// Checks the certificate of 1 payload connection after its TLS handshake.
/// A connection that shows the expected certificate goes to the waiter.
/// Any other connection closes alone.
private final class PayloadGate: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    let expected: [UInt8]
    let waiter: PayloadWaiter
    private var timeout: Scheduled<Void>?
    /// True after the connection went to the waiter as a stream.
    private var delivered = false

    init(expected: [UInt8], waiter: PayloadWaiter) {
        self.expected = expected
        self.waiter = waiter
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        timeout = context.eventLoop.scheduleTask(in: PayloadServer.handshakeTimeout) { channel.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        timeout?.cancel()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent {
            timeout?.cancel()
            timeout = nil
            guard let certificate = context.channel.peerCertificateDER(), certificate == expected else {
                FluxLog.net.info("closed a payload connection from \(context.remoteAddress?.ipAddress ?? "?", privacy: .public) with another certificate")
                context.close(promise: nil)
                return
            }
            // The wrap adds the async handlers now. NIOSSL decodes the data
            // after this event, so no byte is lost.
            delivered = true
            waiter.deliver(context.channel, certificate: certificate)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // The stream reports an error after the delivery. Before it, the
        // connection closes alone.
        if delivered {
            context.fireErrorCaught(error)
        } else {
            context.close(promise: nil)
        }
    }
}

/// Flux tunnels. The computer asks this device to listen, because a firewall
/// on the computer can block incoming connections. This device opens a TLS
/// listener and answers with flux.tunnel {id, port}, or {id, error}. The
/// computer then connects.
public enum Tunnel {
    public static func ready(token: String, port: Int) -> Packet {
        Packet(PacketType.fluxTunnel, ["id": token, "port": port])
    }

    public static func failed(token: String, error: String) -> Packet {
        Packet(PacketType.fluxTunnel, ["id": token, "error": error])
    }

    /// Opens a listener for token, sends flux.tunnel with its port through
    /// announce, and waits for 1 connection from the device with the expected
    /// certificate.
    public static func accept(
        tls: FluxTLS,
        expected: [UInt8],
        token: String,
        announce: (Packet) -> Void,
        timeout: TimeAmount = tunnelTimeout
    ) async throws -> TLSStream {
        let server: PayloadServer
        do {
            server = try await PayloadServer.open(tls: tls, expected: expected)
        } catch {
            announce(failed(token: token, error: String(describing: error)))
            throw error
        }
        announce(ready(token: token, port: server.port))
        return try await server.accept(timeout: timeout)
    }
}
