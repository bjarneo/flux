import Foundation
import NIOCore
import NIOPosix

/// Bridges a TLS stream to a new listener on 127.0.0.1, so that a library
/// that opens its own TCP connection can use the stream. The bridge accepts
/// 1 connection and closes when either side closes.
final class LoopbackBridge: Sendable {
    let host = "127.0.0.1"
    let port: Int
    private let server: Channel
    private let remote: TLSStream

    private init(server: Channel, port: Int, remote: TLSStream) {
        self.server = server
        self.port = port
        self.remote = remote
    }

    /// Opens the listener and starts to wait for the 1 local connection.
    static func open(_ remote: TLSStream, acceptTimeout: TimeAmount = .seconds(10)) async throws -> LoopbackBridge {
        let listener: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
        do {
            listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(.backlog, value: 1)
                .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
                .bind(host: "127.0.0.1", port: 0) { ch in
                    ch.eventLoop.makeCompletedFuture { try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: ch) }
                }
        } catch {
            remote.channel.channel.close(promise: nil)
            throw error
        }
        let bridge = LoopbackBridge(server: listener.channel, port: listener.channel.localAddress?.port ?? 0, remote: remote)
        let timer = listener.channel.eventLoop.scheduleTask(in: acceptTimeout) { [server = listener.channel] in
            server.close(promise: nil)
        }
        Task {
            let local = try? await listener.executeThenClose { inbound, _ -> NIOAsyncChannel<ByteBuffer, ByteBuffer>? in
                var accepted = inbound.makeAsyncIterator()
                return try await accepted.next()
            }
            timer.cancel()
            if let local { try? await pipe(remote, local) }
            bridge.close()
        }
        return bridge
    }

    /// Copies bytes both ways until one side ends, then closes both.
    private static func pipe(_ remote: TLSStream, _ local: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async throws {
        try await remote.executeThenClose { remoteIn, remoteOut in
            try await local.executeThenClose { localIn, localOut in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { for try await chunk in remoteIn { try await localOut.write(chunk) } }
                    group.addTask { for try await chunk in localIn { try await remoteOut.write(chunk) } }
                    try await group.next()
                    group.cancelAll()
                }
            }
        }
    }

    /// Closes the listener and the tunnel. The local connection ends with them.
    func close() {
        server.close(promise: nil)
        remote.channel.channel.close(promise: nil)
    }
}
