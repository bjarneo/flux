import XCTest
import Foundation
@testable import FluxCore
@testable import FluxProto

/// Pairing state-machine matrix. Mirrors Android `core/Device.kt` pairing
/// methods and Go `internal/core/pairing.go handlePair`.
///
/// Synthetic SPKIs reuse the `FluxProtoTests` vector:
/// `a = [0x30,0x82,0x01,0x22,0x80]`, `b = [0x30,0x82,0x01,0x22,0x7F]`,
/// key at ts 1790000000 is `5EE6825F`, key without stamp is `5BB22DB1`.
final class PairingSessionTests: XCTestCase {
    private let a = Data([0x30, 0x82, 0x01, 0x22, 0x80])
    private let b = Data([0x30, 0x82, 0x01, 0x22, 0x7F])
    private let t0: Int64 = 1_790_000_000

    private func session(
        peerVersion: Int = 8,
        now: Date? = nil,
        ownSPKI: Data? = nil,
        peerSPKI: Data? = nil
    ) -> PairingSession {
        let at = now ?? Date(timeIntervalSince1970: TimeInterval(t0))
        return PairingSession(
            peerId: "fedcba9876543210fedcba9876543210",
            peerProtocolVersion: peerVersion,
            ownSPKI: ownSPKI ?? a,
            peerSPKI: peerSPKI ?? b,
            now: { at }
        )
    }

    // MARK: - Outgoing (this phone pairs to the desktop)

    func testOutgoingAccept() async {
        let s = session()
        let started = await s.startOutgoing(timestamp: t0)
        XCTAssertEqual("5EE6825F", started?.key)
        XCTAssertEqual(true, started?.packet.bool("pair"))
        XCTAssertEqual(t0, started?.packet.long("timestamp"))
        // Second start while open is refused.
        let __v1 = await s.startOutgoing(timestamp: t0)
        XCTAssertNil(__v1)

        let (event, send) = await s.receive(Pairing.accept())
        XCTAssertEqual(.accepted, event)
        XCTAssertTrue(send.isEmpty)
        let __v2 = await s.isPaired
        XCTAssertTrue(__v2)
    }

    func testOutgoingReject() async {
        let s = session()
        _ = await s.startOutgoing(timestamp: t0)
        let (event, send) = await s.receive(Pairing.reject())
        XCTAssertEqual(.closed(reason: .rejectedByPeer), event)
        XCTAssertTrue(send.isEmpty)
        let __v3 = await s.isPaired
        XCTAssertFalse(__v3)
    }

    func testOutgoingTimeoutSendsCancel() async {
        let s = session()
        _ = await s.startOutgoing(timestamp: t0)
        let at = Date(timeIntervalSince1970: TimeInterval(t0))
        let (early, _) = await s.expire(now: at.addingTimeInterval(29))
        XCTAssertNil(early)
        let (event, send) = await s.expire(now: at.addingTimeInterval(31))
        XCTAssertEqual(.closed(reason: .timedOut), event)
        XCTAssertEqual(1, send.count)
        XCTAssertEqual(false, send[0].bool("pair"))
        let __v4 = await s.isPaired
        XCTAssertFalse(__v4)
    }

    func testSimultaneousRequestsResolve() async {
        let s = session()
        _ = await s.startOutgoing(timestamp: t0)
        // The desktop dialed us at the same time: accept and finish,
        // like Android (`Requested -> pairingDone`) and Go.
        let (event, _) = await s.receive(Pairing.request(timestamp: t0))
        XCTAssertEqual(.accepted, event)
        let __v5 = await s.isPaired
        XCTAssertTrue(__v5)
    }

    // MARK: - Incoming (desktop pairs to this phone)

    func testIncomingAccept() async {
        let s = session()
        let (event, send) = await s.receive(Pairing.request(timestamp: t0))
        XCTAssertEqual(.showRequest(key: "5EE6825F"), event)
        XCTAssertTrue(send.isEmpty)

        let accept = await s.accept()
        XCTAssertEqual(true, accept?.bool("pair"))
        XCTAssertFalse(accept?.has("timestamp") ?? true)
        let __v6 = await s.isPaired
        XCTAssertTrue(__v6)
    }

