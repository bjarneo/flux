import Foundation
#if canImport(Security)
import Security
#endif
import FluxProto

/// Self-signed device certificate issuance.
///
/// Profile mirrors Go `generateCert` in `internal/proto/cert.go`:
/// EC P-256, serial 10, `CN = device ID`, `O = KDE`, `OU = KDE Connect`,
/// validity −1y/+10y, signature algorithm ECDSA-with-SHA512. No extensions
/// (like Go; unlike older Android RSA builds which add BasicConstraints).
/// The desktop checks `CN == device ID` and pins the exact DER bytes, so
/// this builder must stay wire-compatible — verified against Go
/// `x509.ParseCertificate` and `openssl x509` (see M1 notes in
/// `ios/README.md`).
///
/// The TBS bytes are pure Swift (`tbsCertificate`) and unit-tested for
/// structure. Signing goes through `SecKey` (Secure Enclave or Keychain)
/// with `.ecdsaSignatureMessageX962SHA512`, which takes the message and
/// hashes internally — the same bytes Go signs.
public enum SelfSignedCertificate {
    /// Certificate profile (all pure data, no Security dependency).
    public struct Profile: Sendable, Equatable {
        public var deviceId: String
        public var organization = "KDE"
        public var unit = "KDE Connect"
        public var serial: UInt = 10

        public init(deviceId: String) { self.deviceId = deviceId }
    }

    public enum IssueError: Error, Equatable {
        case invalidDeviceId
        case signingFailed
    }

    // MARK: - Pure DER builder

    /// Builds the TBSCertificate bytes for the profile + SPKI.
    public static func tbsCertificate(profile: Profile, spki: Data, now: Date = Date()) -> Data {
        let cal = Calendar(identifier: .gregorian)
        let notBefore = cal.date(byAdding: .year, value: -1, to: now) ?? now
        let notAfter = cal.date(byAdding: .year, value: 10, to: now) ?? now
        var tbs = Data()
        tbs += derInteger(UInt64(profile.serial))
        tbs += ecdsaSHA512AlgId()
        tbs += name(profile: profile)
        tbs += derSequence(derUTCTime(notBefore) + derUTCTime(notAfter))
        tbs += name(profile: profile)
        tbs += spki
        return derSequence(tbs)
    }

    /// Issues a certificate with an injected signer. The signer receives the
    /// TBS bytes and returns a DER-encoded ECDSA signature
    /// (`SEQ { INTEGER r, INTEGER s }`, the `X962` output format of
    /// `SecKeyCreateSignature`). The components are re-encoded canonically.
    /// Throws `invalidDeviceId` unless the ID has the KDE Connect format.
    public static func issue(
        profile: Profile,
        spki: Data,
        now: Date = Date(),
        sign: (Data) throws -> Data
    ) throws -> Data {
        guard validDeviceId(profile.deviceId) else { throw IssueError.invalidDeviceId }
        let tbs = tbsCertificate(profile: profile, spki: spki, now: now)
        let der: Data
        do { der = try sign(tbs) } catch { throw IssueError.signingFailed }
        guard let (r, s) = rawSignatureComponents(der) else { throw IssueError.signingFailed }
        let sig = derSequence(derInteger(r) + derInteger(s))
        var cert = Data()
        cert += tbs
        cert += ecdsaSHA512AlgId()
        cert += derBitString(sig)
        return derSequence(cert)
    }

    // MARK: - DER primitives (internal for golden tests)

