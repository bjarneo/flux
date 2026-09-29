import Foundation
#if canImport(Security)
import Security
import Darwin

/// TLS over an already-connected socket, via SecureTransport.
///
/// Why not `Network.framework`: the acceptor must read the plaintext
/// `kdeconnect.identity` line *before* the TLS handshake and then act as
/// TLS **client** (Go `provider.go accept()` + `finish()`). `NWListener`
/// TLS handshakes immediately as server — the wrong role at the wrong time.
/// SecureTransport gives exact handshake control and works with Secure
/// Enclave keys (no export, unlike file-based TLS stacks). It is deprecated
/// (macOS 10.15+) but functional; the framing/pinning logic above it is
/// transport-agnostic, so a future `Network.framework` STARTTLS-style
/// upgrade only replaces this file.
///
/// Cipher posture mirrors Go `tls.go`: TLS 1.2 minimum. The handshake
/// accepts any self-signed certificate; authentication happens after it via
/// `TrustValidation` (CN match + pin compare), like Go and Android.
///
/// Threading: blocking I/O, one thread per connection (like Android `Link`
/// reader/writer threads). Not `Sendable`; confine to its owning thread.
public final class TLSConnection {
    public enum TLSRole {
        /// TLS client: offers `identity`, breaks on server auth for pinning.
        case client(identity: SecIdentity)
        /// TLS server: presents `identity`, requests a client certificate.
        /// Used by tests and (later) payload sockets.
        case server(identity: SecIdentity)
    }

    /// Called after the peer's certificate arrives. Receives the leaf CN
    /// (nil when absent/unparseable) and leaf DER (nil when absent).
    /// Return true to continue, false to abort. System trust is never
    /// consulted; implement `TrustValidation` here.
    public typealias PeerCheck = (String?, Data?) -> Bool

    public enum Error: Swift.Error, Equatable {
        case handshakeFailed(OSStatus)
        case ioFailed(OSStatus)
        case closed
        case lineTooLong
    }

    private let fd: Int32
    private var ctx: SSLContext?
    private let box: FDBox

    private init(fd: Int32, box: FDBox, ctx: SSLContext) {
        self.fd = fd
        self.box = box
        self.ctx = ctx
    }

    deinit {
        if let ctx { SSLClose(ctx) }
    }

    // MARK: - Handshake

    /// Performs the handshake on `fd` (must already be connected).
    /// `timeout` bounds the whole handshake (Go parity: 10 s).
    public static func handshake(fd: Int32, role: TLSRole, timeout: TimeInterval = 10, peerCheck: @escaping PeerCheck) throws -> TLSConnection {
        try setTimeout(fd: fd, seconds: timeout)
        let box = FDBox(fd: fd)
        let raw = Unmanaged.passUnretained(box).toOpaque()
        let ctx: SSLContext
        switch role {
        case .client:
            guard let c = SSLCreateContext(nil, .clientSide, .streamType) else { throw Error.handshakeFailed(-1) }
            ctx = c
            SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        case .server:
            guard let c = SSLCreateContext(nil, .serverSide, .streamType) else { throw Error.handshakeFailed(-1) }
            ctx = c
            SSLSetClientSideAuthenticate(ctx, .alwaysAuthenticate)
            SSLSetSessionOption(ctx, .breakOnClientAuth, true)
        }
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        if case .client(let id) = role { SSLSetCertificate(ctx, [id] as CFArray) }
        if case .server(let id) = role { SSLSetCertificate(ctx, [id] as CFArray) }
        SSLSetIOFuncs(ctx, sslReadFunc, sslWriteFunc)
        SSLSetConnection(ctx, raw)

        let conn = TLSConnection(fd: fd, box: box, ctx: ctx)
        var status = SSLHandshake(ctx)
        // Break-on-auth pauses the handshake for our pin check, then we resume.
        if status == errSSLPeerAuthCompleted {
            var trust: SecTrust?
            SSLCopyPeerTrust(ctx, &trust)
            let (cn, der): (String?, Data?) = {
                guard let trust,
                      let cert = SecTrustGetCertificateAtIndex(trust, 0) else { return (nil, nil) }
                return (TLSIdentity.commonName(cert), TLSIdentity.certificateDER(cert))
            }()
            guard peerCheck(cn, der) else {
                conn.close()
                throw Error.handshakeFailed(errSSLBadCert)
            }
            status = SSLHandshake(ctx)
        }
        var spins = 0
        while status == errSSLWouldBlock {
            spins += 1
            guard spins < 10_000 else { conn.close(); throw Error.handshakeFailed(status) }
            try waitWritable(fd: fd, seconds: timeout)
            status = SSLHandshake(ctx)
        }
        guard status == errSecSuccess else {
            conn.close()
            throw Error.handshakeFailed(status)
        }
        return conn
    }

