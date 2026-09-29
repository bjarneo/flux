import XCTest
import Foundation
import Darwin
#if canImport(Security)
import Security
#endif
@testable import FluxNet
@testable import FluxProto
@testable import FluxCore

/// Socket-level link tests over loopback. No entitlements, no daemons.
final class LinkSocketTests: XCTestCase {
    private func socketPair() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw Sockets.SocketError.unavailable(errno)
        }
        return (fds[0], fds[1])
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    func testRawLineReader() throws {
        let (rd, wr) = try socketPair()
        defer { Darwin.close(rd); Darwin.close(wr) }
        writeAll(wr, Data("hello\r\nworld\n".utf8))
        XCTAssertEqual(Data("hello".utf8), try Sockets.readRawLine(fd: rd, max: 64))
        XCTAssertEqual(Data("world".utf8), try Sockets.readRawLine(fd: rd, max: 64))

        // EOF with a partial line returns the partial line, then nil.
        let (rd2, wr2) = try socketPair()
        defer { Darwin.close(rd2) }
        writeAll(wr2, Data("partial".utf8))
        Darwin.close(wr2)
        XCTAssertEqual(Data("partial".utf8), try Sockets.readRawLine(fd: rd2, max: 64))
        XCTAssertNil(try Sockets.readRawLine(fd: rd2, max: 64))
    }

    func testRawLineReaderMax() throws {
        let (rd, wr) = try socketPair()
        defer { Darwin.close(rd); Darwin.close(wr) }
        writeAll(wr, Data("0123456789".utf8))
        XCTAssertThrowsError(try Sockets.readRawLine(fd: rd, max: 5))
    }

    func testUDPLoopback() throws {
        let rx = try Sockets.discoverySocket(port: 28716)
        defer { Sockets.close(rx) }
        let tx = try Sockets.discoverySocket(port: 28717)
        defer { Sockets.close(tx) }
        let payload = Data("kdeconnect-udp-probe".utf8)
        try Sockets.sendTo(fd: tx, data: payload, host: "127.0.0.1", port: 28716)
        let got = try Sockets.receiveFrom(fd: rx, timeout: 5)
        XCTAssertEqual(payload, got?.0)
        XCTAssertEqual("127.0.0.1", got?.1)
        XCTAssertNil(try Sockets.receiveFrom(fd: rx, timeout: 0.2))
    }

#if canImport(Security)
    func testLoopbackTLSHandshake() throws {
        // Permanent test keys (same-process reads never prompt) + cleanup.
        let cTag = "org.omarchy.flux.test.tls-client.\(UUID().uuidString)"
        let sTag = "org.omarchy.flux.test.tls-server.\(UUID().uuidString)"
        defer {
            IdentityKeys.delete(tag: cTag)
            IdentityKeys.delete(tag: sTag)
        }
        let cKey = try TestKeychain.loadOrCreateIdentity(tag: cTag)
        let sKey = try TestKeychain.loadOrCreateIdentity(tag: sTag)
        let cId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let sId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let cDER = try SelfSignedCertificate.issue(key: cKey, deviceId: cId)
        let sDER = try SelfSignedCertificate.issue(key: sKey, deviceId: sId)
        let cCert = try XCTUnwrap(SecCertificateCreateWithData(nil, cDER as CFData))
        let sCert = try XCTUnwrap(SecCertificateCreateWithData(nil, sDER as CFData))
        XCTAssertEqual(cId, TLSIdentity.commonName(cCert))
        XCTAssertEqual(sId, TLSIdentity.commonName(sCert))
        let cIdent = try XCTUnwrap(TLSIdentity.makeIdentity(certificate: cCert, label: cTag))
        let sIdent = try XCTUnwrap(TLSIdentity.makeIdentity(certificate: sCert, label: sTag))

        let (cfd, sfd) = try socketPair()

        final class Cap: @unchecked Sendable {
            var serverCN: String?
            var serverError: String?
            var done = false
        }
        let cap = Cap()
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            do {
                let server = try TLSConnection.handshake(fd: sfd, role: .server(identity: sIdent)) { cn, _ in
                    cap.serverCN = cn
                    return true
                }
                let line = try TLSLineReader(server).readLine(max: 65536)
                try server.write((line ?? Data()) + Data([0x0A]))
                server.close()
            } catch {
                cap.serverError = String(describing: error)
            }
            cap.done = true
            group.leave()
        }

        let client = try TLSConnection.handshake(fd: cfd, role: .client(identity: cIdent)) { cn, der in
            // Server presents its self-signed cert; pin it like a first pair.
            guard cn == sId, der == sDER else { return false }
            return true
        }
        XCTAssertEqual(sId, client.peerLeaf()?.cn)
        try client.write(Data("ping-line\n".utf8))
        XCTAssertEqual(Data("ping-line".utf8), try TLSLineReader(client).readLine(max: 65536))
        client.close()

        XCTAssertEqual(.success, group.wait(timeout: .now() + 30))
        XCTAssertNil(cap.serverError)
        XCTAssertTrue(cap.done)
        XCTAssertEqual(cId, cap.serverCN)
    }
#endif
}
