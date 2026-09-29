import XCTest
import Foundation
import Darwin
#if canImport(Security)
import Security
#endif
@testable import FluxNet
@testable import FluxCore

/// D1 bridge tests: the loopback relay pumps bytes both ways between a
/// tunnel TLS connection and a plain TCP client (the SSH library's side).
/// Keychain-gated like the other loopback-TLS tests: unsigned simulator
/// hosts throw `XCTSkip` out of `TestKeychain` (-34018).
///
/// Scope: both directions + close + a small smoke. Sustained overlapped
/// traffic is E2E-held (`test_peer.py --browse-ssh`: Citadel ↔ asyncssh
/// through the production relay) — unit level stays sequential, which is
/// all these sockets need to prove the wiring.
final class BrowseBridgeTests: XCTestCase {
    private func socketPair() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw Sockets.SocketError.unavailable(errno)
        }
        return (fds[0], fds[1])
    }

    /// One loopback TLS pair: the client side drives the test, the server
    /// side feeds the bridge.
    private func tlsPair() throws -> (client: TLSConnection, server: TLSConnection) {
        let tag = "org.omarchy.flux.test.browse.\(UUID().uuidString)"
        defer { IdentityKeys.delete(tag: tag) }
        let key = try TestKeychain.loadOrCreateIdentity(tag: tag)
        let id = "cccccccccccccccccccccccccccccccc"
        let der = try SelfSignedCertificate.issue(key: key, deviceId: id)
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let ident = try XCTUnwrap(TLSIdentity.makeIdentity(certificate: cert, label: tag))
        let (cfd, sfd) = try socketPair()
        final class Box: @unchecked Sendable { var conn: TLSConnection? }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            box.conn = try? TLSConnection.handshake(fd: sfd, role: .server(identity: ident)) { _, _ in true }
            group.leave()
        }
        let client = try TLSConnection.handshake(fd: cfd, role: .client(identity: ident)) { _, _ in true }
        XCTAssertEqual(.success, group.wait(timeout: .now() + 30))
        let server = try XCTUnwrap(box.conn)
        return (client, server)
    }

    private func dialLoopback(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Sockets.SocketError.unavailable(errno) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            Darwin.close(fd)
            throw Sockets.SocketError.unavailable(errno)
        }
        return fd
    }

    /// Waits for the relay to accept the dial (kernel-accept lands in the
    /// backlog first; closing before the relay accepts tests nothing).
    private func waitForAccept(_ bridge: LoopbackBridge) throws {
        let deadline = Date().addingTimeInterval(5)
        while !bridge.didAccept {
            if Date() > deadline { throw Sockets.SocketError.timeout }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { ptr in
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    private func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 32 * 1024)
        while out.count < count {
            let n = recv(fd, &buf, min(buf.count, count - out.count), 0)
            if n <= 0 { throw Sockets.SocketError.closed }
            out += Data(bytes: buf, count: n)
        }
        return out
    }

    func testBridgePumpsBothWays() throws {
        let (client, server) = try tlsPair()
        defer { client.close() }
        let bridge = try LoopbackBridge(remote: server)
        defer { bridge.close() }
        let local = try dialLoopback(port: bridge.port)
        defer { Darwin.close(local) }
        try waitForAccept(bridge)

        // Tunnel → local (the SSH server's bytes toward the client library).
        let down = Data("ssh-server-bytes".utf8)
        try client.write(down)
        XCTAssertEqual(down, try readExactly(local, down.count))

        // Local → tunnel (the client library's bytes toward the server).
        let up = Data("ssh-client-bytes".utf8)
        writeAll(local, up)
        var got = Data()
        while got.count < up.count {
            let chunk = try XCTUnwrap(try client.read(max: 32 * 1024))
            if chunk.isEmpty { continue }
            got += chunk
        }
        XCTAssertEqual(up, got)
    }

    func testBridgeCloseEndsBoth() throws {
        let (client, server) = try tlsPair()
        defer { client.close() }
        let bridge = try LoopbackBridge(remote: server)
        let local = try dialLoopback(port: bridge.port)
        defer { Darwin.close(local) }
        try waitForAccept(bridge)
        // Idempotent: twice must not crash or double-close the fd.
        bridge.close()
        bridge.close()
        // The local side sees EOF after the relay goes away.
        var one: UInt8 = 0
        XCTAssertEqual(0, recv(local, &one, 1, 0))
    }

    func testTinyDirect() throws {
        // Sanity: a fresh loopback TLS pair carries a small message
        // without any relay in the path.
        let (client, server) = try tlsPair()
        defer { client.close(); server.close() }
        try server.write(Data("0123456789abcdef".utf8))
        let back = try XCTUnwrap(try client.read(max: 1024))
        XCTAssertEqual(Data("0123456789abcdef".utf8), back)
    }
}
