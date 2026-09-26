import XCTest
@testable import FluxKit

final class ProtocolTests: XCTestCase {
    func testPacketIDAcceptsNumberAndString() {
        for line in [
            #"{"id":1727260000000,"type":"kdeconnect.ping","body":{}}"#,
            #"{"id":"1727260000000","type":"kdeconnect.ping","body":{}}"#,
            #"{"id":1727260000000.0,"type":"kdeconnect.ping"}"#,
        ] {
            let p = Packet.parse(line)
            XCTAssertEqual(p?.id, 1_727_260_000_000, line)
            XCTAssertEqual(p?.type, "kdeconnect.ping", line)
        }
    }

    func testParseRejectsLinesWithoutType() {
        XCTAssertNil(Packet.parse(#"{"id":1,"body":{}}"#))
        XCTAssertNil(Packet.parse(#"{"id":1,"type":5}"#))
        XCTAssertNil(Packet.parse("not json"))
    }

    func testSerializeOmitsPayloadFieldsWithoutPayload() {
        let s = String(decoding: Packet(PacketType.ping, ["message": "hi"]).serialize(), as: UTF8.self)
        XCTAssertTrue(s.hasSuffix("\n"))
        XCTAssertFalse(s.contains("payloadSize"))
        XCTAssertFalse(s.contains("payloadTransferInfo"))
    }

    func testPayloadRoundTrip() {
        let port = Packet(PacketType.share, ["filename": "a.txt"], payloadSize: 12, payloadPort: 1739)
        let parsedPort = Packet.parse(port.serialize())
        XCTAssertEqual(parsedPort?.payloadSize, 12)
        XCTAssertEqual(parsedPort?.payloadPort, 1739)
        XCTAssertNil(parsedPort?.payloadTunnel)

        let tunnel = Packet(PacketType.share, ["filename": "a.txt"], payloadSize: 12, payloadTunnel: "tok")
        let parsedTunnel = Packet.parse(tunnel.serialize())
        XCTAssertEqual(parsedTunnel?.payloadTunnel, "tok")
        XCTAssertEqual(parsedTunnel?.payloadPort, 0)
        XCTAssertTrue(parsedTunnel?.hasPayload ?? false)
    }

    func testLooseBodyTypes() {
        let p = Packet.parse(#"{"id":1,"type":"t","body":{"a":"8","b":8.0,"c":"true","d":[1,"x"]}}"#)!
        XCTAssertEqual(p.int("a"), 8)
        XCTAssertEqual(p.int("b"), 8)
        XCTAssertEqual(p.bool("c"), true)
        XCTAssertEqual(p.strings("d"), ["1", "x"])
    }

    func testCleanName() {
        XCTAssertEqual(cleanName(#"Bob's "Pixel" (8)!"#), "Bobs Pixel 8")
        XCTAssertEqual(cleanName("omarchy-framework"), "omarchy-framework")
        XCTAssertEqual(cleanName("a name that is much longer than 32 characters"), "a name that is much longer than")
        XCTAssertEqual(cleanName("..."), "Mac")
    }

    func testValidDeviceID() {
        XCTAssertTrue(validDeviceId("9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b"))
        XCTAssertFalse(validDeviceId("short"))
        XCTAssertFalse(validDeviceId("9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b!"))
    }

    func testIdentityFromPacketRequiresValidID() {
        let good = Packet(PacketType.identity, ["deviceId": "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b", "deviceName": "desk", "protocolVersion": 8, "incomingCapabilities": ["flux.tunnel"]])
        let id = Identity.from(good)
        XCTAssertEqual(id?.deviceName, "desk")
        XCTAssertEqual(id?.isFlux, true)
        let bad = Packet(PacketType.identity, ["deviceId": "x"])
        XCTAssertNil(Identity.from(bad))
    }

    func testGeneratedCertificateAndVerificationKey() throws {
        let a = try LocalCertificate.generate(deviceId: "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b")
        let b = try LocalCertificate.generate(deviceId: "0f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b")
        XCTAssertEqual(a.deviceId, "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b")
        let ka = verificationKey(ownCertificate: a.certificateDER, peerCertificate: b.certificateDER, timestamp: 1_727_260_000)
        let kb = verificationKey(ownCertificate: b.certificateDER, peerCertificate: a.certificateDER, timestamp: 1_727_260_000)
        XCTAssertEqual(ka, kb)
        XCTAssertEqual(ka.count, 8)
        XCTAssertNotEqual(ka, verificationKey(ownCertificate: a.certificateDER, peerCertificate: b.certificateDER, timestamp: 1_727_260_001))
    }

    func testLoadOrCreateKeepsIdentity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try LocalCertificate.loadOrCreate(directory: dir)
        let second = try LocalCertificate.loadOrCreate(directory: dir)
        XCTAssertTrue(validDeviceId(first.deviceId))
        XCTAssertEqual(first.deviceId, second.deviceId)
        XCTAssertEqual(first.certificateDER, second.certificateDER)
    }
}
