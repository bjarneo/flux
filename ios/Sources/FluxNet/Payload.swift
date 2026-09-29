import Foundation
import Darwin
#if canImport(Security)
import Security
#endif
import FluxProto

#if canImport(Security)
/// Payload + tunnel sockets: the phone side of file transfers.
///
/// Roles (see `FluxProto/Transfers.swift` for the selection rule):
/// - RECEIVE classic: connect to the sender's `port` as the TLS client
///   (`Payload.fetch`, mirrors Go `FetchPayload` + Android `Payload.receive`).
/// - RECEIVE via tunnel: listen on a payload-range port as the TLS server,
///   announce it with `flux.tunnel ready` (`TunnelListener`, mirrors
///   Android `Tunnel.accept` + Go `OpenTunnel`/`DialPeer` counterparts).
/// - SEND (phone→desktop): always classic — listen, announce `port`, serve
///   the bytes (mirrors Android `Share.sendFiles` + `Payload.send`).
///
/// The listener is always the TLS server and the dialer the TLS client
/// (Go `SendWithPayload`, Android `Payload`). Both directions check that
/// the peer presents the pinned link certificate (Go `checkPeer`).
public enum Payload {
    public enum Error: Swift.Error, Equatable {
        case noFreePort
        case acceptTimeout
        case handshakeFailed(OSStatus)
        case peerMismatch
        case shortPayload(received: Int64, expected: Int64)
        case ioFailed(OSStatus)
    }

    /// Payload-range listener (1739–1764, Go `listenPayload` parity).
    public struct Listener {
        public let fd: Int32
        public let port: Int
    }

    /// Binds the first free port in the payload range.
    public static func listen() throws -> Listener {
        do {
            let (fd, port) = try Sockets.listenTCP(first: Lan.minPayloadPort, max: Lan.maxPayloadPort)
            return Listener(fd: fd, port: port)
        } catch {
            throw Error.noFreePort
        }
    }

    // MARK: - Receive: classic fetch

    /// Connects to the sender's payload port and reads exactly `size`
    /// bytes. Calls `progress` with the running total (throttle it at the
    /// call site: Go publishes at most 4/s). Throws `shortPayload` when
    /// the stream ends early (Go `received %d of %d bytes`, Android
    /// `payload ended at %d of %d bytes`).
    public static func fetch(
        host: String, port: Int, size: Int64,
        identity: SecIdentity, expectedPeerDER: Data,
        progress: (Int64) -> Void = { _ in }
    ) throws -> Data {
        var collected = Data()
        collected.reserveCapacity(Int(min(size, 1 << 20)))
        try stream(host: host, port: port, identity: identity, expectedPeerDER: expectedPeerDER) { conn in
            collected = try readExactly(conn, size: size, progress: progress)
        }
        return collected
    }

    /// Same as `fetch` but writes into `output` (files land here; the
    /// `.part`+rename wrapper lives in `FluxCore.TransferEngine`, mirroring
    /// Go `receiveFile` + Android `finishDownload`).
    public static func fetch(
        host: String, port: Int, size: Int64,
        identity: SecIdentity, expectedPeerDER: Data,
        output: OutputStream,
        progress: (Int64) -> Void = { _ in }
    ) throws {
        try stream(host: host, port: port, identity: identity, expectedPeerDER: expectedPeerDER) { conn in
            try pipeExactly(conn, size: size, output: output, progress: progress)
        }
    }

    // MARK: - Receive/serve: tunnel listener side

    /// Accepts one connection on `listener` (waiting up to `timeout`,
    /// default 30 s like Go `tunnelWait` / Android `TUNNEL_TIMEOUT_MS`)
    /// and runs the TLS-server handshake with the pinned-peer check.
    public static func acceptTunnel(
        _ listener: Listener, identity: SecIdentity, expectedPeerDER: Data,
        timeout: TimeInterval = 30
    ) throws -> TLSConnection {
        let fd: Int32
        do {
            fd = try Sockets.accept(fd: listener.fd, timeout: timeout)
        } catch Sockets.SocketError.timeout {
            throw Error.acceptTimeout
        }
        Sockets.close(listener.fd)
        return try serverHandshake(fd: fd, identity: identity, expectedPeerDER: expectedPeerDER)
    }

    /// Accepts one classic payload connection (Go's 20 s accept timeout in
    /// `SendWithPayload`) with the pinned-peer check.
    public static func acceptPayload(
        _ listener: Listener, identity: SecIdentity, expectedPeerDER: Data,
        timeout: TimeInterval = 20
    ) throws -> TLSConnection {
        do {
            return try acceptTunnel(listener, identity: identity, expectedPeerDER: expectedPeerDER, timeout: timeout)
        } catch Error.acceptTimeout {
            Sockets.close(listener.fd)
            throw Error.acceptTimeout
        }
    }

