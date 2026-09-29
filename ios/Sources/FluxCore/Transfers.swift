import Foundation
import FluxProto
import FluxNet
#if canImport(Security)
import Security

/// M3 file transfers + browse-tunnel plumbing.
///
/// Mirrors Go `internal/core/share.go` (`receiveFile`: `.part` + rename,
/// exact-size check, `uniquePath`/`safeName`; `sendFile`/`SendFiles`:
/// `share.update` preamble + one announcement per file) and Android
/// `core/Share.kt` (`receive`/`download` on `core.io`, `sendFiles`,
/// `sendCapture`) + `net/Tunnel.kt` (`receive`: listen + `ready`, `failed`
/// on save errors).
///
/// Threading: the session thread never blocks on transfers — every method
/// below hops to the engine's serial queue (Android `core.io` parity) and
/// reports through `onEvent`. Outbound packets go through `LinkSender`,
/// which serializes TLS writes across the session + transfer threads
/// (Android `Link` reader/writer split: one reader, lock-serialized
/// writers).
public enum TransferEvent: Sendable {
    case progress(filename: String, done: Int64, size: Int64)
    case completed(filename: String, path: String, bytes: Int64)
    case failed(filename: String, error: String)
    case browseReady(tunnel: String)
    case browseFailed(tunnel: String?, error: String)
}

/// Serializes all TLS writes on one link. The session thread and every
/// transfer thread share one sender; reads stay on the session thread.
public final class LinkSender: @unchecked Sendable {
    private let lock = NSLock()
    private let conn: TLSConnection

    public init(_ conn: TLSConnection) { self.conn = conn }

    /// Serializes + writes a packet. Never throws (Go `l.Send` errors are
    /// logged at the call site; the harness logs via the return value).
    @discardableResult
    public func send(_ packet: Packet) -> Bool {
        lock.withLock {
            do {
                try conn.write(try packet.serialize())
                return true
            } catch {
                return false
            }
        }
    }
}

/// Published session sender for app-originated packets (D23,
/// `LinkRunner.liveSend`). The runner publishes its `LinkSender` once the
/// TLS session is up and clears it when the session ends; `LinkService`
/// fans app packets out over every live runner. Unit-testable without a
/// socket (publish a closure, no session needed).
public final class LiveSendBox: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var impl: ((Packet) -> Bool)?

    public init() {}

    /// Publishes the session sender. The closure must stay
    /// lock-serialized with the session's other writers — pass
    /// `{ sender.send($0) }` over the session's `LinkSender`, which
    /// already serializes.
    public func publish(_ send: @escaping (Packet) -> Bool) {
        lock.withLock { impl = send }
    }

    /// Withdraws the sender (session ended). Sends after this fail.
    public func clear() {
        lock.withLock { impl = nil }
    }

    /// Sends on the published session. False when no session is up.
    @discardableResult
    public func send(_ packet: Packet) -> Bool {
        let current = lock.withLock { self.impl }
        return current?(packet) ?? false
    }
}

/// Published live-stream inlet for app-originated streams (D16,
/// `LinkRunner.liveStreams`). The runner attaches its `StreamEngine` once
/// the TLS session is up and detaches when it ends; `LinkService` fans
/// app offers/stops out over every live runner. Offers posted before the
/// attach are held per kind (replacing) and served on attach — a UI Start
/// tap racing session setup is delayed, never dropped. Unit-testable
/// without a socket up to the engine boundary (the engine itself is
/// loopback-covered in `StreamLiveTests`).
public final class LiveStreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var engine: StreamEngine?
    private nonisolated(unsafe) var pending: [StreamKind: LiveOffer] = [:]

    public init() {}

    /// Attaches the session engine and serves anything held. Called on
    /// the session thread once per connection.
    public func attach(_ engine: StreamEngine) {
        let held = lock.withLock { () -> [StreamKind: LiveOffer] in
            self.engine = engine
            let held = self.pending
            self.pending.removeAll()
            return held
        }
        for offer in held.values { engine.serveLive(offer) }
    }

    /// Detaches the engine, stopping every live stream without announcing
    /// (the session is gone; stop packets would fail anyway).
    public func detach() {
        let current = lock.withLock { () -> StreamEngine? in
            let current = self.engine
            self.engine = nil
            self.pending.removeAll()
            return current
        }
        current?.stopAllLive()
    }

    /// Serves a live offer on the attached engine, or holds it per kind
    /// until the attach. Always accepted (presence, not readiness, is the
    /// gate — `LinkService` reports false with no session at all).
    public func serve(_ offer: LiveOffer) {
        let current = lock.withLock { () -> StreamEngine? in
            if let current = self.engine { return current }
            self.pending[offer.kind] = offer
            return nil
        }
        current?.serveLive(offer)
    }

    /// Stops a live stream (and drops anything held for the kind).
    public func stop(kind: StreamKind, announce: Bool = true) {
        let current = lock.withLock { () -> StreamEngine? in
            self.pending.removeValue(forKey: kind)
            return self.engine
        }
        current?.stopLive(kind: kind, announce: announce)
    }
}

