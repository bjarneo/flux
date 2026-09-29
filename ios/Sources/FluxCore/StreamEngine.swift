import Foundation
import FluxProto
import FluxNet
#if canImport(Security)
import Security
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Phone-side stream serving: webcam H.264, mic PCM, screen H.264.
///
/// Mirrors Android `stream/PinnedStream.kt` (`accept`: listen, announce the
/// port, wait for the paired computer, pin its certificate) + the byte
/// pumps of `mic/MicSession.kt` (`record`), `webcam/H264Encoder.kt`
/// (`drainLoop`), and `screen/ScreenMirrorService.kt`.
///
/// Threading: like `TransferEngine` — the session thread never blocks.
/// Fixed offers run on the engine's serial queue (Android `core.io`
/// parity); live offers run as per-kind tasks with connection I/O
/// serialized through a `LiveChannel` (a stop racing an in-flight write
/// corrupts the SecureTransport heap — the channel is the fix). Both
/// report through `onEvent`. Outbound packets go through the send
/// closure.
public enum StreamEvent: Sendable {
    case started(kind: StreamKind, port: Int)
    case progress(kind: StreamKind, done: Int64, size: Int64)
    case done(kind: StreamKind, bytes: Int64, sha256: String)
    case failed(kind: StreamKind, error: String)
}

/// One stream to serve: the `start` packet builder (it needs the bound
/// port), an optional follow-up (webcam sends `config` right after `start`,
/// Android `WebcamSession` parity), and the bytes.
public struct StreamOffer: Sendable {
    public var kind: StreamKind
    public var buildStart: @Sendable (Int) -> Packet
    public var followUp: Packet?
    public var bytes: Data
    /// Sends the kind's `stop` after the bytes (harness user-stop
    /// semantics; the app stops explicitly through `StreamSession`).
    public var announceStop: Bool

    public init(
        kind: StreamKind,
        buildStart: @escaping @Sendable (Int) -> Packet,
        followUp: Packet? = nil,
        bytes: Data,
        announceStop: Bool = false
    ) {
        self.kind = kind
        self.buildStart = buildStart
        self.followUp = followUp
        self.bytes = bytes
        self.announceStop = announceStop
    }
}

/// One live stream to serve: same `start`/follow-up handshake as
/// `StreamOffer`, but the bytes arrive incrementally from a producer
/// (AVAudioEngine tap, VideoToolbox drain, ReplayKit samples) instead of
/// a fixed blob. The stream ends when `chunks` finishes (normal `.done`)
/// or when `stopLive` cancels it (silent — the stop packet is the
/// signal). Replaces any live stream of the same kind.
public struct LiveOffer: Sendable {
    public var kind: StreamKind
    public var buildStart: @Sendable (Int) -> Packet
    public var followUp: Packet?
    public var chunks: AsyncStream<Data>
    /// Sends the kind's `stop` when the producer finishes (harness
    /// semantics; the app stops explicitly and passes `announce: false`
    /// for desktop-initiated stops).
    public var announceStop: Bool

    public init(
        kind: StreamKind,
        buildStart: @escaping @Sendable (Int) -> Packet,
        followUp: Packet? = nil,
        chunks: AsyncStream<Data>,
        announceStop: Bool = false
    ) {
        self.kind = kind
        self.buildStart = buildStart
        self.followUp = followUp
        self.chunks = chunks
        self.announceStop = announceStop
    }
}

/// Serializes one live stream's connection I/O. SecureTransport contexts
/// are not thread-safe and `close()` re-closes the fd, so a stop racing
/// an in-flight write corrupts the heap (seen on-device as a malloc
/// "pointer being freed was not allocated" crash on mic Stop,
/// 2026-09-27 — every prior close was same-thread). Every op funnels
/// through one serial queue; `close` runs once. A blocked writer delays
/// a concurrent close by one chunk at most (64 KiB); the writer never
/// waits on the closer, so no deadlock.
final class LiveChannel {
    private let conn: TLSConnection
    private let io = DispatchQueue(label: "org.omarchy.flux.stream-io")
    private var closed = false // guarded by io

    init(_ conn: TLSConnection) { self.conn = conn }

    func write(_ data: Data) throws {
        try io.sync {
            if closed { throw TLSConnection.Error.closed }
            try conn.write(data)
        }
    }

    func close() {
        io.sync {
            if !closed {
                closed = true
                conn.close()
            }
        }
    }
}