    static func derLength(_ n: Int) -> Data {
        if n < 128 { return Data([UInt8(n)]) }
        var v = n, bytes: [UInt8] = []
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }

    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + derLength(content.count) + content
    }

    static func derSequence(_ content: Data) -> Data { tlv(0x30, content) }
    static func derSet(_ content: Data) -> Data { tlv(0x31, content) }

    static func derInteger(_ v: UInt64) -> Data {
        var bytes: [UInt8] = []
        var x = v
        repeat { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 } while x > 0
        return derInteger(Data(bytes))
    }

    static func derInteger(_ bytes: Data) -> Data {
        var b = bytes
        while b.count > 1, b.first == 0x00, b.dropFirst().first.map({ $0 & 0x80 == 0 }) ?? false {
            b.removeFirst()
        }
        if let first = b.first, first & 0x80 != 0 { b.insert(0x00, at: 0) }
        return tlv(0x02, b)
    }

    /// `1.2.840.10045.4.3.4` (ecdsa-with-SHA512), no parameters (like Go).
    static func ecdsaSHA512AlgId() -> Data {
        derSequence(Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04]))
    }

    static func attribute(oid: Data, value: String) -> Data {
        let ava = tlv(0x06, oid) + tlv(0x0C, Data(value.utf8))
        return derSet(derSequence(ava))
    }

    static func name(profile: Profile) -> Data {
        derSequence(
            attribute(oid: Data([0x55, 0x04, 0x03]), value: profile.deviceId) +
            attribute(oid: Data([0x55, 0x04, 0x0A]), value: profile.organization) +
            attribute(oid: Data([0x55, 0x04, 0x0B]), value: profile.unit)
        )
    }

    static func derUTCTime(_ date: Date) -> Data {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let s = String(format: "%02d%02d%02d%02d%02d%02dZ",
                       (c.year ?? 2000) % 100, c.month ?? 1, c.day ?? 1,
                       c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return tlv(0x17, Data(s.utf8))
    }

    static func derBitString(_ content: Data) -> Data {
        tlv(0x03, Data([0x00]) + content)
    }

    /// Parses a DER ECDSA signature (`SEQ { INTEGER r, INTEGER s }`, the
    /// `X962` output of `SecKeyCreateSignature`) into fixed 32-byte
    /// big-endian components. Returns nil for malformed input.
    static func rawSignatureComponents(_ der: Data) -> (r: Data, s: Data)? {
        let b = Array(der)
        guard b.count >= 8, b[0] == 0x30 else { return nil }
        var i = 1
        guard let (outer, outerLen) = readLength(b, i) else { return nil }
        i += outerLen
        guard b.count - i == outer else { return nil }
        guard b[i] == 0x02, let (rlen, rnlen) = readLength(b, i + 1) else { return nil }
        let r = Array(b[(i + 1 + rnlen)..<(i + 1 + rnlen + rlen)])
        i += 1 + rnlen + rlen
        guard i < b.count, b[i] == 0x02, let (slen, snlen) = readLength(b, i + 1) else { return nil }
        let s = Array(b[(i + 1 + snlen)..<(i + 1 + snlen + slen)])
        guard i + 1 + snlen + slen == b.count else { return nil }
        guard let nr = normalized32(r), let ns = normalized32(s) else { return nil }
        return (Data(nr), Data(ns))
    }

    private static func normalized32(_ v: [UInt8]) -> [UInt8]? {
        var x = v
        while x.count > 1, x[0] == 0x00 { x.removeFirst() }
        guard x.count <= 32 else { return nil }
        return Array(repeating: 0, count: 32 - x.count) + x
    }

    private static func readLength(_ b: [UInt8], _ i: Int) -> (Int, Int)? {
        guard i < b.count else { return nil }
        let first = b[i]
        if first < 0x80 { return (Int(first), 1) }
        let n = Int(first & 0x7F)
        guard n >= 1, n <= 4, i + n < b.count else { return nil }
        var v = 0
        for j in 1...n { v = (v << 8) | Int(b[i + j]) }
        return (v, 1 + n)
    }

    // MARK: - Live SecKey issuance

#if canImport(Security)
    /// Issues a certificate for the P-256 `key`, deriving the SPKI from the
    /// public key's uncompressed point. Works with Secure Enclave keys (the
    /// private bytes never leave the Enclave; signing happens inside it).
    public static func issue(key: SecKey, deviceId: String, now: Date = Date()) throws -> Data {
        guard validDeviceId(deviceId) else { throw IssueError.invalidDeviceId }
        guard let pub = SecKeyCopyPublicKey(key) else { throw IssueError.signingFailed }
        var error: Unmanaged<CFError>?
        guard let rep = SecKeyCopyExternalRepresentation(pub, &error) as Data?,
              rep.count == 65,
              let spki = Certificates.spkiFromUncompressedPoint(rep)
        else { throw IssueError.signingFailed }
        return try issue(profile: Profile(deviceId: deviceId), spki: spki, now: now) { tbs in
            var signError: Unmanaged<CFError>?
            // X962 output: DER SEQ { INTEGER r, INTEGER s }.
            guard let sig = SecKeyCreateSignature(
                key, .ecdsaSignatureMessageX962SHA512, tbs as CFData, &signError
            ) as Data? else { throw IssueError.signingFailed }
            return sig
        }
    }

    /// Verifies a DER-encoded ECDSA/SHA-512 signature over `message`.
    public static func verifySignature(publicKey: SecKey, message: Data, derSignature: Data) -> Bool {
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(
            publicKey, .ecdsaSignatureMessageX962SHA512, message as CFData,
            derSignature as CFData, &error
        )
    }
#endif
}