/// Published upload inlet for app-originated files/captures (D15/D18,
/// `LinkRunner.liveUploads`). The runner attaches its `TransferEngine` once
/// the TLS session is up and detaches when it ends; `LinkService` fans app
/// `sendFiles`/`sendCaptures` out over every live runner (the D23 packet
/// pattern, but for uploads: the engine owns the payload listeners, so the
/// box holds the engine, not a closure). Uploads posted before the attach
/// are held (replacing batch) and served on attach — a capture tap racing
/// session setup is delayed, never dropped. Unit-testable without a socket
/// up to the engine boundary (the engine itself is loopback-covered in
/// `TransferUploadTests` + the M5 harness).
public final class LiveUploadBox: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var engine: TransferEngine?
    private nonisolated(unsafe) var heldFiles: [URL]?
    private nonisolated(unsafe) var heldCaptures: [TransferEngine.CaptureUpload]?

    public init() {}

    /// Attaches the session engine and serves anything held. Called on
    /// the session thread once per connection.
    public func attach(_ engine: TransferEngine) {
        let (files, captures) = lock.withLock { () -> ([URL]?, [TransferEngine.CaptureUpload]?) in
            self.engine = engine
            let files = self.heldFiles
            let captures = self.heldCaptures
            self.heldFiles = nil
            self.heldCaptures = nil
            return (files, captures)
        }
        if let files { engine.sendFiles(files) }
        if let captures { engine.sendCaptures(captures) }
    }

    /// Detaches the engine and drops anything held (the session is gone;
    /// announcements would fail anyway).
    public func detach() {
        lock.withLock {
            self.engine = nil
            self.heldFiles = nil
            self.heldCaptures = nil
        }
    }

    /// Sends local files on the attached engine, or holds them until the
    /// attach. False only when no session exists at all (`LinkService`
    /// reports false with no runners — the caller shows offline instead).
    @discardableResult
    public func sendFiles(_ paths: [URL]) -> Bool {
        let current = lock.withLock { () -> TransferEngine? in
            if let current = self.engine { return current }
            self.heldFiles = (self.heldFiles ?? []) + paths
            return nil
        }
        if let current { current.sendFiles(paths); return true }
        return true
    }

    /// Sends camera captures on the attached engine, or holds them until
    /// the attach. See `sendFiles` for the presence contract.
    @discardableResult
    public func sendCaptures(_ items: [TransferEngine.CaptureUpload]) -> Bool {
        let current = lock.withLock { () -> TransferEngine? in
            if let current = self.engine { return current }
            self.heldCaptures = (self.heldCaptures ?? []) + items
            return nil
        }
        if let current { current.sendCaptures(items); return true }
        return true
    }

    /// True while a session engine is attached (for tests/diagnostics).
    public var attached: Bool {
        lock.withLock { engine != nil }
    }
}

/// Throttles progress callbacks to at most 4/s with a final report
/// (Go `Daemon.progress`: 250 ms tick + `markDirty`).
struct ProgressGate {
    private var last = Date.distantPast

    mutating func allow(done: Int64, size: Int64) -> Bool {
        if done >= size { last = Date(); return true }
        return allowLive(done: done)
    }