    /// Peer leaf after a successful handshake (for logging/debugging).
    public func peerLeaf() -> (cn: String?, der: Data?)? {
        guard let ctx else { return nil }
        var trust: SecTrust?
        guard SSLCopyPeerTrust(ctx, &trust) == errSecSuccess, let trust,
              let cert = SecTrustGetCertificateAtIndex(trust, 0)
        else { return nil }
        return (TLSIdentity.commonName(cert), TLSIdentity.certificateDER(cert))
    }

    /// Raw socket for select()-driven relays (D1 bridge): lets one thread
    /// multiplex tunnel + loopback readability, so every SecureTransport
    /// call stays on that thread (contexts are not thread-safe — the
    /// LiveChannel rule). Never close/shutdown this fd directly; the
    /// owner closes exactly once via `close()`.
    public var socketFD: Int32 { fd }

    /// Negotiated TLS version for diagnostics ("1.2"/"1.3"/"?").
    public var tlsVersion: String {
        guard let ctx else { return "?" }
        var v = SSLProtocol.tlsProtocol12
        guard SSLGetNegotiatedProtocolVersion(ctx, &v) == errSecSuccess else { return "?" }
        switch v {
        case .tlsProtocol13: return "1.3"
        case .tlsProtocol12: return "1.2"
        default: return "?"
        }
    }

    /// Negotiated cipher suite as hex for diagnostics ("c02f" style, "?"
    /// when unavailable). The device download leg negotiates with Go's
    /// restricted 1.2 list (`internal/lan/tls.go`), not with the loopback
    /// harness's OpenSSL — the suite goes on record with the version.
    public var cipherSuite: String {
        guard let ctx else { return "?" }
        var suite: SSLCipherSuite = 0
        guard SSLGetNegotiatedCipher(ctx, &suite) == errSecSuccess else { return "?" }
        return String(format: "%04x", suite)
    }

    // MARK: - I/O

    /// Writes all bytes (loops on partial writes).
    public func write(_ data: Data) throws {
        guard let ctx else { throw Error.closed }
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < data.count {
                var out = 0
                let base = ptr.baseAddress!.advanced(by: sent)
                let status = SSLWrite(ctx, base, data.count - sent, &out)
                guard status == errSecSuccess || status == errSSLWouldBlock else { throw Error.ioFailed(status) }
                if out == 0 { throw Error.closed }
                sent += out
            }
        }
    }

    /// Reads up to `max` bytes. Returns nil on clean EOF, empty Data when
    /// no bytes are ready (non-blocking moment).
    public func read(max: Int) throws -> Data? {
        guard let ctx else { throw Error.closed }
        var buf = Data(count: max)
        // -1 signals clean EOF out of the closure (exclusivity: no `buf`
        // access inside while mutating).
        let out: Int = try buf.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Int in
            var out = 0
            guard let base = ptr.baseAddress else {
                fputs("flux-tls: read nil base for max=\(max)\n", stderr)
                throw Error.ioFailed(errSecParam)
            }
            let status = SSLRead(ctx, base, max, &out)
            switch status {
            case errSecSuccess:
                return out
            case errSSLClosedGraceful, errSSLClosedNoNotify, errSSLClosedAbort:
                // Peers often close without close_notify (notably Python's
                // ssl module and some KDE Connect peers); treat as clean EOF.
                return -1
            case errSSLWouldBlock:
                return 0
            default:
                throw Error.ioFailed(status)
            }
        }
        if out < 0 { return nil }
        return Data(buf.prefix(out))
    }

    public func close() {
        box.closed = true
        if let ctx {
            SSLClose(ctx)
            self.ctx = nil
        }
        _ = Darwin.close(fd)
    }

    // MARK: - Socket helpers

    /// Bounds socket I/O. Public so the pre-TLS plaintext phase (owned by
    /// the caller, Go `SetDeadline` parity) uses the same timeouts.
    public static func setTimeout(fd: Int32, seconds: TimeInterval) throws {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: __darwin_suseconds_t((seconds.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) == 0
        else { throw Error.ioFailed(errno) }
    }

    private static func waitWritable(fd: Int32, seconds: TimeInterval) throws {
        var fds = fd_set()
        Sockets.fdZero(&fds)
        Sockets.fdSet(fd, &fds)
        var tv = timeval(tv_sec: Int(ceil(seconds)), tv_usec: 0)
        let r = select(fd + 1, nil, &fds, nil, &tv)
        if r < 0 { throw Error.ioFailed(errno) }
    }
}