    func testIncomingReject() async {
        let s = session()
        _ = await s.receive(Pairing.request(timestamp: t0))
        let reject = await s.reject()
        XCTAssertEqual(false, reject?.bool("pair"))
        let __v7 = await s.isPaired
        XCTAssertFalse(__v7)
        // Idle accept/reject do nothing.
        let __v8 = await s.accept()
        XCTAssertNil(__v8)
        let __v9 = await s.reject()
        XCTAssertNil(__v9)
    }

    func testIncomingTimeoutSendsNothing() async {
        let s = session()
        _ = await s.receive(Pairing.request(timestamp: t0))
        let at = Date(timeIntervalSince1970: TimeInterval(t0))
        // Incoming window is 25 s (shorter than the 30 s outgoing window).
        let (event, send) = await s.expire(now: at.addingTimeInterval(26))
        XCTAssertEqual(.closed(reason: .timedOut), event)
        XCTAssertTrue(send.isEmpty)
    }

    func testMissingTimestampRefused() async {
        let s = session()
        // Bare `{"pair": true}` while idle is a v8 request without a
        // timestamp: refuse it like Android ("sent no timestamp").
        let (event, send) = await s.receive(Pairing.accept())
        XCTAssertEqual(.refused(reason: .missingTimestamp), event)
        XCTAssertEqual(1, send.count)
        XCTAssertEqual(false, send[0].bool("pair"))
        let __v10 = await s.isPaired
        XCTAssertFalse(__v10)
    }

    func testClockSkewRefused() async {
        let s = session()
        let (event, send) = await s.receive(Pairing.request(timestamp: t0 + 1801))
        XCTAssertEqual(.refused(reason: .clockSkew), event)
        XCTAssertEqual(1, send.count)
        let (event2, _) = await s.receive(Pairing.request(timestamp: t0 - 1801))
        XCTAssertEqual(.refused(reason: .clockSkew), event2)
    }

    func testLegacyV7NeedsNoTimestamp() async {
        let s = session(peerVersion: 7)
        let (event, _) = await s.receive(Pairing.accept())
        // Key omits the timestamp for old peers.
        XCTAssertEqual(.showRequest(key: "5BB22DB1"), event)
    }

    // MARK: - Paired transitions

    func testUnpairBothDirections() async {
        let s = session()
        _ = await s.startOutgoing(timestamp: t0)
        _ = await s.receive(Pairing.accept())
        let __v11 = await s.isPaired
        XCTAssertTrue(__v11)

        let pkt = await s.unpair()
        XCTAssertEqual(false, pkt?.bool("pair"))

        // Peer unpairs us.
        let s2 = session()
        _ = await s2.startOutgoing(timestamp: t0)
        _ = await s2.receive(Pairing.accept())
        let (event, _) = await s2.receive(Pairing.reject())
        XCTAssertEqual(.closed(reason: .unpairedByPeer), event)
        let __v12 = await s2.isPaired
        XCTAssertFalse(__v12)
    }

    func testPeerRelostTrustAsksAgain() async {
        let s = session()
        _ = await s.startOutgoing(timestamp: t0)
        _ = await s.receive(Pairing.accept())
        let __v13 = await s.isPaired
        XCTAssertTrue(__v13)

        // The desktop reinstalled and asks again: drop trust, show the key.
        let (event, _) = await s.receive(Pairing.request(timestamp: t0))
        XCTAssertEqual(.trustReset(key: "5EE6825F"), event)
        let __v14 = await s.isPaired
        XCTAssertFalse(__v14)
        let __v15 = await s.accept()
        XCTAssertNotNil(__v15)
        let __v16 = await s.isPaired
        XCTAssertTrue(__v16)
    }

    func testPeerResetInvalidDropsTrust() async {
        let s = session()
        _ = await s.startOutgoing(timestamp: t0)
        _ = await s.receive(Pairing.accept())

        // Invalid re-request still drops trust (like Go), but shows nothing.
        let (event, send) = await s.receive(Pairing.request(timestamp: t0 + 9999))
        XCTAssertEqual(.trustResetRefused(reason: .clockSkew), event)
        XCTAssertEqual(1, send.count)
        let __v17 = await s.isPaired
        XCTAssertFalse(__v17)

        // A fresh valid request works afterwards.
        let (event2, _) = await s.receive(Pairing.request(timestamp: t0))
        XCTAssertEqual(.showRequest(key: "5EE6825F"), event2)
    }
}
