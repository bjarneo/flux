// Citadel 0.9.2 is not Sendable-annotated: every Citadel value stays
// inside the `BrowseSession` actor below, and only `BrowseEntry`/`Data`
/// counts cross isolation boundaries.
@preconcurrency import Citadel
import Darwin
import Foundation
import NIO
import FluxNet
import FluxProto

/// D1 browse errors. Messages carry the underlying cause for the status
/// line + `flux:` console (never secrets — the password never appears).
public enum BrowseError: Error, Equatable {
    case noSession
    case bridgeFailed(String)
    case connectFailed(String)
    case listFailed(String)
    case downloadFailed(String)

    /// True when the SSH channel underneath is dead and the session must
    /// be dropped (the next tap reopens for a fresh tunnel — never a
    /// silent instant-refail on the corpse). Citadel reports a dead
    /// channel as `SFTPError.connectionClosed`; file-level failures
    /// (missing file, permissions) leave a live session alone.
    public var isSessionDead: Bool {
        switch self {
        case .noSession, .bridgeFailed, .connectFailed:
            return true
        case .listFailed(let m), .downloadFailed(let m):
            return m.contains("connectionClosed")
        }
    }
}

/// Bridges a connected TLS tunnel to a 127.0.0.1 listener, so an SSH client
/// library that opens its own TCP connection can use the tunnel (Android
/// `net/Tunnel.kt LoopbackBridge` parity: one accepted connection, 10 s
/// accept wait, 32 KiB pipes, `TCP_NODELAY`, either side closing ends both).
///
/// Threading: ONE relay thread multiplexes both directions with select(),
/// and every SecureTransport call runs on it — concurrent read+write on one
/// context heap-corrupts (crashed the harness peer 2026-09-28: malloc abort
/// in SSLRead vs. a concurrent SSLWrite; the LiveChannel rule applies to
/// reads too). `close()` runs once, so the teardown still closes each fd
/// exactly once (the `close()` re-close rule); `shutdown` wakes the
/// select at once, so teardown has no thread tail.
final class LoopbackBridge: @unchecked Sendable {
    private static let pipeSize = 32 * 1024
    private static let acceptTimeout: TimeInterval = 10

    private let lock = NSLock()
    private var closed = false
    private var serverFD: Int32 = -1
    private var localFD: Int32 = -1
    private let remote: TLSConnection
    /// Serializes every SecureTransport touch (read/write/close): closing
    /// the context/fd under an in-flight SSLRead heap-corrupts (the crash
    /// above) — the LiveChannel rule, applied to teardown too.
    private let sslLock = NSLock()
    /// Lifecycle log sink (device forensics: the relay is otherwise
    /// silent, and its death looks identical from both ends).
    private let onLog: (@Sendable (String) -> Void)?

    /// The loopback port the SSH client dials.
    let port: Int

    /// True once the relay accepted the SSH library's connection
    /// (unit-test readiness; the kernel backlog accepts first).
    var didAccept: Bool { lock.withLock { localFD >= 0 } }

