import Foundation
import NIOCore

/// The encoded stream on its way to the computer. The encoder pushes bytes
/// from its own thread, and 1 task writes them to the TLS stream in order.
/// When the network falls behind by about a second of video, backlogged
/// turns true, and the capture skips frames until the network catches up,
/// as a camera drops frames when its encoder is busy.
final class VideoSink: @unchecked Sendable {
    private let stream: TLSStream
    private let chunks: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let limit: Int
    private let lock = NSLock()
    private var pending = 0

    init(stream: TLSStream, bitrate: Int) {
        self.stream = stream
        (chunks, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        limit = max(bitrate / 8, 256 * 1024)
    }

    func push(_ bytes: [UInt8]) {
        lock.withLock { pending += bytes.count }
        continuation.yield(bytes)
    }

    var backlogged: Bool { lock.withLock { pending > limit } }

    /// Writes the pushed bytes until close, then closes the stream. It throws
    /// when the connection fails, for example because the computer closed it.
    func run() async throws {
        try await stream.executeThenClose { _, outbound in
            for await bytes in chunks {
                try await outbound.write(ByteBuffer(bytes: bytes))
                lock.withLock { pending -= bytes.count }
            }
            outbound.finish()
        }
    }

    /// Closes the connection at once, also in the middle of a write, and
    /// ends run.
    func close() {
        continuation.finish()
        stream.channel.channel.close(promise: nil)
    }
}
