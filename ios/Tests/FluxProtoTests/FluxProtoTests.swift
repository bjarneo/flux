import XCTest
@testable import FluxProto

/// Ports of Android `protocol/ProtocolTest.kt` + Go `internal/proto/proto_test.go`.
/// The verification-key and message vectors must stay byte-identical across
/// Go, Kotlin, and Swift or pairing/approval UX breaks.
final class FluxProtoTests: XCTestCase {
    func testPacketRoundTrip() throws {
        let p = Packet(type: PacketType.share, body: ["filename": .string("a b.jpg"), "open": .bool(false), "numberOfFiles": .integer(2)], id: 42, payloadSize: 1234, payloadPort: 1740)
        let line = try p.serialize()
        XCTAssertTrue(line.last == 0x0A)
        let q = try XCTUnwrap(Packet.parse(line))
        XCTAssertEqual(42, q.id)
        XCTAssertEqual(PacketType.share, q.type)
        XCTAssertEqual("a b.jpg", q.string("filename"))
        XCTAssertEqual(false, q.bool("open"))
        XCTAssertEqual(2, q.int("numberOfFiles"))
        XCTAssertEqual(1234, q.payloadSize)
        XCTAssertEqual(1740, q.payloadPort)
        XCTAssertTrue(q.hasPayload)
    }

    func testPacketWithoutPortHasNoPayload() throws {
        let line = try Packet(type: PacketType.ping, id: 1, payloadSize: 10).serialize()
        let s = String(data: line, encoding: .utf8)!
        XCTAssertFalse(s.contains("payloadSize"))
        XCTAssertFalse(try XCTUnwrap(Packet.parse(line)).hasPayload)
    }

    func testTunnelPayload() throws {
        let p = Packet(type: PacketType.share, id: 7, payloadSize: 99, payloadTunnel: "tok-1")
        let q = try XCTUnwrap(Packet.parse(try p.serialize()))
        XCTAssertEqual("tok-1", q.payloadTunnel)
        XCTAssertEqual(0, q.payloadPort)
        XCTAssertTrue(q.hasPayload)
    }