    init(remote: TLSConnection, onLog: (@Sendable (String) -> Void)? = nil) throws {
        self.remote = remote
        self.onLog = onLog
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrowseError.bridgeFailed("socket: errno \(errno)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        // Never die from SIGPIPE (writes to a closed relay socket surface
        // as EPIPE errors on the teardown paths, whatever the host
        // process ignores — the app/peer SIG_IGN is not load-bearing here).
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(0).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw BrowseError.bridgeFailed("bind/listen: errno \(e)")
        }
        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &len)
            }
        }
        serverFD = fd
        port = Int(UInt16(bigEndian: boundAddr.sin_port))
        onLog?("relay up port=\(port) tls=\(remote.tlsVersion) cipher=\(remote.cipherSuite)")
        let bridge = self
        Thread.detachNewThread { bridge.runAccept() }
    }

    private func log(_ line: String) {
        onLog?("relay \(line)")
    }

    private func runAccept() {
        do {
            let c = try Sockets.accept(fd: serverFD, timeout: Self.acceptTimeout)
            var one: Int32 = 1
            setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock {
                if closed { Darwin.close(c); return }
                localFD = c
            }
            // One connection only: the listener is done.
            lock.withLock {
                if serverFD >= 0 { Darwin.close(serverFD); serverFD = -1 }
            }
            log("accepted")
            relay()
        } catch {
            log("accept ended: \(error)")
            close()
        }
    }

    /// Forwards both directions on this thread (the only thread that ever
    /// touches the tunnel's SecureTransport context).
    private func relay() {
        let tunnelFD = remote.socketFD
        var buf = [UInt8](repeating: 0, count: Self.pipeSize)
        while true {
            let local = lock.withLock { localFD }
            guard local >= 0, !lock.withLock({ closed }) else { return }
            var set = fd_set()
            Sockets.fdZero(&set)
            Sockets.fdSet(tunnelFD, &set)
            Sockets.fdSet(local, &set)
            // 30 s bound is a backstop only: close() shutdown()s the local
            // fd, which wakes the select at once on the teardown path.
            var tv = timeval(tv_sec: 30, tv_usec: 0)
            let r = select(max(tunnelFD, local) + 1, &set, nil, nil, &tv)
            if r < 0 { log("select: errno \(errno)"); close(); return }
            if r == 0 { continue }
            // Relay forensics: lifecycle + failure lines only. Per-chunk
            // sizes (`t->l n` / `l->t n`) were logged here during the D1
            // download diagnosis (2026-09-29, see `docs/ios-plan.md` §14)
            // and removed after it closed — ~1200 lines per zip on the
            // device console. Re-add temporarily if the chunk size is
            // ever tuned; the failure lines below stay.
            let tReady = Sockets.fdIsSet(tunnelFD, set)
            let lReady = Sockets.fdIsSet(local, set)
            if tReady {
                // Tunnel → local (the SSH server's bytes).
                let chunk: Data
                do {
                    chunk = try sslLock.withLock {
                        guard let c = try remote.read(max: Self.pipeSize) else {
                            throw RelayDone()
                        }
                        return c
                    }
                    if chunk.isEmpty { continue }
                } catch is RelayDone {
                    log("tunnel EOF"); close(); return
                } catch {
                    log("tunnel read: \(error)"); close(); return
                }
                if !sendAll(fd: local, chunk) { log("local send: errno \(errno)"); close(); return }
            }
            if lReady {
                // Local → tunnel (the SSH client's bytes).
                let n = recv(local, &buf, buf.count, 0)
                if n == 0 { log("local EOF"); close(); return }
                if n < 0 { log("local recv: errno \(errno)"); close(); return }
                do {
                    try sslLock.withLock {
                        try remote.write(Data(bytes: buf, count: n))
                    }
                } catch {
                    log("tunnel write: \(error)"); close(); return
                }
            }
        }
    }

    private func sendAll(fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { ptr -> Bool in
            while sent < data.count {
                let n = send(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Ends both directions. Idempotent: each fd closes exactly once.
    /// The tunnel shutdown wakes an in-flight SSLRead at once
    /// (`LinkRunner.close` pattern: wakeup only, the number frees in
    /// `remote.close()` below); the SSL lock then holds the teardown
    /// until that read drains, so close never lands mid-SSL-call.
    func close() {
        let tunnelFD: Int32 = lock.withLock {
            guard !closed else { return -1 }
            closed = true
            return remote.socketFD
        }
        guard tunnelFD >= 0 else { return }
        log("close")
        let targets: (Int32, Int32) = lock.withLock {
            defer {
                serverFD = -1
                localFD = -1
            }
            return (serverFD, localFD)
        }
        if targets.0 >= 0 { Darwin.close(targets.0) }
        if targets.1 >= 0 {
            shutdown(targets.1, SHUT_RDWR)
            Darwin.close(targets.1)
        }
        shutdown(tunnelFD, SHUT_RDWR)
        sslLock.withLock { remote.close() }
    }
}

/// Keepalive for a taken browse tunnel (provider.go parity: the desktop
/// dials its main links with keepalive 10 s/5 s/×3, but `OpenTunnel`
/// dials without — an idle browse tunnel (user reading the listing) dies
/// silently on Wi-Fi/NAT that drops idle TCP, and the next tap discovers
/// the corpse (device 2026-09-28: two sessions dead after ~20 s idle).
/// No desktop change (v1 rule): the phone arms its own end.
/// Darwin names: `TCP_KEEPALIVE` is the idle time (Linux `TCP_KEEPIDLE`).
enum TunnelKeepalive {
    static func enable(fd: Int32) throws {
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw BrowseError.bridgeFailed("keepalive: errno \(errno)") }
        var idle: Int32 = 10
        guard setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw BrowseError.bridgeFailed("keepalive idle: errno \(errno)") }
        var interval: Int32 = 5
        guard setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw BrowseError.bridgeFailed("keepalive interval: errno \(errno)") }
        var count: Int32 = 3
        guard setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw BrowseError.bridgeFailed("keepalive count: errno \(errno)") }
    }

    static func isEnabled(fd: Int32) -> Bool {
        var on: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, &len) == 0 else { return false }
        return on != 0
    }
}

