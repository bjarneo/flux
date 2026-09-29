import XCTest
import Foundation
#if canImport(Security)
import Security
#endif
@testable import FluxNet
@testable import FluxProto
@testable import FluxCore

/// App-originated uploads over loopback TLS (D15/D18): `LiveUploadBox` →
/// `TransferEngine.sendCaptures`/`sendFiles` announces + serves
/// byte-identical with the routing flags, pre-attach batches hold and
/// serve on attach, and detach drops the inlet. `StreamLiveTests` parity
/// (same in-process loopback TLS shape); multi-MB/file round-trips stay
/// E2E against `tools/test_peer.py`.
#if canImport(Security)
final class UploadLiveTests: XCTestCase {
    private struct Peer: @unchecked Sendable {
        let der: Data
        let identity: SecIdentity
    }

    /// Thread-safe packet/event ledger (StreamLiveTests `Ledger` parity —
    /// the engine reports off-thread).
    final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        var packets: [Packet] = []
        var completedName: String?
        var completedBytes: Int64?
        var failures: [String] = []

        func recordSend(_ p: Packet) -> Bool {
            lock.withLock { packets.append(p) }
            return true
        }

        func recordEvent(_ e: TransferEvent, settled: DispatchGroup) {
            switch e {
            case .completed(let filename, _, let bytes):
                lock.withLock {
                    completedName = filename
                    completedBytes = bytes
                }
                settled.leave()
            case .failed(let filename, let error):
                lock.withLock { failures.append("\(filename): \(error)") }
                settled.leave()
            default:
                break
            }
        }