    /// Tick-only gate for live streams (total unknown — no final report;
    /// `.done` closes the stream instead).
    mutating func allowLive(done: Int64) -> Bool {
        _ = done
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.25 else { return false }
        last = now
        return true
    }
}

/// Established browse tunnels waiting for the SSH session layer.
/// Keyed by the desktop's tunnel id (`sftp` offer `tunnel` field).
final class BrowseTunnels: @unchecked Sendable {
    private let lock = NSLock()
    private var tunnels: [String: TLSConnection] = [:]

    func put(_ id: String, _ conn: TLSConnection) {
        lock.withLock { tunnels[id] = conn }
    }

    func take(_ id: String) -> TLSConnection? {
        lock.withLock { tunnels.removeValue(forKey: id) }
    }

    func closeAll() {
        let all = lock.withLock { tunnels.values.map { $0 } }
        lock.withLock { tunnels.removeAll() }
        all.forEach { $0.close() }
    }
}

/// One link's file-transfer engine. Created per connection (it captures
/// the link's identity, pinned peer certificate, and a lock-serialized
/// send closure — `{ sender.send($0) }` over the session's `LinkSender`,
/// same contract as `StreamEngine`).
public final class TransferEngine: @unchecked Sendable {
    private let identity: SecIdentity
    private let peerDER: Data
    private let send: @Sendable (Packet) -> Bool
    private let downloadsDir: URL
    private let onEvent: (TransferEvent) -> Void
    private let queue = DispatchQueue(label: "org.omarchy.flux.transfers")
    private let browseTunnels = BrowseTunnels()

    public init(
        identity: SecIdentity, peerDER: Data,
        send: @escaping @Sendable (Packet) -> Bool,
        downloadsDir: URL, onEvent: @escaping (TransferEvent) -> Void
    ) {
        self.identity = identity
        self.peerDER = peerDER
        self.send = send
        self.downloadsDir = downloadsDir
        self.onEvent = onEvent
    }

    // MARK: - Receive (desktop→phone)

    /// Fetches one announced file off-thread. `host` is the link peer's
    /// IP (classic fetch dials back to it). A `tunnel` token means the
    /// desktop waits for our `flux.tunnel ready` (Go `pushPayload`); a
    /// `port` means it listens for our fetch (Go `SendWithPayload`).
    public func receive(_ file: ShareFile, host: String) {
        queue.async { [self] in self.fetch(file, host: host) }
    }

    /// Drains queued announcements (e.g. `PendingShareStore.takeAll()`)
    /// through the same fetch path, in order.
    public func receiveAll(_ files: [ShareFile], host: String) {
        queue.async { [self] in
            for f in files { self.fetch(f, host: host) }
        }
    }

    private func fetch(_ file: ShareFile, host: String) {
        let name = file.filename.isEmpty ? "file" : file.filename
        onEvent(.progress(filename: name, done: 0, size: file.payloadSize))
        do {
            let dest = try prepareDestination(filename: name)
            let part = dest.appendingPathExtension("part")
            if let token = file.payloadTunnel {
                try fetchViaTunnel(file, name: name, dest: dest, part: part, token: token)
            } else if file.payloadPort > 0 {
                try fetchClassic(file, name: name, dest: dest, part: part, host: host)
            } else {
                throw Payload.Error.ioFailed(EINVAL)
            }
            try FileManager.default.moveItem(at: part, to: dest)
            onEvent(.completed(filename: name, path: dest.path, bytes: file.payloadSize))
        } catch {
            if let token = file.payloadTunnel {
                send(TunnelPackets.failed(token: token, error: String(describing: error)))
            }
            onEvent(.failed(filename: name, error: String(describing: error)))
        }
    }

    private func fetchClassic(_ file: ShareFile, name: String, dest: URL, part: URL, host: String) throws {
        guard let stream = OutputStream(url: part, append: false) else {
            throw Payload.Error.ioFailed(EIO)
        }
        var gate = ProgressGate()
        let report: (Int64) -> Void = { [self] done in
            if gate.allow(done: done, size: file.payloadSize) {
                self.onEvent(.progress(filename: name, done: done, size: file.payloadSize))
            }
        }
        try Payload.fetch(
            host: host, port: file.payloadPort, size: file.payloadSize,
            identity: identity, expectedPeerDER: peerDER,
            output: stream, progress: report)
    }