/// Internal EOF signal across the SSL lock (a nil read inside
/// `withLock` cannot `return` from the relay directly).
private struct RelayDone: Error {}

/// One read-only SSH+SFTP session over a taken browse tunnel (Android
/// `core/Browse.kt` parity: password auth, accept-any host key, 10 s
/// connect timeout, 64 KiB download chunks, one tunnel = one session).
///
/// The one-time offer password arrives over the pinned TLS link, so the
/// host key is not pinned (Go `BrowseOpen`: `InsecureIgnoreHostKey` — the
/// desktop mints a fresh ed25519 host key per session). The client never
/// writes: list + download only, against fluxd's read-only server.
public actor BrowseSession {
    private var bridge: LoopbackBridge?
    private var client: SSHClient?
    private var sftp: SFTPClient?
    private let onLog: (@Sendable (String) -> Void)?
    /// Warm-keeper: a lightweight SFTP round-trip every 15 s while
    /// connected (see `startKeepalive`); cancelled on close.
    private var keepalive: Task<Void, Never>?

    /// - Parameter onLog: relay lifecycle sink (device forensics; the
    ///   relay's death looks identical from both ends without it).
    public init(onLog: (@Sendable (String) -> Void)? = nil) {
        self.onLog = onLog
    }

    /// Opens the SSH session through a taken browse tunnel. The caller
    /// takes the tunnel off the link (`LinkService.takeBrowseTunnel`) and
    /// hands over ownership here; a failed connect closes the relay.
    public func connect(tunnel: TLSConnection, user: String, password: String) async throws {
        await close()
        // Arm TCP keepalive on the tunnel first: the desktop dials browse
        // tunnels without keepalive (see `TunnelKeepalive`), so an idle
        // listing rots silently until the next tap trips over it.
        try TunnelKeepalive.enable(fd: tunnel.socketFD)
        let relay: LoopbackBridge
        do {
            relay = try LoopbackBridge(remote: tunnel, onLog: onLog)
        } catch {
            throw BrowseError.bridgeFailed(String(describing: error))
        }
        do {
            let ssh = try await SSHClient.connect(
                host: "127.0.0.1",
                port: relay.port,
                authenticationMethod: .passwordBased(username: user, password: password),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                connectTimeout: .seconds(10))
            let ftp = try await ssh.openSFTP()
            bridge = relay
            client = ssh
            sftp = ftp
            startKeepalive()
        } catch {
            relay.close()
            throw BrowseError.connectFailed(String(describing: error))
        }
    }

    /// Keeps the tunnel TLS session warm: a `realpath` round-trip every
    /// 15 s while connected. The phone is the TLS *server* on browse
    /// tunnels, and iOS SecureTransport fails the first SSLRead after
    /// ~20 s+ idle with errSecParam (-50) — kernel TCP keepalive does not
    /// touch the TLS layer, so only real SSH traffic prevents the rot
    /// (device 2026-09-28: three sessions dead at the post-idle tap).
    /// Failures are ignored: a dead session surfaces on the next real op.
    private func startKeepalive() {
        keepalive?.cancel()
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                do {
                    _ = try await self.ping()
                } catch {
                    // Failure lines prove the task runs: silence means the
                    // session is warm, and a tap death with no prior line
                    // narrows the rot window below 15 s. (Success used to
                    // log `warm ping ok` — removed 2026-09-29 after three
                    // device runs proved the keeper fires; failures stay.)
                    // Cancelled tasks stay silent: `close()` Nils the
                    // session before cancelling the keeper, so an
                    // in-flight ping can fail with `noSession` during an
                    // orderly teardown — that is the close, not rot.
                    guard !Task.isCancelled else { return }
                    await self.logKeepalive("warm ping failed: \(error)")
                }
            }
        }
    }

    private func ping() async throws -> String {
        guard let sftp else { throw BrowseError.noSession }
        return try await sftp.getRealPath(atPath: ".")
    }

    private func logKeepalive(_ line: String) {
        onLog?("keepalive \(line)")
    }

    /// Lists a folder (Android `Browse.list` parity: dotfiles dropped,
    /// folders first, case-insensitive names — via `buildBrowseList`).
    public func list(path: String) async throws -> [BrowseEntry] {
        guard let sftp else { throw BrowseError.noSession }
        do {
            var raw: [RawBrowseEntry] = []
            for reply in try await sftp.listDirectory(atPath: path) {
                for c in reply.components {
                    raw.append(RawBrowseEntry(
                        name: c.filename,
                        path: Self.join(path, c.filename),
                        permissions: c.attributes.permissions,
                        longname: c.longname,
                        size: c.attributes.size ?? 0))
                }
            }
            return buildBrowseList(raw)
        } catch {
            throw BrowseError.listFailed(String(describing: error))
        }
    }

    /// Downloads one file, streaming small chunks (Android `copyTo`
    /// parity in shape, not in size). Returns the byte count; `progress`
    /// reports bytes so far.
    /// The caller prepares the destination directory (Downloads +
    /// non-clobbering name, like `TransferEngine` receives).
    @discardableResult
    public func download(
        remotePath: String, to localURL: URL,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> Int64 {
        guard let sftp else { throw BrowseError.noSession }
        do {
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: localURL)
            defer { try? handle.close() }
            // openFile (not withFile): the file closure is @Sendable and
            // cannot touch the local file handle; the explicit close below
            // keeps the same guarantee.
            let remote = try await sftp.openFile(filePath: remotePath, flags: .read)
            do {
                var total: Int64 = 0
                var offset: UInt64 = 0
                while true {
                    // 1 KiB requests, tight loop (no pacing): iOS
                    // SecureTransport in the server role dies reading
                    // multi-segment replies (-50 after a partial 4096 of
                    // an 8 KiB DATA on device 2026-09-29, same cipher
                    // c02c as the green loopback — neither 64 KiB tight
                    // nor 8 KiB + 100/300 ms pacing survived it), while
                    // strict small-message alternation is proven green
                    // (the whole SSH handshake, 3 KiB listings, warm
                    // pings, 57 B files). 1 KiB DATA replies fit one
                    // segment / one TLS record, so every round trip looks
                    // like the handshake pattern: ~600 trips ≈ 6 s for
                    // the 600 KB zip. Tune up once green.
                    let chunk = try await remote.read(from: offset, length: 1024)
                    if chunk.readableBytes == 0 { break }
                    try handle.write(contentsOf: Data(chunk.readableBytesView))
                    total += Int64(chunk.readableBytes)
                    offset += UInt64(chunk.readableBytes)
                    progress?(total)
                }
                try await remote.close()
                return total
            } catch {
                try? await remote.close()
                throw error
            }
        } catch {
            throw BrowseError.downloadFailed(String(describing: error))
        }
    }

    /// Ends the session: SFTP close, SSH disconnect, relay close (Android
    /// `Browse.close` parity). Idempotent; a tunnel carries one session,
    /// so the next browse asks the desktop for a new one.
    public func close() async {
        let ftp = sftp
        let ssh = client
        let relay = bridge
        let keep = keepalive
        sftp = nil
        client = nil
        bridge = nil
        keepalive = nil
        keep?.cancel()
        if let ftp { try? await ftp.close() }
        if let ssh { try? await ssh.close() }
        relay?.close()
    }

    private static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
}