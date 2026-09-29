import XCTest
import Foundation
@testable import FluxCore
@testable import FluxProto

/// Certificate issuance. The profile mirrors Go `generateCert`
/// (`internal/proto/cert.go`): P-256, serial 10, `CN=device ID`, `O=KDE`,
/// `OU=KDE Connect`, −1y/+10y, ECDSA-with-SHA512, no extensions.
final class CertIssuanceTests: XCTestCase {
    private let deviceId = "0123456789abcdef0123456789abcdef"
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private var point: Data {
        Data([0x04]) + Data(repeating: 0x11, count: 64)
    }

    private func spki() throws -> Data {
        try XCTUnwrap(Certificates.spkiFromUncompressedPoint(point))
    }

    /// Deterministic DER ECDSA signature for structural tests.
    private func fakeSignature() -> Data {
        SelfSignedCertificate.derSequence(
            SelfSignedCertificate.derInteger(Data(repeating: 0x01, count: 32)) +
            SelfSignedCertificate.derInteger(Data(repeating: 0x80, count: 32))
        )
    }

    func testIssueStructure() throws {
        let spki = try spki()
        let cert = try SelfSignedCertificate.issue(
            profile: SelfSignedCertificate.Profile(deviceId: deviceId),
            spki: spki,
            now: now,
            sign: { _ in self.fakeSignature() }
        )
        // Outer + TBS are SEQUENCEs.
        XCTAssertEqual(0x30, cert.first)
        // Serial 10.
        XCTAssertTrue(cert.contains(Data([0x02, 0x01, 0x0A])))
        // ecdsa-with-SHA512 OID 1.2.840.10045.4.3.4 appears twice (TBS + outer).
        let oid = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04])
        XCTAssertEqual(2, cert.components(countOf: oid))
        // Subject fields.
        XCTAssertTrue(cert.contains(Data(deviceId.utf8)))
        XCTAssertTrue(cert.contains(Data("KDE Connect".utf8)))
        // SPKI is embedded and extractable (what verificationKey hashes).
        XCTAssertTrue(cert.contains(spki))
        XCTAssertEqual(spki, Certificates.spkiFromCertificate(cert))
        // UTCTime validity markers.
        XCTAssertTrue(cert.contains(Data([0x17, 0x0D])))
    }

    func testIssueRefusesBadDeviceId() throws {
        let spki = try spki()
        XCTAssertThrowsError(try SelfSignedCertificate.issue(
            profile: SelfSignedCertificate.Profile(deviceId: "short"),
            spki: spki,
            now: now,
            sign: { _ in self.fakeSignature() }
        ))
        XCTAssertThrowsError(try SelfSignedCertificate.issue(
            profile: SelfSignedCertificate.Profile(deviceId: deviceId),
            spki: spki,
            now: now,
            sign: { _ in Data([0x30, 0x00]) } // malformed signature
        ))
    }

    func testSignatureComponents() {
        // High-bit components round-trip through DER padding.
        let (r, s) = SelfSignedCertificate.rawSignatureComponents(fakeSignature())!
        XCTAssertEqual(Data(repeating: 0x01, count: 32), r)
        XCTAssertEqual(Data(repeating: 0x80, count: 32), s)
        XCTAssertNil(SelfSignedCertificate.rawSignatureComponents(Data([0x30, 0x00])))
        XCTAssertNil(SelfSignedCertificate.rawSignatureComponents(Data(repeating: 0x01, count: 70)))
        // Oversized integer is refused.
        let big = SelfSignedCertificate.derSequence(
            SelfSignedCertificate.derInteger(Data(repeating: 0x01, count: 33)) +
            SelfSignedCertificate.derInteger(Data(repeating: 0x02, count: 32)))
        XCTAssertNil(SelfSignedCertificate.rawSignatureComponents(big))
    }

    func testDerLengthEncoding() {
        XCTAssertEqual(Data([0x05]), SelfSignedCertificate.derLength(5))
        XCTAssertEqual(Data([0x81, 0x80]), SelfSignedCertificate.derLength(128))
        XCTAssertEqual(Data([0x82, 0x01, 0x00]), SelfSignedCertificate.derLength(256))
    }

#if canImport(Security)
    func testLiveIssueRoundTrip() throws {
        // Ephemeral P-256 key (never touches the Keychain).
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false,
        ]
        var error: Unmanaged<CFError>?
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, &error) as SecKey?)
        let cert = try SelfSignedCertificate.issue(key: key, deviceId: deviceId, now: now)

        // The OS parses it as a certificate …
        let secCert = try XCTUnwrap(SecCertificateCreateWithData(nil, cert as CFData))
        XCTAssertNotNil(secCert)
        // … and the CN attribute (`OID 2.5.4.3`, UTF8String) holds the device ID.
        var cnAttr = Data([0x06, 0x03, 0x55, 0x04, 0x03, 0x0C, UInt8(deviceId.utf8.count)])
        cnAttr += Data(deviceId.utf8)
        XCTAssertNotNil(cert.range(of: cnAttr))
        // The pure-DER parser (iOS path) agrees.
        XCTAssertEqual(deviceId, Certificates.commonName(certificateDER: cert))

        // The embedded signature verifies against the recomputed TBS.
        let pub = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let rep = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, nil) as Data?)
        let spki = try XCTUnwrap(Certificates.spkiFromUncompressedPoint(rep))
        let tbs = SelfSignedCertificate.tbsCertificate(
            profile: SelfSignedCertificate.Profile(deviceId: deviceId), spki: spki, now: now)
        var signError: Unmanaged<CFError>?
        let derSig = try XCTUnwrap(SecKeyCreateSignature(
            key, .ecdsaSignatureMessageX962SHA512, tbs as CFData, &signError) as Data?)
        XCTAssertNotNil(SelfSignedCertificate.rawSignatureComponents(derSig))
        XCTAssertTrue(SelfSignedCertificate.verifySignature(publicKey: pub, message: tbs, derSignature: derSig))
        XCTAssertFalse(SelfSignedCertificate.verifySignature(
            publicKey: pub, message: Data("other".utf8), derSignature: derSig))

        // Dump for external interop checks (Go x509 + openssl, see README).
        if let path = ProcessInfo.processInfo.environment["FLUX_DUMP_CERT"] {
            try cert.write(to: URL(fileURLWithPath: path))
        }
    }
#endif
}

private extension Data {
    /// Counts non-overlapping occurrences of `needle`.
    func components(countOf needle: Data) -> Int {
        guard !needle.isEmpty, count >= needle.count else { return 0 }
        var n = 0
        var i = startIndex
        while let r = self[i...].range(of: needle) {
            n += 1
            i = r.upperBound
            if i == endIndex { break }
        }
        return n
    }

    func contains(_ needle: Data) -> Bool {
        range(of: needle) != nil
    }
}