/// Serves phone→desktop streams on one link. Created per connection (it
/// captures the link's identity, pinned peer certificate, and a
/// lock-serialized send closure — `{ sender.send($0) }` over the session's
/// `LinkSender`, same contract as `LiveSendBox.publish`).
public final class StreamEngine: @unchecked Sendable {
    private let identity: SecIdentity
    private let peerDER: Data
    private let send: @Sendable (Packet) -> Bool
    private let onEvent: (StreamEvent) -> Void
    private let queue = DispatchQueue(label: "org.omarchy.flux.streams")
    /// Live streams run off the serial queue (a live serve never returns
    /// on its own): one task + connection per kind, replaced on re-serve,
    /// cancelled on stop or detach.
    private let liveLock = NSLock()
    private nonisolated(unsafe) var liveTasks: [StreamKind: Task<Void, Never>] = [:]
    private nonisolated(unsafe) var liveConns: [StreamKind: LiveChannel] = [:]
    /// Listeners are tracked so `stopLive` unblocks a serve still waiting
    /// in `accept` (cancelling the task alone cannot interrupt BSD accept).
    private nonisolated(unsafe) var liveListeners: [StreamKind: Payload.Listener] = [:]

    public init(
        identity: SecIdentity, peerDER: Data,
        send: @escaping @Sendable (Packet) -> Bool,
        onEvent: @escaping (StreamEvent) -> Void
    ) {
        self.identity = identity
        self.peerDER = peerDER
        self.send = send
        self.onEvent = onEvent
    }

    /// Serves the offers one after another, in order.
    public func serve(_ offers: [StreamOffer]) {
        queue.async { [self] in
            for offer in offers { self.serveOne(offer) }
        }
    }

    /// Serves a live offer, replacing any live stream of the same kind
    /// (the old connection is closed; its task is cancelled silently).
    public func serveLive(_ offer: LiveOffer) {
        stopLive(kind: offer.kind, announce: false)
        let task = Task<Void, Never> { [weak self] in await self?.serveLiveOne(offer) }
        liveLock.withLock { liveTasks[offer.kind] = task }
    }

    /// Stops a live stream. An announced stop sends the kind's `stop`
    /// packet FIRST so the desktop stops reading before its end goes
    /// away (a close with bytes in flight reads as RST, which the desktop
    /// reports as an error); then the task is cancelled and the listener
    /// + connection closed. Unannounced stops (desktop already stopped,
    /// session gone) just tear down.
    public func stopLive(kind: StreamKind, announce: Bool = true) {
        if announce { send(kind.stopPacket()) }
        let (task, channel, listener): (Task<Void, Never>?, LiveChannel?, Payload.Listener?) = liveLock.withLock {
            (liveTasks.removeValue(forKey: kind),
             liveConns.removeValue(forKey: kind),
             liveListeners.removeValue(forKey: kind))
        }
        task?.cancel()
        if let listener { Sockets.close(listener.fd) }
        channel?.close()
    }

    /// Stops every live stream without announcing (session ended; the
    /// sender is dead, so stop packets would fail anyway).
    public func stopAllLive() {
        for kind in StreamKind.allCases { stopLive(kind: kind, announce: false) }
    }

