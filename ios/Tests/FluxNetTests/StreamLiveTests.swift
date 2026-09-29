import XCTest
import Foundation
import Darwin
import CryptoKit
#if canImport(Security)
import Security
#endif
@testable import FluxNet
@testable import FluxProto
@testable import FluxCore

/// Live producer seam over loopback TLS: chunked serves reassemble
/// byte-identical with an incremental SHA-256, stops close promptly and
/// stay silent, and `LiveStreamBox` holds pre-attach offers for the
/// session engine. Fixed-blob serves stay untouched (`StreamOffer` path);
/// multi-MB/file round-trips run E2E against `tools/test_peer.py`.
#if canImport(Security)
final class StreamLiveTests: XCTestCase {
    private struct Peer: @unchecked Sendable {
        let der: Data
        let identity: SecIdentity
    }

    /// Thread-safe event/packet ledger (PayloadTests `Box` parity — the
    /// engine reports off-thread).
    final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        var startedPort: Int?
        var doneBytes: Int64?
        var doneSha: String?
        var failures: [String] = []
        var packets: [Packet] = []

        func recordSend(_ p: Packet) -> Bool {
            lock.withLock { packets.append(p) }
            return true
        }

        func recordEvent(_ e: StreamEvent, started: DispatchGroup, settled: DispatchGroup) {
            switch e {
            case .started(_, let port):
                lock.withLock { startedPort = port }
                started.leave()
            case .done(_, let bytes, let sha):
                lock.withLock {
                    doneBytes = bytes
                    doneSha = sha
                }
                settled.leave()
            case .failed(_, let error):
                lock.withLock { failures.append(error) }
                settled.leave()
            case .progress:
                break
            }
        }

