import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// The TCP port range for payload servers and tunnels.
public let payloadPorts: ClosedRange<Int> = 1739...1764

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
public final class PayloadServer: Sendable {
    public let port: Int
    private let server: Channel
    private let accepted: EventLoopPromise<TLSStream>

    private init(server: Channel, port: Int, accepted: EventLoopPromise<TLSStream>) {
        self.server = server
        self.port = port
        self.accepted = accepted
    }

    /// Opens a listener on the first free port in the payload range.
    public static func open(tls: FluxTLS, expected: [UInt8]?, ports: ClosedRange<Int> = payloadPorts) async throws -> PayloadServer {
        let group = MultiThreadedEventLoopGroup.singleton
        let accepted = group.next().makePromise(of: TLSStream.self)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    let handshake = ch.eventLoop.makePromise(of: Void.self)
                    try ch.pipeline.syncOperations.addHandler(tls.serverHandler())
                    try ch.pipeline.syncOperations.addHandler(HandshakeWaiter(promise: handshake))
                    let stream = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: ch)
                    handshake.futureResult.whenComplete { result in
                        switch result {
                        case .success:
                            let cert = ch.peerCertificateDER()
                            if let expected, cert != expected {
                                ch.close(promise: nil)
                                accepted.fail(FluxError("payload peer is not the paired device"))
                            } else {
                                accepted.succeed(TLSStream(channel: stream, peerCertificate: cert))
                            }
                        case .failure(let error):
                            ch.close(promise: nil)
                            accepted.fail(error)
                        }
                    }
                }
            }
        for port in ports {
            if let server = try? await bootstrap.bind(host: "0.0.0.0", port: port).get() {
                return PayloadServer(server: server, port: port, accepted: accepted)
            }
        }
        accepted.fail(FluxError("no free payload port"))
        throw FluxError("no free payload port in \(ports)")
    }

    /// Waits for the peer, then closes the listener.
    public func accept(timeout: TimeAmount = .seconds(60)) async throws -> TLSStream {
        let timer = server.eventLoop.scheduleTask(in: timeout) { [accepted] in
            accepted.fail(FluxError("the computer did not connect in time"))
        }
        defer {
            timer.cancel()
            server.close(promise: nil)
        }
        return try await accepted.futureResult.get()
    }

    public func close() {
        accepted.fail(FluxError("canceled"))
        server.close(promise: nil)
    }
}

/// Payload transfer. The sender listens on a port and is the TLS server. The
/// receiver connects and is the TLS client.
public enum Payload {
    /// Connects to the sender at host:port.
    public static func connect(tls: FluxTLS, host: String, port: Int) async throws -> TLSStream {
        let stream = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(10))
            .connect(host: host, port: port) { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(try tls.clientHandler())
                    return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: ch)
                }
            }
        return TLSStream(channel: stream, peerCertificate: nil)
    }
}

/// Flux tunnels. When the computer blocks incoming connections, it asks this
/// device to listen. This device opens a TLS listener and answers with
/// flux.tunnel {id, port}, or {id, error}. The computer then connects.
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