        /// First announced file packet (share type with a payload port).
        func announcedFile() -> Packet? {
            lock.withLock {
                packets.first { $0.type == PacketType.share && $0.payloadPort > 0 }
            }
        }
    }

    private var tags: [String] = []
    private var tmpDirs: [URL] = []

    override func tearDown() {
        for tag in tags { IdentityKeys.delete(tag: tag) }
        tags.removeAll()
        for dir in tmpDirs { try? FileManager.default.removeItem(at: dir) }
        tmpDirs.removeAll()
        super.tearDown()
    }

    private func makePeer(id: String) throws -> Peer {
        let tag = "org.omarchy.flux.test.uploadlive.\(UUID().uuidString)"
        tags.append(tag)
        let key = try TestKeychain.loadOrCreateIdentity(tag: tag)
        let der = try SelfSignedCertificate.issue(key: key, deviceId: id)
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let identity = try XCTUnwrap(TLSIdentity.makeIdentity(certificate: cert, label: tag))
        return Peer(der: der, identity: identity)
    }

    private func scratchDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flux-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tmpDirs.append(dir)
        return dir
    }

    private func pattern(_ n: Int, seed: Int) -> Data {
        Data((0..<n).map { UInt8(($0 * 31 + seed) & 0xFF) })
    }

    private func engine(
        server: Peer, client: Peer, ledger: Ledger, settled: DispatchGroup
    ) throws -> TransferEngine {
        let downloads = try scratchDir()
        return TransferEngine(
            identity: server.identity, peerDER: client.der,
            send: { ledger.recordSend($0) },
            downloadsDir: downloads
        ) { ledger.recordEvent($0, settled: settled) }
    }

    /// Waits for the file announcement, fetches the bytes as the desktop
    /// would, and waits for the engine's completion.
    private func expectBytes(
        _ bytes: Data, ledger: Ledger, client: Peer, server: Peer,
        settled: DispatchGroup, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Packet {
        var announcement: Packet?
        let deadline = Date().addingTimeInterval(15)
        while announcement == nil && Date() < deadline {
            announcement = ledger.announcedFile()
            if announcement == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        let packet = try XCTUnwrap(announcement, "no file announcement", file: file, line: line)
        let got = try Payload.fetch(
            host: "127.0.0.1", port: packet.payloadPort, size: Int64(bytes.count),
            identity: client.identity, expectedPeerDER: server.der)
        XCTAssertEqual(bytes, got, file: file, line: line)
        XCTAssertEqual(.success, settled.wait(timeout: .now() + 15), file: file, line: line)
        return packet
    }

    /// `sendCaptures` through the box: preamble + flagged announcement go
    /// out, the bytes arrive identical, the engine completes.
    func testCaptureRoundTrip() throws {
        let server = try makePeer(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let client = try makePeer(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let bytes = pattern(200_000, seed: 5)
        let dir = try scratchDir()
        let file = dir.appendingPathComponent("IMG_20260928_120000.jpg")
        try bytes.write(to: file)

        let ledger = Ledger()
        let settled = DispatchGroup()
        settled.enter()
        let box = LiveUploadBox()
        XCTAssertFalse(box.attached)
        box.attach(try engine(server: server, client: client, ledger: ledger, settled: settled))
        XCTAssertTrue(box.attached)

        XCTAssertTrue(box.sendCaptures([TransferEngine.CaptureUpload(url: file, photo: true)]))
        let announcement = try expectBytes(
            bytes, ledger: ledger, client: client, server: server, settled: settled)
        // Routing flags ride the announcement (desktop `photo_dir`).
        guard case .file(let record) = ShareMessage.parse(announcement) else {
            return XCTFail("announcement is not a file share")
        }
        XCTAssertTrue(record.photo)
        XCTAssertFalse(record.scan)
        XCTAssertEqual(Int64(bytes.count), ledger.completedBytes)
        XCTAssertTrue(ledger.failures.isEmpty)
        box.detach()
        XCTAssertFalse(box.attached)
    }

    /// `sendFiles` through the box: same bytes, no routing flags.
    func testFileRoundTrip() throws {
        let server = try makePeer(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let client = try makePeer(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let bytes = pattern(50_000, seed: 11)
        let dir = try scratchDir()
        let file = dir.appendingPathComponent("report.txt")
        try bytes.write(to: file)

        let ledger = Ledger()
        let settled = DispatchGroup()
        settled.enter()
        let box = LiveUploadBox()
        box.attach(try engine(server: server, client: client, ledger: ledger, settled: settled))

        XCTAssertTrue(box.sendFiles([file]))
        let announcement = try expectBytes(
            bytes, ledger: ledger, client: client, server: server, settled: settled)
        guard case .file(let record) = ShareMessage.parse(announcement) else {
            return XCTFail("announcement is not a file share")
        }
        XCTAssertFalse(record.photo)
        XCTAssertFalse(record.scan)
        XCTAssertFalse(record.screenshot)
        box.detach()
    }

    /// Captures posted before the attach are held and served on attach (a
    /// capture tap racing session setup is delayed, never dropped).
    func testBoxHoldsPreAttach() throws {
        let server = try makePeer(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let client = try makePeer(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let bytes = pattern(20_000, seed: 23)
        let dir = try scratchDir()
        let file = dir.appendingPathComponent("scan-20260928-120000.pdf")
        try bytes.write(to: file)

        let box = LiveUploadBox()
        // No engine yet: accepted (held), never dropped.
        XCTAssertTrue(box.sendCaptures([TransferEngine.CaptureUpload(url: file, scan: true)]))

        let ledger = Ledger()
        let settled = DispatchGroup()
        settled.enter()
        box.attach(try engine(server: server, client: client, ledger: ledger, settled: settled))
        let announcement = try expectBytes(
            bytes, ledger: ledger, client: client, server: server, settled: settled)
        guard case .file(let record) = ShareMessage.parse(announcement) else {
            return XCTFail("announcement is not a file share")
        }
        XCTAssertTrue(record.scan)
        box.detach()
    }

    /// Detach drops the inlet: sends after it are held, never served into
    /// a dead session.
    func testBoxDetachDropsHeld() throws {
        let server = try makePeer(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let client = try makePeer(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let box = LiveUploadBox()
        let ledger = Ledger()
        let settled = DispatchGroup()
        box.attach(try engine(server: server, client: client, ledger: ledger, settled: settled))
        XCTAssertTrue(box.attached)
        box.detach()
        XCTAssertFalse(box.attached)
        // Held after detach: accepted by the box, but no engine serves it.
        let dir = try scratchDir()
        let file = dir.appendingPathComponent("IMG_x.jpg")
        try pattern(100, seed: 1).write(to: file)
        XCTAssertTrue(box.sendFiles([file]))
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(ledger.packets.isEmpty)
    }
}
#endif
