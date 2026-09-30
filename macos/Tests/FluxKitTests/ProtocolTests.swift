import XCTest
@testable import FluxKit

final class ProtocolTests: XCTestCase {
    func testPacketIDAcceptsNumberAndString() {
        for line in [
            #"{"id":1727260000000,"type":"flux.ping","body":{}}"#,
            #"{"id":"1727260000000","type":"flux.ping","body":{}}"#,
            #"{"id":1727260000000.0,"type":"flux.ping"}"#,
        ] {
            let p = Packet.parse(line)
            XCTAssertEqual(p?.id, 1_727_260_000_000, line)
            XCTAssertEqual(p?.type, "flux.ping", line)
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
        let noVersion = Packet(PacketType.identity, ["deviceId": "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b", "deviceName": "desk", "incomingCapabilities": ["flux.tunnel"]])
        XCTAssertNil(Identity.from(noVersion), "an identity without protocolVersion is not a Flux peer")
    }

    func testIdentityApp() {
        let id = Identity(deviceId: "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b", deviceName: "mac", deviceType: "laptop", protocolVersion: 8,
                          incoming: [], outgoing: [], app: "macos", appVersion: "0.7.0")
        let back = Packet.parse(id.packet().serialize()).flatMap(Identity.from)
        XCTAssertEqual(back?.app, "macos")
        XCTAssertEqual(back?.appVersion, "0.7.0")
        // An earlier Flux sends no app fields.
        let old = Identity(deviceId: "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b", deviceName: "pc", deviceType: "laptop", protocolVersion: 8, incoming: [], outgoing: [])
        let parsed = Packet.parse(old.packet().serialize())
        XCTAssertNil(parsed?.string("app"))
        XCTAssertEqual(parsed.flatMap(Identity.from)?.app, "")
        XCTAssertEqual(parsed.flatMap(Identity.from)?.appVersion, "")
    }

    func testOnlyOmarchyComputersAreFlux() {
        func identity(_ type: String, _ incoming: [String]) -> Identity {
            Identity(deviceId: "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b", deviceName: "x", deviceType: type, protocolVersion: 8, incoming: incoming, outgoing: [])
        }
        XCTAssertTrue(identity("desktop", ["flux.tunnel"]).isFlux, "fluxd on a desktop")
        XCTAssertTrue(identity("laptop", ["flux.tunnel"]).isFlux, "fluxd on a laptop")
        XCTAssertFalse(identity("phone", ["flux.tunnel"]).isFlux, "Flux for Android also accepts flux.tunnel")
        XCTAssertFalse(identity("tablet", ["flux.tunnel"]).isFlux)
        XCTAssertFalse(identity("laptop", ["flux.ping"]).isFlux, "another Mac")
    }

    func testGeneratedCertificateAndVerificationKey() throws {
        let a = try LocalCertificate.generate(deviceId: "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b")
        let b = try LocalCertificate.generate(deviceId: "0f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b")
        XCTAssertEqual(a.deviceId, "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b")
        let ka = verificationKey(ownCertificate: a.certificateDER, peerCertificate: b.certificateDER, timestamp: 1_727_260_000)
        let kb = verificationKey(ownCertificate: b.certificateDER, peerCertificate: a.certificateDER, timestamp: 1_727_260_000)
        XCTAssertEqual(ka, kb)
        XCTAssertEqual(ka.count, 16)
        XCTAssertEqual(ka, ka.uppercased())
        XCTAssertNotEqual(ka, verificationKey(ownCertificate: a.certificateDER, peerCertificate: b.certificateDER, timestamp: 1_727_260_001))
    }

    /// The same vector as in fluxd and Flux for Android.
    func testVerificationKeyVector() {
        let a: [UInt8] = [0x30, 0x82, 0x01, 0x22, 0x80]
        let b: [UInt8] = [0x30, 0x82, 0x01, 0x22, 0x7F]
        XCTAssertEqual(verificationKey(ownKey: a, peerKey: b, timestamp: 1_790_000_000), "5EE6825F974ED59A")
        XCTAssertEqual(verificationKey(ownKey: b, peerKey: a, timestamp: 1_790_000_000), "5EE6825F974ED59A")
        XCTAssertEqual(verificationKey(ownKey: a, peerKey: b, timestamp: 0), "5BB22DB11047F34B")
        XCTAssertEqual(verificationKey(ownKey: b, peerKey: a, timestamp: 0), "5BB22DB11047F34B")
    }

    func testLargeNumbersInAPacketDoNotStopTheApp() {
        for line in [
            #"{"type":"x","id":"1e300"}"#,
            #"{"type":"x","id":1e300}"#,
            #"{"type":"x","id":-1e300}"#,
            #"{"type":"x","id":"-1e19"}"#,
            #"{"type":"x","id":1e19}"#,
            #"{"type":"x","id":9.3e18}"#,
            #"{"type":"x","id":"9223372036854775808"}"#,
            #"{"type":"x","id":99999999999999999999}"#,
            #"{"type":"x","id":"NaN"}"#,
        ] {
            let p = Packet.parse(line)
            XCTAssertEqual(p?.type, "x", line)
            XCTAssertEqual(p?.id, 0, line)
        }
        XCTAssertEqual(Packet.parse(#"{"type":"x","payloadSize":"1e300"}"#)?.payloadSize, 0)
        XCTAssertEqual(Packet.parse(#"{"type":"x","payloadSize":"9.3e18"}"#)?.payloadSize, 0)
        XCTAssertEqual(Packet.parse(#"{"type":"x","payloadSize":"1e30"}"#)?.payloadSize, 0)
        XCTAssertEqual(Packet.parse(#"{"type":"x","payloadTransferInfo":{"port":"1e300"}}"#)?.payloadPort, 0)
        XCTAssertEqual(Packet.parse(#"{"type":"x","id":-9223372036854775808}"#)?.id, Int64.min)
    }

    func testInt64RefusesValuesOutsideItsRange() {
        XCTAssertNil(JSONValue.double(1e300).int64)
        XCTAssertNil(JSONValue.double(-1e19).int64)
        XCTAssertNil(JSONValue.double(9.3e18).int64)
        XCTAssertNil(JSONValue.double(9.223372036854775808e18).int64, "2^63 is 1 above Int64.max")
        XCTAssertNil(JSONValue.double(.nan).int64)
        XCTAssertNil(JSONValue.double(.infinity).int64)
        XCTAssertNil(JSONValue.string("1e300").int64)
        XCTAssertNil(JSONValue.string("9223372036854775808").int64)
        XCTAssertNil(JSONValue.string("-1e19").int64)
        XCTAssertEqual(JSONValue.string("-9223372036854775808").int64, Int64.min)
        XCTAssertEqual(JSONValue.double(-9.223372036854775808e18).int64, Int64.min)
        XCTAssertEqual(JSONValue.double(12.9).int64, 12)
        XCTAssertEqual(JSONValue.double(-12.9).int64, -12)
        XCTAssertEqual(JSONValue.string("12.9").int64, 12)
        XCTAssertNil(JSONValue.double(1e19).int)
    }

    func testIdentityWithLargeNumbers() {
        let id = "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b"
        XCTAssertNil(Packet.parse(#"{"type":"flux.identity","body":{"deviceId":"\#(id)","protocolVersion":"1e300","tcpPort":"1e300"}}"#).flatMap(Identity.from))
        let udp = Packet.parse(#"{"type":"flux.identity","id":1e19,"body":{"deviceId":"\#(id)","protocolVersion":8,"tcpPort":1e300}}"#)
        XCTAssertEqual(udp.flatMap(Identity.from)?.tcpPort, 0)
    }

    func testPairTimestampCheckCannotOverflow() {
        let now: Int64 = 1_790_000_000
        for ts in [Int64.min, Int64.max, 0, -1, Int64.min + 1, now - 1801, now + 1801] {
            XCTAssertFalse(Device.timestampFresh(ts, now: now), "\(ts)")
        }
        for ts in [now, now - 1800, now + 1800] {
            XCTAssertTrue(Device.timestampFresh(ts, now: now), "\(ts)")
        }
        let p = Packet.parse(#"{"type":"flux.pair","body":{"pair":true,"timestamp":"-9223372036854775808"}}"#)
        XCTAssertEqual(p?.long("timestamp"), Int64.min)
        XCTAssertNil(Packet.parse(#"{"type":"flux.pair","body":{"pair":true,"timestamp":1e19}}"#)?.long("timestamp"))
        XCTAssertNil(Packet.parse(#"{"type":"flux.pair","body":{"pair":true,"timestamp":"1e30"}}"#)?.long("timestamp"))
    }

    func testDataDirectoryKeepsItsDefaultsDomain() {
        let a = FluxPaths.standard(["FLUX_DATA_DIR": "/tmp/flux-a"])
        XCTAssertEqual(a.suite, FluxPaths.standard(["FLUX_DATA_DIR": "/tmp/flux-a"]).suite)
        XCTAssertEqual(a.suite, FluxPaths.testSuite("/tmp/flux-a"), "the name does not change with the launch")
        XCTAssertTrue(a.suite.hasPrefix("org.omarchy.flux.test."))
        XCTAssertNotEqual(a.suite, FluxPaths.standard(["FLUX_DATA_DIR": "/tmp/flux-b"]).suite)
    }

    func testLoadOrCreateKeepsIdentity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try LocalCertificate.loadOrCreate(directory: dir)
        let second = try LocalCertificate.loadOrCreate(directory: dir)
        XCTAssertTrue(validDeviceId(first.deviceId))
        XCTAssertEqual(first.deviceId, second.deviceId)
        XCTAssertEqual(first.certificateDER, second.certificateDER)
        let key = dir.appendingPathComponent(LocalCertificate.keyFile).path
        let mode = try FileManager.default.attributesOfItem(atPath: key)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "only the user reads the key")
    }

    func testLoadOrCreateKeepsAnIdentityThatDoesNotRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try LocalCertificate.loadOrCreate(directory: dir)
        let key = dir.appendingPathComponent(LocalCertificate.keyFile)
        try Data("damaged".utf8).write(to: key)
        XCTAssertThrowsError(try LocalCertificate.loadOrCreate(directory: dir), "a damaged key is not replaced") { error in
            XCTAssertFalse(error is IdentityUnreadable, "a damaged key does not read later either")
        }
        XCTAssertEqual(try Data(contentsOf: key), Data("damaged".utf8), "the file stays for the user to recover")
    }

    /// Before the first unlock after a restart, iOS keeps the identity
    /// locked. The start fails, and the app starts the core again later.
    func testLoadOrCreateKeepsAnIdentityThatCannotBeReadNow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try LocalCertificate.loadOrCreate(directory: dir)
        let key = dir.appendingPathComponent(LocalCertificate.keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: key.path)
        XCTAssertThrowsError(try LocalCertificate.loadOrCreate(directory: dir)) { error in
            XCTAssertTrue(error is IdentityUnreadable, "\(error)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        XCTAssertEqual(try LocalCertificate.loadOrCreate(directory: dir).deviceId, first.deviceId, "the identity stays")
    }
}