    func testParseAcceptsStringAndFloatId() {
        XCTAssertEqual(1_790_000_000_123, Packet.parse(#"{"id":"1790000000123","type":"kdeconnect.ping","body":{}}"#)?.id)
        XCTAssertEqual(1_727_260_000_000, Packet.parse(#"{"id":1727260000000.0,"type":"kdeconnect.ping"}"#)?.id)
        XCTAssertEqual(1_727_260_000_000, Packet.parse(#"{"id":1727260000000,"type":"kdeconnect.ping","body":{}}"#)?.id)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(Packet.parse("not json"))
        XCTAssertNil(Packet.parse(#"{"id":1,"body":{}}"#))
    }

    func testParseEnforcesMaxPacketSize() {
        let big = Data(repeating: 0x41, count: FluxProto.maxPacketSize + 16)
        XCTAssertNil(Packet.parse(big + Data([0x0A])))
    }

    func testIdentityPortOnlyInBroadcast() throws {
        let id = Identity.phone(deviceId: "0123456789abcdef0123456789abcdef", name: "Pixel", tcpPort: 1717)
        XCTAssertEqual(1717, try XCTUnwrap(Packet.parse(try id.toPacket(withPort: true).serialize())).int("tcpPort"))
        XCTAssertNil(try XCTUnwrap(Packet.parse(try id.toPacket().serialize())).int("tcpPort"))
        let target = Identity(deviceId: "fedcba9876543210fedcba9876543210", deviceName: "pc", deviceType: "laptop", protocolVersion: 8, incoming: [], outgoing: [])
        let tcp = try XCTUnwrap(Packet.parse(try id.toPacket(target: target).serialize()))
        XCTAssertEqual("fedcba9876543210fedcba9876543210", tcp.string("targetDeviceId"))
        XCTAssertEqual(8, tcp.int("targetProtocolVersion"))
        XCTAssertLessThan(try id.toPacket(withPort: true).serialize().count, FluxProto.maxIdentityLine)
    }

    func testIdentityParse() throws {
        let id = Identity.phone(deviceId: "0123456789abcdef0123456789abcdef", name: "Pixel", tcpPort: 1717)
        let line = try id.toPacket(withPort: true).serialize()
        let back = try XCTUnwrap(Identity.from(try XCTUnwrap(Packet.parse(line))))
        XCTAssertEqual(id.deviceId, back.deviceId)
        XCTAssertEqual("phone", back.deviceType)
        XCTAssertEqual(8, back.protocolVersion)
        XCTAssertEqual(incomingCapabilities, back.incoming)
        XCTAssertNil(Identity.from(Packet(type: PacketType.identity, body: ["deviceId": .string("short")])))
    }

    func testCleanNames() {
        XCTAssertEqual("Bobs phone", cleanName("Bob's phone!"))
        XCTAssertEqual("abc", cleanName("  a(b)c.  "))
        XCTAssertEqual(32, cleanName(String(repeating: "x", count: 40)).count)
        XCTAssertEqual("iPhone", cleanName("\"\"\""))
        XCTAssertEqual("Bobs Pixel 8", cleanName("Bob's \"Pixel\" (8)!"))
    }

    func testDeviceIds() {
        XCTAssertTrue(validDeviceId("0123456789abcdef0123456789abcdef"))
        XCTAssertTrue(validDeviceId("_0123456789abcdef_0123456789abcdef_"))
        XCTAssertFalse(validDeviceId("0123"))
        XCTAssertFalse(validDeviceId("0123456789abcdef0123456789abcde!"))
    }

    func testUnsignedByteOrder() {
        XCTAssertGreaterThan(Certificates.compareBytes(Data([0x80]), Data([0x7F])), 0)
        XCTAssertLessThan(Certificates.compareBytes(Data([1, 2]), Data([1, 2, 0])), 0)
        XCTAssertEqual(0, Certificates.compareBytes(Data([5]), Data([5])))
    }

    func testVerificationKeyVector() {
        // Expected values come from Python: sha256(larger + smaller + "1790000000").
        let a = Data([0x30, 0x82, 0x01, 0x22, 0x80])
        let b = Data([0x30, 0x82, 0x01, 0x22, 0x7F])
        XCTAssertEqual("5EE6825F", Certificates.verificationKey(own: a, peer: b, timestamp: 1_790_000_000))
        XCTAssertEqual("5EE6825F", Certificates.verificationKey(own: b, peer: a, timestamp: 1_790_000_000))
        XCTAssertEqual("5BB22DB1", Certificates.verificationKey(own: a, peer: b, timestamp: 0))
    }

    func testPairPackets() throws {
        let req = Pairing.request(timestamp: 1_790_000_000)
        XCTAssertEqual(PacketType.pair, req.type)
        XCTAssertEqual(true, req.bool("pair"))
        XCTAssertEqual(1_790_000_000, req.long("timestamp"))
        XCTAssertEqual(.request(timestamp: 1_790_000_000), Pairing.parse(req))

        XCTAssertEqual(.accept, Pairing.parse(Pairing.accept()))
        XCTAssertEqual(.reject, Pairing.parse(Pairing.reject()))

        // Round-trip over the wire.
        let back = try XCTUnwrap(Packet.parse(try req.serialize()))
        XCTAssertEqual(.request(timestamp: 1_790_000_000), Pairing.parse(back))

        // Non-numeric timestamp parses with nil stamp (refused on v8).
        let bad = Packet(type: PacketType.pair, body: ["pair": .bool(true), "timestamp": .string("soon")])
        XCTAssertEqual(.request(timestamp: nil), Pairing.parse(bad))
        XCTAssertNil(Pairing.parse(Packet(type: PacketType.ping, body: [:])))
    }

    func testPairTimestampRules() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        // v8: required, ±30 min.
        XCTAssertTrue(Pairing.validTimestamp(1_790_000_000, protocolVersion: 8, now: now))
        XCTAssertTrue(Pairing.validTimestamp(1_790_000_000 - 1800, protocolVersion: 8, now: now))
        XCTAssertTrue(Pairing.validTimestamp(1_790_000_000 + 1800, protocolVersion: 8, now: now))
        XCTAssertFalse(Pairing.validTimestamp(1_790_000_000 - 1801, protocolVersion: 8, now: now))
        XCTAssertFalse(Pairing.validTimestamp(1_790_000_000 + 1801, protocolVersion: 8, now: now))
        XCTAssertFalse(Pairing.validTimestamp(nil, protocolVersion: 8, now: now))
        // v7 and older: no timestamp needed.
        XCTAssertTrue(Pairing.validTimestamp(nil, protocolVersion: 7, now: now))
        // Key gating: v8 uses the stamp, older peers omit it.
        XCTAssertEqual(1_790_000_000, Pairing.keyTimestamp(pairTimestamp: 1_790_000_000, protocolVersion: 8))
        XCTAssertEqual(0, Pairing.keyTimestamp(pairTimestamp: 1_790_000_000, protocolVersion: 7))
    }

    func testPemRoundTrip() {
        let der = Data([0x30, 0x82, 0x01, 0x22, 0x80])
        let pem = Certificates.pemEncode(certificateDER: der)
        XCTAssertTrue(pem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        XCTAssertTrue(pem.hasSuffix("-----END CERTIFICATE-----\n"))
        XCTAssertEqual(der, Certificates.pemDecode(pem))
    }

    func testSpkiFromPoint() {
        var point = Data([0x04])
        point += Data(repeating: 0x11, count: 64)
        let spki = Certificates.spkiFromUncompressedPoint(point)
        XCTAssertNotNil(spki)
        XCTAssertEqual(26 + 65, spki?.count)
        XCTAssertTrue(spki?.prefix(2) == Data([0x30, 0x59]))
        XCTAssertNil(Certificates.spkiFromUncompressedPoint(Data(repeating: 0x04, count: 64)))
        XCTAssertNil(Certificates.spkiFromUncompressedPoint(Data(repeating: 0x05, count: 65)))
    }

    func testSpkiFromCertificateOsslFixture() throws {
        // P-256 self-signed cert minted by openssl (not by our issuer, and
        // with extensions ours never emits). Proves the SPKI walker is not
        // tuned to our own DER layout. Expected SPKI cross-checked with
        // `openssl x509 -pubkey | openssl pkey -outform DER`.
        let pem = """
        -----BEGIN CERTIFICATE-----
        MIIB8jCCAZmgAwIBAgIUa9MdCxHmEvscwx5yjtFfcfO91hYwCgYIKoZIzj0EAwIwTzEpMCcGA1UE
        Awwgc3BraXRlc3QwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1NjcxDDAKBgNVBAoMA0tERTEUMBIGA1UE
        CwwLS0RFIENvbm5lY3QwHhcNMjYwOTI2MTEzMjQzWhcNMjcwOTI2MTEzMjQzWjBPMSkwJwYDVQQD
        DCBzcGtpdGVzdDAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2NzEMMAoGA1UECgwDS0RFMRQwEgYDVQQL
        DAtLREUgQ29ubmVjdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABH4Qf+ztohXKHF3PFvR2ypp/
        a51DNuGLJq3svp6ulPoRMuXsY2zPHRvObV29L2JBvyPPVk9hf6AK2QPE7lKJuLSjUzBRMB0GA1Ud
        DgQWBBRGDmwlMnk37HjYzQkaeQ8uhrdU4DAfBgNVHSMEGDAWgBRGDmwlMnk37HjYzQkaeQ8uhrdU
        4DAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCICbO0gdbG+oc9yhU65ZCaU8NvlTH
        LrUiKOZ4svCK0XKsAiAtH2IAzjWZTWZTODufvjXeKNI6xUiOVCs7gyRQMsrSOA==
        -----END CERTIFICATE-----
        """
        let der = try XCTUnwrap(Certificates.pemDecode(pem))
        let spki = try XCTUnwrap(Certificates.spkiFromCertificate(der))
        XCTAssertEqual(91, spki.count)
        let expected = Data(base64Encoded: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfhB/7O2iFcocXc8W9HbKmn9rnUM24Ysmrey+nq6U+hEy5exjbM8dG85tXb0vYkG/I89WT2F/oArZA8TuUom4tA==")!
        XCTAssertEqual(expected, spki)
        // Malformed inputs refuse.
        XCTAssertNil(Certificates.spkiFromCertificate(Data([0x30, 0x03, 0x01, 0x02, 0x03])))
        XCTAssertNil(Certificates.spkiFromCertificate(der.prefix(der.count / 2)))
        XCTAssertNil(Certificates.spkiFromCertificate(Data()))
    }

    func testCommonName() throws {
        XCTAssertNil(Certificates.commonName(certificateDER: Data()))
        XCTAssertNil(Certificates.commonName(certificateDER: Data([0x30, 0x03, 0x01, 0x02, 0x03])))
        // openssl fixture (CN first attribute, PrintableString-able value).
        let ossl = try XCTUnwrap(Certificates.pemDecode("""
        -----BEGIN CERTIFICATE-----
        MIIB8jCCAZmgAwIBAgIUa9MdCxHmEvscwx5yjtFfcfO91hYwCgYIKoZIzj0EAwIwTzEpMCcGA1UE
        Awwgc3BraXRlc3QwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1NjcxDDAKBgNVBAoMA0tERTEUMBIGA1UE
        CwwLS0RFIENvbm5lY3QwHhcNMjYwOTI2MTEzMjQzWhcNMjcwOTI2MTEzMjQzWjBPMSkwJwYDVQQD
        DCBzcGtpdGVzdDAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2NzEMMAoGA1UECgwDS0RFMRQwEgYDVQQL
        DAtLREUgQ29ubmVjdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABH4Qf+ztohXKHF3PFvR2ypp/
        a51DNuGLJq3svp6ulPoRMuXsY2zPHRvObV29L2JBvyPPVk9hf6AK2QPE7lKJuLSjUzBRMB0GA1Ud
        DgQWBBRGDmwlMnk37HjYzQkaeQ8uhrdU4DAfBgNVHSMEGDAWgBRGDmwlMnk37HjYzQkaeQ8uhrdU
        4DAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCICbO0gdbG+oc9yhU65ZCaU8NvlTH
        LrUiKOZ4svCK0XKsAiAtH2IAzjWZTWZTODufvjXeKNI6xUiOVCs7gyRQMsrSOA==
        -----END CERTIFICATE-----
        """))
        XCTAssertEqual("spkitest0123456789abcdef01234567", Certificates.commonName(certificateDER: ossl))
    }
}
