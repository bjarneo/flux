import XCTest
import Foundation
import Darwin
#if canImport(Security)
import Security
#endif
@testable import FluxNet
@testable import FluxProto
@testable import FluxCore

/// Payload byte-moving over loopback TLS: fetch framing, exact-size
/// enforcement, and the pinned-peer check (Go `checkPeer` parity).
/// Packet builders + routing live in `TransferTests`; multi-MB/file
/// round-trips run E2E against `tools/test_peer.py`.
#if canImport(Security)
final class PayloadTests: XCTestCase {
    private struct Peer: @unchecked Sendable {
        let key: SecKey
        let der: Data
        let identity: SecIdentity
    }

    private var tags: [String] = []

    override func tearDown() {
        // Permanent test keys never prompt in-process; delete them so the
        // suite stays Keychain-residue-free (LinkSocketTests parity).
        for tag in tags { IdentityKeys.delete(tag: tag) }
        tags.removeAll()
        super.tearDown()
    }

    private func makePeer(id: String) throws -> Peer {
        let tag = "org.omarchy.flux.test.payload.\(UUID().uuidString)"
        tags.append(tag)
        let key = try TestKeychain.loadOrCreateIdentity(tag: tag)
        // Best-effort cleanup: the tag is unique per test.
        let der = try SelfSignedCertificate.issue(key: key, deviceId: id)
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let identity = try XCTUnwrap(TLSIdentity.makeIdentity(certificate: cert, label: tag))
        return Peer(key: key, der: der, identity: identity)
    }

    private func payloadBytes(_ n: Int) -> Data {
        // Deterministic pattern (compressor-proof, checksum-stable).
        Data((0..<n).map { UInt8(($0 * 31 + 7) & 0xFF) })
    }

    /// Serves `bytes` (or fewer, to simulate truncation) on a loopback
    /// payload listener, then fetches them as the TLS client.
    private func roundTrip(serve bytes: Data, announce size: Int64) throws -> Data {
        let server = try makePeer(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let client = try makePeer(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let (lfd, port) = try Sockets.listenTCP(first: 28739, max: 28764)
        let group = DispatchGroup()
        group.enter()
        final class Box: @unchecked Sendable { var error: String? }
        let box = Box()
        Thread.detachNewThread {
            do {
                let fd = try Sockets.accept(fd: lfd, timeout: 15)
                Sockets.close(lfd)
                let conn = try Payload.serverHandshake(fd: fd, identity: server.identity, expectedPeerDER: client.der)
                defer { conn.close() }
                try Payload.serve(conn, input: InputStream(data: bytes), size: Int64(bytes.count)) { _ in }
            } catch {
                box.error = String(describing: error)
            }
            group.leave()
        }
        do {
            let got = try Payload.fetch(
                host: "127.0.0.1", port: port, size: size,
                identity: client.identity, expectedPeerDER: server.der)
            XCTAssertEqual(.success, group.wait(timeout: .now() + 30))
            XCTAssertNil(box.error)
            return got
        } catch {
            group.wait(timeout: .now() + 30)
            throw error
        }
    }

    func testFetchRoundTrip() throws {
        let bytes = payloadBytes(300_000)
        // Separate `try` (not inside XCTAssertEqual): an XCTSkip from the
        // unsigned-host guard must propagate, not read as a failure.
        let got = try roundTrip(serve: bytes, announce: Int64(bytes.count))
        XCTAssertEqual(bytes, got)
    }

    func testFetchShortPayloadFails() throws {
        let bytes = payloadBytes(10_000)
        do {
            _ = try roundTrip(serve: bytes, announce: Int64(bytes.count) + 1)
            XCTFail("expected shortPayload")
        } catch Payload.Error.shortPayload(let received, let expected) {
            XCTAssertEqual(Int64(bytes.count), received)
            XCTAssertEqual(Int64(bytes.count) + 1, expected)
        }
    }

    func testFetchPeerMismatchFails() throws {
        let server = try makePeer(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let client = try makePeer(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let (lfd, port) = try Sockets.listenTCP(first: 28739, max: 28764)
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            guard let fd = try? Sockets.accept(fd: lfd, timeout: 15) else { return }
            Sockets.close(lfd)
            // The server pins the real client; the fetch below offers a
            // stranger's DER, so the handshake must refuse.
            _ = try? Payload.serverHandshake(fd: fd, identity: server.identity, expectedPeerDER: client.der)
            Sockets.close(fd)
        }
        defer { Sockets.close(lfd); group.wait(timeout: .now() + 30) }
        let stranger = try makePeer(id: "cccccccccccccccccccccccccccccccc")
        do {
            _ = try Payload.fetch(
                host: "127.0.0.1", port: port, size: 10,
                identity: client.identity, expectedPeerDER: stranger.der)
            XCTFail("expected handshake failure")
        } catch Payload.Error.handshakeFailed {
        }
    }

    func testListenerRange() throws {
        // Listeners bind inside the Go payload range (1739–1764).
        let listener = try Payload.listen()
        defer { Sockets.close(listener.fd) }
        XCTAssertTrue(Lan.minPayloadPort...Lan.maxPayloadPort ~= listener.port)
    }
}
#endif