    public static func serverHandshake(fd: Int32, identity: SecIdentity, expectedPeerDER: Data) throws -> TLSConnection {
        do {
            return try TLSConnection.handshake(fd: fd, role: .server(identity: identity), timeout: 15) { _, der in
                der == expectedPeerDER
            }
        } catch TLSConnection.Error.handshakeFailed(let s) {
            throw Error.handshakeFailed(s)
        } catch {
            throw Error.handshakeFailed(errSSLInternal)
        }
    }

    // MARK: - Send: serve bytes to a fetcher

    /// Streams exactly `size` bytes from `input` to the accepted fetcher
    /// (Android `Payload.send` tail: copy + flush).
    public static func serve(_ conn: TLSConnection, input: InputStream, size: Int64, progress: (Int64) -> Void = { _ in }) throws {
        input.open()
        defer { input.close() }
        var done: Int64 = 0
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while done < size {
            let want = Int(min(Int64(buf.count), size - done))
            let n = input.read(&buf, maxLength: want)
            if n <= 0 { break }
            try writeAll(conn, Data(bytes: buf, count: n))
            done += Int64(n)
            progress(done)
        }
        progress(done)
        if done < size { throw Error.shortPayload(received: done, expected: size) }
    }

    /// Reads exactly `size` bytes from an accepted tunnel/payload
    /// connection (64 KiB chunks like Android `Payload.copy`).
    public static func receive(
        from conn: TLSConnection, size: Int64,
        progress: (Int64) -> Void = { _ in }
    ) throws -> Data {
        try readExactly(conn, size: size, progress: progress)
    }

    /// Writes exactly `size` bytes from an accepted connection into `output`.
    public static func receive(
        from conn: TLSConnection, size: Int64,
        output: OutputStream,
        progress: (Int64) -> Void = { _ in }
    ) throws {
        try pipeExactly(conn, size: size, output: output, progress: progress)
    }

    private static func stream(
        host: String, port: Int, identity: SecIdentity, expectedPeerDER: Data,
        body: (TLSConnection) throws -> Void
    ) throws {
        // No port-range check here: like Go `FetchPayload`, the fetcher
        // dials whatever port the announcement carries. (The 1739–1764
        // range is enforced on listeners, and on the desktop's `DialPeer`.)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.ioFailed(errno) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Sockets.close(fd)
            throw Error.ioFailed(EINVAL)
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            let e = errno
            Sockets.close(fd)
            throw Error.ioFailed(e)
        }
        let conn: TLSConnection
        do {
            conn = try TLSConnection.handshake(fd: fd, role: .client(identity: identity), timeout: 15) { _, der in
                der == expectedPeerDER
            }
        } catch TLSConnection.Error.handshakeFailed(let s) {
            Sockets.close(fd)
            throw Error.handshakeFailed(s)
        } catch {
            Sockets.close(fd)
            throw Error.handshakeFailed(errSSLInternal)
        }
        defer { conn.close() }
        try body(conn)
    }

    /// Reads exactly `size` bytes (64 KiB chunks like Android `Payload.copy`).
    static func readExactly(_ conn: TLSConnection, size: Int64, progress: (Int64) -> Void) throws -> Data {
        var out = Data()
        out.reserveCapacity(Int(min(size, 1 << 20)))
        var done: Int64 = 0
        while done < size {
            let want = Int(min(Int64(64 * 1024), size - done))
            guard let chunk = try conn.read(max: want) else { break }
            if chunk.isEmpty { continue }
            out += chunk
            done += Int64(chunk.count)
            progress(done)
        }
        progress(done)
        if done < size { throw Error.shortPayload(received: done, expected: size) }
        return out
    }

    static func pipeExactly(_ conn: TLSConnection, size: Int64, output: OutputStream, progress: (Int64) -> Void) throws {
        output.open()
        defer { output.close() }
        var done: Int64 = 0
        while done < size {
            let want = Int(min(Int64(64 * 1024), size - done))
            guard let chunk = try conn.read(max: want) else { break }
            if chunk.isEmpty { continue }
            let written = chunk.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                output.write(ptr.bindMemory(to: UInt8.self).baseAddress!, maxLength: chunk.count)
            }
            if written <= 0 { throw Error.ioFailed(EIO) }
            done += Int64(written)
            progress(done)
        }
        progress(done)
        if done < size { throw Error.shortPayload(received: done, expected: size) }
    }

    private static func writeAll(_ conn: TLSConnection, _ data: Data) throws {
        do {
            try conn.write(data)
        } catch TLSConnection.Error.ioFailed(let s) {
            throw Error.ioFailed(s)
        } catch {
            throw Error.ioFailed(EIO)
        }
    }
}
#endif