    private func fetchViaTunnel(_ file: ShareFile, name: String, dest: URL, part: URL, token: String) throws {
        let listener: Payload.Listener
        do {
            listener = try Payload.listen()
        } catch {
            send(TunnelPackets.failed(token: token, error: "no free port"))
            throw error
        }
        send(TunnelPackets.ready(token: token, port: listener.port))
        let conn: TLSConnection
        do {
            conn = try Payload.acceptTunnel(listener, identity: identity, expectedPeerDER: peerDER)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
        defer { conn.close() }
        guard let stream = OutputStream(url: part, append: false) else {
            send(TunnelPackets.failed(token: token, error: "cannot save the file"))
            throw Payload.Error.ioFailed(EIO)
        }
        var gate = ProgressGate()
        let report: (Int64) -> Void = { [self] done in
            if gate.allow(done: done, size: file.payloadSize) {
                self.onEvent(.progress(filename: name, done: done, size: file.payloadSize))
            }
        }
        do {
            try Payload.receive(from: conn, size: file.payloadSize, output: stream, progress: report)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    // MARK: - Send (phone→desktop, always classic)

    /// One camera capture to upload: the file plus the routing flags Go
    /// `handleShare` reads (`scan` → `scan_dir`, `photo` → `photo_dir`,
    /// `screenshot` + `photo` → the screenshots folder — Android
    /// `Share.sendCapture` sends the same map).
    public struct CaptureUpload: Sendable {
        public var url: URL
        public var scan: Bool
        public var photo: Bool
        public var screenshot: Bool

        public init(url: URL, scan: Bool = false, photo: Bool = false, screenshot: Bool = false) {
            self.url = url
            self.scan = scan
            self.photo = photo
            self.screenshot = screenshot
        }
    }

    /// Sends local files: `share.update` preamble, then one announcement
    /// + payload server per file (Go `SendFiles`, Android `sendFiles`).
    /// Directories are refused like Go's `is_dir` error.
    public func sendFiles(_ paths: [URL], numberOfFiles: Int? = nil) {
        queue.async { [self] in
            var items: [(url: URL, size: Int64)] = []
            for path in paths {
                guard let size = self.fileSize(path) else { continue }
                items.append((path, size))
            }
            guard !items.isEmpty else { return }
            let total = items.reduce(0) { $0 + $1.size }
            let count = numberOfFiles ?? items.count
            self.send(ShareMessage.updatePacket(numberOfFiles: count, totalPayloadSize: total))
            for (url, size) in items {
                self.serveOne(url: url, size: size, count: count, total: total)
            }
        }
    }

    /// Sends camera captures with their routing flags (Android
    /// `sendCapture` parity). Same preamble + classic servers as files.
    public func sendCaptures(_ items: [CaptureUpload]) {
        queue.async { [self] in
            var sized: [(upload: CaptureUpload, size: Int64)] = []
            for item in items {
                guard let size = self.fileSize(item.url) else { continue }
                sized.append((item, size))
            }
            guard !sized.isEmpty else { return }
            let total = sized.reduce(0) { $0 + $1.size }
            self.send(ShareMessage.updatePacket(numberOfFiles: sized.count, totalPayloadSize: total))
            for (item, size) in sized {
                var extra: [(String, Any?)] = []
                if item.scan { extra.append(("scan", true)) }
                if item.photo { extra.append(("photo", true)) }
                if item.screenshot { extra.append(("screenshot", true)) }
                self.serveOne(url: item.url, size: size, count: sized.count, total: total, extra: extra)
            }
        }
    }

    private func fileSize(_ path: URL) -> Int64? {
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir),
              !isDir.boolValue
        else {
            self.onEvent(.failed(filename: path.lastPathComponent, error: "not a file"))
            return nil
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
        let size: Int64? = {
            switch attrs?[.size] {
            case let n as Int64: return n
            case let n as Int: return Int64(n)
            case let n as NSNumber: return n.int64Value
            default: return nil
            }
        }()
        guard let size, size >= 0 else {
            self.onEvent(.failed(filename: path.lastPathComponent, error: "cannot stat file"))
            return nil
        }
        return size
    }

    private func serveOne(url: URL, size: Int64, count: Int, total: Int64, extra: [(String, Any?)] = []) {
        let name = url.lastPathComponent
        onEvent(.progress(filename: name, done: 0, size: size))
        do {
            let listener = try Payload.listen()
            send(ShareMessage.filePacket(
                filename: name, numberOfFiles: count, totalPayloadSize: total,
                payloadSize: size, payloadPort: listener.port, extra: extra))
            let conn = try Payload.acceptPayload(listener, identity: identity, expectedPeerDER: peerDER)
            defer { conn.close() }
            guard let input = InputStream(url: url) else { throw Payload.Error.ioFailed(EIO) }
            var gate = ProgressGate()
            try Payload.serve(conn, input: input, size: size) { [self] done in
                if gate.allow(done: done, size: size) {
                    self.onEvent(.progress(filename: name, done: done, size: size))
                }
            }
            onEvent(.completed(filename: name, path: url.path, bytes: size))
        } catch {
            onEvent(.failed(filename: name, error: String(describing: error)))
        }
    }

    // MARK: - Browse (phone browses desktop, read-only v1)

    /// Answers an `sftp` tunnel offer: opens the listener, sends
    /// `flux.tunnel ready`, and holds the established TLS connection for
    /// the SSH session layer (`takeBrowseTunnel`). Classic `ip`+`port`
    /// offers need no listener — the SSH layer dials them directly.
    ///
    /// SSH decision (plan §12 Q4): `apple/swift-nio-ssh` (Apache-2.0,
    /// same NIO family the plan already names in §5) is the pick when a
    /// dependency can be vendored; `Citadel` (MIT, NIOSSH wrapper) is the
    /// fallback; `libssh2` is out (C XCFramework interop). No dependency
    /// is vendored in M3, so the SSH channel + SFTP list/download ride
    /// here as a documented seam: the tunnel below is real and E2E-held,
    /// the bytes inside it start in M4+.
    public func openBrowseTunnel(_ offer: SftpOffer) {
        queue.async { [self] in
            guard let token = offer.tunnel else { return }
            let listener: Payload.Listener
            do {
                listener = try Payload.listen()
            } catch {
                self.send(TunnelPackets.failed(token: token, error: "no free port"))
                self.onEvent(.browseFailed(tunnel: token, error: "no free port"))
                return
            }
            self.send(TunnelPackets.ready(token: token, port: listener.port))
            do {
                let conn = try Payload.acceptTunnel(listener, identity: self.identity, expectedPeerDER: self.peerDER)
                self.browseTunnels.put(token, conn)
                self.onEvent(.browseReady(tunnel: token))
            } catch {
                self.onEvent(.browseFailed(tunnel: token, error: String(describing: error)))
            }
        }
    }

    /// Takes an established browse tunnel for the SSH layer (nil when the
    /// desktop never connected). The caller owns the connection.
    public func takeBrowseTunnel(_ id: String) -> TLSConnection? {
        browseTunnels.take(id)
    }

    public func closeBrowseTunnels() {
        browseTunnels.closeAll()
    }

    // MARK: - Destination

    private func prepareDestination(filename: String) throws -> URL {
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        return TransferEngine.uniqueDestination(directory: downloadsDir, filename: filename)
    }

    /// Non-clobbering destination (Go `uniquePath`: `name (2).ext`,
    /// `name (3).ext`, …). The name is already `sanitize`d by the parser.
    /// Public for browse downloads (the app stages into Downloads with
    /// the same rule as `TransferEngine` receives).
    public static func uniqueDestination(directory: URL, filename: String) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let next = directory.appendingPathComponent("\(base) (\(i))").appendingPathExtension(ext)
            // appendingPathExtension("") appends "." — rebuild instead.
            let fixed: URL = ext.isEmpty
                ? directory.appendingPathComponent("\(base) (\(i))")
                : next
            if !FileManager.default.fileExists(atPath: fixed.path) { return fixed }
            i += 1
        }
    }

    /// Default receive folder: `Application Support/Downloads/`
    /// (Android `Downloads/` parity; Go `download_dir` parity).
    public static func defaultDownloadsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Downloads")
    }
}
#endif