        func snapshot() -> (port: Int?, bytes: Int64?, sha: String?, failures: [String], packets: [Packet]) {
            lock.withLock { (startedPort, doneBytes, doneSha, failures, packets) }
        }
    }

    private var tags: [String] = []

    override func tearDown() {
        for tag in tags { IdentityKeys.delete(tag: tag) }
        tags.removeAll()
        super.tearDown()
    }

    private func makePeer(id: String) throws -> Peer {
        let tag = "org.omarchy.flux.test.streamlive.\(UUID().uuidString)"
        tags.append(tag)
        let key = try TestKeychain.loadOrCreateIdentity(tag: tag)
        let der = try SelfSignedCertificate.issue(key: key, deviceId: id)
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let identity = try XCTUnwrap(TLSIdentity.makeIdentity(certificate: cert, label: tag))
        return Peer(der: der, identity: identity)
    }

    private func streamOf(_ parts: [Data]) -> AsyncStream<Data> {
        AsyncStream { cont in
            for part in parts { cont.yield(part) }
            cont.finish()
        }
    }

    private func pattern(_ n: Int, seed: Int) -> Data {
        Data((0..<n).map { UInt8(($0 * 31 + seed) & 0xFF) })
    }

    /// Chunked live serve reassembles byte-identical with the SHA-256 of
    /// the concatenation, and the stop packet follows (announceStop).
    func testLiveRoundTrip() throws {
        let server = try makePeer(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let client = try makePeer(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let parts = [pattern(10_000, seed: 7), pattern(50_000, seed: 13), pattern(5_000, seed: 29)]
        let total = parts.reduce(0) { $0 + $1.count }
        let expectedSha = SHA256.hash(data: parts.reduce(Data(), +)).map { String(format: "%02x", $0) }.joined()

        let ledger = Ledger()
        let started = DispatchGroup()
        started.enter()
        let settled = DispatchGroup()
        settled.enter()
        let engine = StreamEngine(
            identity: server.identity, peerDER: client.der,
            send: { ledger.recordSend($0) }
        ) { ledger.recordEvent($0, started: started, settled: settled) }

        engine.serveLive(LiveOffer(
            kind: .mic,
            buildStart: { MicPackets.start(port: $0) },
            chunks: streamOf(parts), announceStop: true))

        XCTAssertEqual(.success, started.wait(timeout: .now() + 15))
        let port = try XCTUnwrap(ledger.snapshot().port)
        let got = try Payload.fetch(
            host: "127.0.0.1", port: port, size: Int64(total),
            identity: client.identity, expectedPeerDER: server.der)
        XCTAssertEqual(parts.reduce(Data(), +), got)
        XCTAssertEqual(.success, settled.wait(timeout: .now() + 15))
        let snap = ledger.snapshot()
        XCTAssertEqual(Int64(total), snap.bytes)
        XCTAssertEqual(expectedSha, snap.sha)
        // Start + stop packets, in order (the stop is the announceStop).
        // The stop send lands just after `.done` wakes us — poll for it.
        let deadline = Date().addingTimeInterval(5)
        while ledger.snapshot().packets.count < 2 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(2, ledger.snapshot().packets.count)
    }

    /// A stop closes the listener promptly (a waiting desktop gets
    /// connection-refused, not a 10 s accept timeout), sends the stop
    /// packet, and never reports `.done`.
    func testLiveStopIsSilent() throws {
        let server = try makePeer(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let client = try makePeer(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let ledger = Ledger()
        let started = DispatchGroup()
        started.enter()
        let settled = DispatchGroup()
        let engine = StreamEngine(
            identity: server.identity, peerDER: client.der,
            send: { ledger.recordSend($0) }
        ) { ledger.recordEvent($0, started: started, settled: settled) }

        // Never-ending producer: without the stop this serve would run
        // until the desktop disconnects.
        let (producer, continuation) = AsyncStream<Data>.makeStream()
        engine.serveLive(LiveOffer(
            kind: .mic,
            buildStart: { MicPackets.start(port: $0) },
            chunks: producer, announceStop: true))
        XCTAssertEqual(.success, started.wait(timeout: .now() + 15))
        let port = try XCTUnwrap(ledger.snapshot().port)

        engine.stopLive(kind: .mic, announce: true)
        continuation.finish()
        // The listener is closed: the desktop dial fails fast.
        XCTAssertThrowsError(try Payload.fetch(
            host: "127.0.0.1", port: port, size: 10,
            identity: client.identity, expectedPeerDER: server.der))
        Thread.sleep(forTimeInterval: 1.0)
        let snap = ledger.snapshot()
        XCTAssertNil(snap.bytes)
        XCTAssertTrue(snap.failures.isEmpty)
        // Start + stop, no `.done` (same land-after-wake race as above).
        let deadline = Date().addingTimeInterval(5)
        while ledger.snapshot().packets.count < 2 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(2, ledger.snapshot().packets.count)
    }

    /// Offers posted before the session engine attaches are held per kind
    /// and served on attach (a UI Start racing session setup is delayed,
    /// never dropped). A dead sender proves the held offer was served.
    func testLiveBoxQueuesPreAttach() throws {
        let server = try makePeer(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let client = try makePeer(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let box = LiveStreamBox()
        box.serve(LiveOffer(
            kind: .mic,
            buildStart: { MicPackets.start(port: $0) },
            chunks: streamOf([pattern(100, seed: 3)])))
        let ledger = Ledger()
        let failed = DispatchGroup()
        failed.enter()
        // Dead sender: the serve must fail "not connected", proving the
        // held offer reached an engine on attach.
        let engine = StreamEngine(
            identity: server.identity, peerDER: client.der,
            send: { _ in false }
        ) { ledger.recordEvent($0, started: DispatchGroup(), settled: failed) }
        box.attach(engine)
        XCTAssertEqual(.success, failed.wait(timeout: .now() + 15))
        XCTAssertEqual(["not connected"], ledger.snapshot().failures)
        box.detach()
    }

    /// A stop before attach drops the held offer: attaching afterwards
    /// serves nothing.
    func testLiveBoxStopDropsHeld() throws {
        let box = LiveStreamBox()
        box.serve(LiveOffer(
            kind: .mic,
            buildStart: { MicPackets.start(port: $0) },
            chunks: streamOf([pattern(100, seed: 3)])))
        box.stop(kind: .mic)
        let ledger = Ledger()
        let server = try makePeer(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let client = try makePeer(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        // Recording sender: any serve would emit `.started` first.
        let engine = StreamEngine(
            identity: server.identity, peerDER: client.der,
            send: { ledger.recordSend($0) }
        ) { _ in }
        box.attach(engine)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(ledger.snapshot().packets.isEmpty)
        box.detach()
    }
}
#endif