    private func serveOne(_ offer: StreamOffer) {
        let listener: Payload.Listener
        do {
            listener = try Payload.listen()
        } catch {
            onEvent(.failed(kind: offer.kind, error: "no free port"))
            return
        }
        guard send(offer.buildStart(listener.port)) else {
            Sockets.close(listener.fd)
            onEvent(.failed(kind: offer.kind, error: "not connected"))
            return
        }
        if let followUp = offer.followUp {
            send(followUp)
        }
        onEvent(.started(kind: offer.kind, port: listener.port))
        do {
            // 10 s like Android CONNECT_TIMEOUT_MS; the pinned-peer check
            // is the same as browse/payload listeners (Go DialPeer parity).
            let conn = try Payload.acceptTunnel(listener, identity: identity, expectedPeerDER: peerDER, timeout: 10)
            defer { conn.close() }
            var gate = ProgressGate()
            var done: Int64 = 0
            let total = Int64(offer.bytes.count)
            try offer.bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < offer.bytes.count {
                    let n = min(64 * 1024, offer.bytes.count - offset)
                    try conn.write(Data(bytes: raw.baseAddress!.advanced(by: offset), count: n))
                    offset += n
                    done = Int64(offset)
                    if gate.allow(done: done, size: total) {
                        self.onEvent(.progress(kind: offer.kind, done: done, size: total))
                    }
                }
            }
            onEvent(.done(kind: offer.kind, bytes: done, sha256: sha256Hex(offer.bytes)))
            if offer.announceStop {
                send(offer.kind.stopPacket())
            }
        } catch {
            onEvent(.failed(kind: offer.kind, error: String(describing: error)))
        }
    }

    /// Serves one live offer: same handshake as `serveOne`, then chunks
    /// until the producer finishes, the task is cancelled, or a write
    /// fails. Progress carries `size: -1` (total unknown — the app shows
    /// bytes-so-far); `.done` carries the incremental SHA-256 over every
    /// chunk served. Cancellation is silent (the stop packet, if any, is
    /// the caller's `stopLive(announce:)` decision, not ours).
    private func serveLiveOne(_ offer: LiveOffer) async {
        let listener: Payload.Listener
        do {
            listener = try Payload.listen()
        } catch {
            onEvent(.failed(kind: offer.kind, error: "no free port"))
            return
        }
        liveLock.withLock { liveListeners[offer.kind] = listener }
        defer {
            // Same replace-race guard as the connection registry below.
            liveLock.withLock {
                if liveListeners[offer.kind]?.port == listener.port {
                    liveListeners.removeValue(forKey: offer.kind)
                }
            }
        }
        guard send(offer.buildStart(listener.port)) else {
            Sockets.close(listener.fd)
            onEvent(.failed(kind: offer.kind, error: "not connected"))
            return
        }
        if let followUp = offer.followUp {
            send(followUp)
        }
        onEvent(.started(kind: offer.kind, port: listener.port))
        do {
            let conn = try Payload.acceptTunnel(listener, identity: identity, expectedPeerDER: peerDER, timeout: 10)
            // The listener is consumed by the accept (`acceptTunnel`
            // closes it): drop the registration so a later `stopLive`
            // cannot close the recycled fd number out from under a live
            // socket — that reads as RST on the desktop (seen on-device
            // as a phantom mic error, 2026-09-27).
            let channel = LiveChannel(conn)
            liveLock.withLock {
                liveListeners.removeValue(forKey: offer.kind)
                liveConns[offer.kind] = channel
            }
            defer {
                // Close only our own registration: a replacing serve may
                // already have registered its channel under this kind.
                // `close` is idempotent, so a racing `stopLive` is safe.
                liveLock.withLock {
                    if liveConns[offer.kind] === channel { liveConns.removeValue(forKey: offer.kind) }
                }
                channel.close()
            }
            var gate = ProgressGate()
            var digest = LiveDigest()
            var done: Int64 = 0
            for await chunk in offer.chunks {
                if Task.isCancelled { return }
                var offset = 0
                while offset < chunk.count {
                    let n = min(64 * 1024, chunk.count - offset)
                    let piece = chunk.subdata(in: offset..<offset + n)
                    try channel.write(piece)
                    digest.update(piece)
                    offset += n
                    done += Int64(n)
                }
                if gate.allowLive(done: done) {
                    onEvent(.progress(kind: offer.kind, done: done, size: -1))
                }
            }
            if Task.isCancelled { return }
            onEvent(.done(kind: offer.kind, bytes: done, sha256: digest.hex()))
            if offer.announceStop {
                send(offer.kind.stopPacket())
            }
        } catch {
            if !Task.isCancelled {
                onEvent(.failed(kind: offer.kind, error: String(describing: error)))
            }
        }
    }
}

/// Incremental SHA-256 over served chunks (a live stream has no fixed
/// `Data` to hash at the end). CryptoKit path is unconditional on the
/// supported floors (iOS 17+/macOS 14+); the fallback mirrors the
/// `sha256Hex` shape for hypothetical platforms without it.
struct LiveDigest {
    #if canImport(CryptoKit)
    private var hasher = SHA256()
    #else
    private var count = 0
    private var mix = 0
    #endif

    mutating func update(_ chunk: Data) {
        #if canImport(CryptoKit)
        hasher.update(data: chunk)
        #else
        count += chunk.count
        for b in chunk.prefix(64) { mix = mix &* 31 &+ Int(b) }
        #endif
    }

    func hex() -> String {
        #if canImport(CryptoKit)
        if #available(macOS 10.15, iOS 13, *) {
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } else {
            return "unavailable"
        }
        #else
        return String(format: "%08x%08x", count, mix)
        #endif
    }
}

private func sha256Hex(_ data: Data) -> String {
    #if canImport(CryptoKit)
    if #available(macOS 10.15, iOS 13, *) {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    #endif
    // Fallback fingerprint when CryptoKit is unavailable (never on the
    // supported platforms; keeps the event shape stable).
    return String(format: "%08x%08x", data.count, data.prefix(4).reduce(0) { $0 * 31 + Int($1) })
}
#endif