// MARK: - Buffered line reader

/// Newline-delimited reader over a `TLSConnection` (Go `bufio.Reader` +
/// `readLine` parity: CR/LF trimmed, hard cap per line).
public final class TLSLineReader {
    private let conn: TLSConnection
    private var buf = Data()

    public init(_ conn: TLSConnection) { self.conn = conn }

    /// Reads one line without the newline. Returns nil on clean EOF with no
    /// pending bytes. Throws `lineTooLong` past `max` bytes.
    public func readLine(max: Int) throws -> Data? {
        while true {
            if let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.prefix(upTo: nl)
                buf.removeSubrange(...nl)
                if line.count > max { throw TLSConnection.Error.lineTooLong }
                return trim(line)
            }
            if buf.count > max { throw TLSConnection.Error.lineTooLong }
            // nil = EOF; empty = momentarily no data (blocking sockets wait
            // inside the next read, so just retry).
            guard let chunk = try conn.read(max: 65536) else {
                if buf.isEmpty { return nil }
                let line = buf
                buf = Data()
                if line.count > max { throw TLSConnection.Error.lineTooLong }
                return trim(line)
            }
            if chunk.isEmpty { continue }
            buf += chunk
        }
    }

    private func trim(_ line: Data) -> Data {
        var d = line
        while let last = d.last, last == 0x0A || last == 0x0D { d.removeLast() }
        return d
    }
}

// MARK: - C callbacks

private final class FDBox {
    let fd: Int32
    var closed = false
    init(fd: Int32) { self.fd = fd }
}

private func sslReadFunc(connection: SSLConnectionRef, data: UnsafeMutableRawPointer, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let box = Unmanaged<FDBox>.fromOpaque(connection).takeUnretainedValue()
    if box.closed { return errSSLClosedNoNotify }
    let want = dataLength.pointee
    guard want > 0 else { dataLength.pointee = 0; return errSecSuccess }
    let n = Darwin.recv(box.fd, data, want, 0)
    if n > 0 { dataLength.pointee = n; return errSecSuccess }
    if n == 0 { dataLength.pointee = 0; return errSSLClosedGraceful }
    dataLength.pointee = 0
    return errno == EAGAIN || errno == EWOULDBLOCK ? errSSLWouldBlock : errSSLClosedNoNotify
}

private func sslWriteFunc(connection: SSLConnectionRef, data: UnsafeRawPointer, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let box = Unmanaged<FDBox>.fromOpaque(connection).takeUnretainedValue()
    if box.closed { return errSSLClosedNoNotify }
    let want = dataLength.pointee
    guard want > 0 else { dataLength.pointee = 0; return errSecSuccess }
    let n = Darwin.send(box.fd, data, want, 0)
    if n >= 0 { dataLength.pointee = n; return errSecSuccess }
    dataLength.pointee = 0
    return errno == EAGAIN || errno == EWOULDBLOCK ? errSSLWouldBlock : errSSLClosedNoNotify
}
#endif
