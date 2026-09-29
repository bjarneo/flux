import XCTest
import Foundation
@testable import FluxNet
@testable import FluxProto

/// Loopback + framing tests. No entitlements needed; run on macOS CI too.
final class FluxNetTests: XCTestCase {
    func testSplitLinesRoundTrip() throws {
        let a = try Packet.of(PacketType.ping, ("message", "hi")).serialize()
        let b = try Packet.of(PacketType.ping, ("message", "yo")).serialize()
        let lines = try PacketCodec.splitLines(a + b)
        XCTAssertEqual(2, lines.count)
        XCTAssertEqual("hi", try PacketCodec.decode(lines[0]).string("message"))
        XCTAssertEqual("yo", try PacketCodec.decode(lines[1]).string("message"))
    }

    func testSplitLinesRejectsOversize() {
        let big = Data(repeating: 0x41, count: FluxProto.maxPacketSize + 2) + Data([0x0A])
        XCTAssertThrowsError(try PacketCodec.splitLines(big))
    }

    func testBroadcastRequiresPort() throws {
        let id = Identity.phone(deviceId: "0123456789abcdef0123456789abcdef", name: "iPhone", tcpPort: 1717)
        let line = try Discovery.broadcastLine(identity: id, tcpPort: 1717)
        XCTAssertNotNil(Discovery.parseBroadcast(line, ownId: "fedcba9876543210fedcba9876543210"))
        // Own ID is ignored.
        XCTAssertNil(Discovery.parseBroadcast(line, ownId: "0123456789abcdef0123456789abcdef"))
        // Post-TLS identity without tcpPort is not a broadcast.
        let noPort = try id.toPacket().serialize()
        XCTAssertNil(Discovery.parseBroadcast(noPort, ownId: "fedcba9876543210fedcba9876543210"))
    }

    func testPreferredLinkAfterWindowAlwaysReplaces() {
        let old = LinkDescriptor(peerId: "peer", outgoing: true, started: Date(timeIntervalSinceNow: -10))
        let next = LinkDescriptor(peerId: "peer", outgoing: false, started: Date())
        XCTAssertEqual(next, preferredLink(old: old, next: next, selfId: "self0123456789abcdef0123456789ab"))
    }

    func testPreferredLinkInWindowKeepsLargerOpener() {
        // Mirrors Go TestPreferredAgrees: both sides keep the link opened by
        // the device with the larger ID.
        let selfId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let peerId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let old = LinkDescriptor(peerId: peerId, outgoing: false, started: Date())
        let next = LinkDescriptor(peerId: peerId, outgoing: true, started: Date())
        // self opened `next`, peer opened `old`; peer ID is larger, so `old` wins.
        XCTAssertEqual(old, preferredLink(old: old, next: next, selfId: selfId))
    }

    func testTrustValidation() {
        let id = "0123456789abcdef0123456789abcdef"
        let pinned = Data([10, 20, 30])
        func failure(
            commonName: String? = id,
            peerDER: Data? = nil,
            pinnedDER: Data? = nil
        ) -> TrustValidation.Failure? {
            let r = TrustValidation.validate(
                commonName: commonName, peerDER: peerDER, expectedDeviceId: id,
                deviceName: "pc", pinnedDER: pinnedDER)
            if case .failure(let f) = r { return f }
            return nil
        }
        // First connect (nothing pinned) succeeds.
        XCTAssertNil(failure(peerDER: pinned))
        // Same cert on reconnect succeeds.
        XCTAssertNil(failure(peerDER: pinned, pinnedDER: pinned))
        // Replacement certificate is a re-pair, never silent.
        XCTAssertEqual(.certificateChanged(deviceName: "pc"), failure(peerDER: Data([99]), pinnedDER: pinned))
        // CN must match the plaintext identity.
        XCTAssertEqual(
            .identityMismatch(commonName: "other00000000000000000000000000x", deviceId: id),
            failure(commonName: "other00000000000000000000000000x", peerDER: pinned))
        // No certificate, no link.
        XCTAssertEqual(.noCertificate, failure(commonName: nil, peerDER: nil))
        XCTAssertEqual(.noCertificate, failure(peerDER: nil))
    }

    func testPreTLSValidation() throws {
        let own = "0123456789abcdef0123456789abcdef"
        let peer = Identity.phone(deviceId: "fedcba9876543210fedcba9876543210", name: "iPhone", tcpPort: 1717)
        // Plain identity naming us is accepted.
        let ok = peer.toPacket()
        var body = ok.body
        body["targetDeviceId"] = JSONValue.string(own)
        body["targetProtocolVersion"] = JSONValue.integer(8)
        let named = Packet(type: PacketType.identity, body: body)
        XCTAssertNotNil(FluxLink.validatesPreTLS(named, ownId: own))
        // Wrong target is refused.
        var badBody = ok.body
        badBody["targetDeviceId"] = JSONValue.string("other00000000000000000000000000x")
        XCTAssertNil(FluxLink.validatesPreTLS(Packet(type: PacketType.identity, body: badBody), ownId: own))
        // Wrong protocol is refused.
        var badVer = ok.body
        badVer["targetDeviceId"] = JSONValue.string(own)
        badVer["targetProtocolVersion"] = JSONValue.integer(7)
        XCTAssertNil(FluxLink.validatesPreTLS(Packet(type: PacketType.identity, body: badVer), ownId: own))
    }
}
