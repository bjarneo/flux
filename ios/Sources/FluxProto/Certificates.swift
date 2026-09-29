import CryptoKit
import Foundation

/// Certificate helpers. Mirrors `internal/proto/cert.go` (ECDSA P-256,
/// CN = device ID, `O=KDE`, `OU=KDE Connect`) and Android
/// `protocol/Certificates.kt` verification-key math.
///
/// The desktop generates a self-signed ECDSA P-256 certificate; older
/// Android builds used RSA-2048. The verification key only needs the two
/// SubjectPublicKeyInfo blobs, so it is algorithm-agnostic: iOS must produce
/// **byte-identical** codes or pairing UX breaks.
///
/// Key storage (see `FluxCore/TrustStore.swift`): private key in the Secure
/// Enclave when available (`kSecAttrTokenIDSecureEnclave`), else Keychain.
/// Certificate DER is pinned by the desktop in `devices.json`.
public enum Certificates {
    /// Compares bytes as unsigned values, the same way Go `bytes.Compare` does.
    public static func compareBytes(_ a: Data, _ b: Data) -> Int {
        let n = min(a.count, b.count)
        for i in 0..<n {
            let x = Int(a[a.startIndex.advanced(by: i)])
            let y = Int(b[b.startIndex.advanced(by: i)])
            if x != y { return x - y }
        }
        return a.count - b.count
    }

    /// Returns the 8-character key both devices show while pairing. It hashes
    /// the two public keys (larger first) and the pairing timestamp in
    /// seconds as decimal text. `timestamp <= 0` omits the timestamp.
    ///
    /// Test vector (shared with Android `ProtocolTest` and Go `proto_test`):
    /// `a = [0x30,0x82,0x01,0x22,0x80]`, `b = [0x30,0x82,0x01,0x22,0x7F]`,
    /// `verificationKey(a,b,1790000000) == "5EE6825F"`.
    public static func verificationKey(own: Data, peer: Data, timestamp: Int64) -> String {
        var a = own
        var b = peer
        if compareBytes(a, b) < 0 { swap(&a, &b) }
        var h = SHA256()
        h.update(data: a)
        h.update(data: b)
        if timestamp > 0 { h.update(data: Data(String(timestamp).utf8)) }
        let digest = h.finalize()
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined().uppercased()
    }

    /// Encodes a DER certificate as PEM (mirrors Go `CertPEM`). The desktop
    /// pins this text in `devices.json`; it is also what `test_peer.py`
    /// prints for manual comparison.
    public static func pemEncode(certificateDER: Data) -> String {
        // Chunk manually: base64EncodedString line-length options do not
        // terminate short output, which would fuse the last line with the
        // END marker.
        let b64 = certificateDER.base64EncodedString()
        var out = "-----BEGIN CERTIFICATE-----\n"
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            out += b64[i..<j] + "\n"
            i = j
        }
        out += "-----END CERTIFICATE-----\n"
        return out
    }

    /// Decodes a PEM certificate to DER (mirrors Go `ParseCertPEM`).
    public static func pemDecode(_ pem: String) -> Data? {
        let lines = pem.components(separatedBy: .newlines).filter {
            !$0.hasPrefix("-----") && !$0.isEmpty
        }
        return Data(base64Encoded: lines.joined())
    }

    /// SubjectPublicKeyInfo DER prefix for P-256/ECDSA-SHA256. Prepend to the
    /// 65-byte uncompressed point (`0x04 || X || Y`) to form the SPKI blob
    /// that `verificationKey` hashes.
    public static let spkiPrefixP256 = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
        0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
        0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00,
    ])

    /// Wraps a raw 65-byte uncompressed P-256 point in its SPKI DER header.
    /// Returns nil when the point is not 65 bytes starting with `0x04`.
    public static func spkiFromUncompressedPoint(_ point: Data) -> Data? {
        guard point.count == 65, point.first == 0x04 else { return nil }
        return spkiPrefixP256 + point
    }

    /// Extracts the SubjectPublicKeyInfo bytes from a DER certificate.
    /// The SPKI is the TBS child that is a SEQUENCE starting with a
    /// SEQUENCE starting with an OID (the algorithm identifier) — robust
    /// across EC/RSA keys and attribute orders. Returns nil for malformed
    /// input. The returned range aliases the input (no copy).
    public static func spkiFromCertificate(_ der: Data) -> Data? {
        guard let outer = TLV.read(der, at: 0), outer.tag == 0x30,
              let tbs = TLV.read(der, at: outer.headerLength),
              tbs.tag == 0x30
        else { return nil }
        var i = outer.headerLength + tbs.headerLength
        let tbsEnd = i + tbs.length
        while i < tbsEnd {
            guard let child = TLV.read(der, at: i) else { return nil }
            if child.tag == 0x30,
               let alg = TLV.read(der, at: i + child.headerLength),
               alg.tag == 0x30,
               let oid = TLV.read(der, at: i + child.headerLength + alg.headerLength),
               oid.tag == 0x06
            {
                return Data(der[i..<(i + child.totalLength)])
            }
            i += child.totalLength
        }
        return nil
    }

    /// Returns the subject common name (OID 2.5.4.3) of a DER certificate,
    /// or nil. Pure DER parsing: `SecCertificateCopyValues` is macOS-only,
    /// so iOS uses this instead (same result on both).
    ///
    /// The subject is the last TBS child that is a SEQUENCE of SETs (issuer
    /// and subject are the only Names; validity holds UTCTimes and the SPKI
    /// starts with a nested SEQUENCE, so neither collides). Each SET holds
    /// `SEQ { OID, value }`; the CN attribute's value may be UTF8String,
    /// PrintableString, TeletexString, or BMPString.
    public static func commonName(certificateDER der: Data) -> String? {
        guard let outer = TLV.read(der, at: 0), outer.tag == 0x30,
              let tbs = TLV.read(der, at: outer.headerLength), tbs.tag == 0x30
        else { return nil }
        var i = outer.headerLength + tbs.headerLength
        let tbsEnd = i + tbs.length
        var subject: TLV?
        while i < tbsEnd {
            guard let child = TLV.read(der, at: i) else { return nil }
            if child.tag == 0x30, isName(der, child) {
                subject = child
            }
            i += child.totalLength
        }
        guard let subject else { return nil }
        var j = subject.valueOffset
        while j < subject.valueOffset + subject.length {
            guard let set = TLV.read(der, at: j), set.tag == 0x31,
                  let ava = TLV.read(der, at: set.valueOffset), ava.tag == 0x30,
                  let oid = TLV.read(der, at: ava.valueOffset), oid.tag == 0x06
            else { return nil }
            if oidContentsEqual(der, oid, bytes: [0x55, 0x04, 0x03]),
               let value = TLV.read(der, at: ava.valueOffset + oid.totalLength),
               let s = derString(der, value)
            {
                return s
            }
            j += set.totalLength
        }
        return nil
    }

    private static func isName(_ der: Data, _ seq: TLV) -> Bool {
        var k = seq.valueOffset
        let end = k + seq.length
        if k >= end { return false }
        while k < end {
            guard let c = TLV.read(der, at: k), c.tag == 0x31 else { return false }
            k += c.totalLength
        }
        return true
    }

    private static func oidContentsEqual(_ der: Data, _ oid: TLV, bytes: [UInt8]) -> Bool {
        guard oid.length == bytes.count else { return false }
        let start = der.startIndex + oid.valueOffset
        return der[start..<(start + oid.length)].elementsEqual(bytes)
    }

    private static func derString(_ der: Data, _ value: TLV) -> String? {
        let start = der.startIndex + value.valueOffset
        let bytes = der[start..<(start + value.length)]
        switch value.tag {
        case 0x0C, 0x13, 0x14: // UTF8String, PrintableString, TeletexString
            return String(bytes: bytes, encoding: .utf8)
        case 0x1E: // BMPString (UTF-16BE)
            guard value.length > 0, value.length % 2 == 0 else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(value.length / 2)
            for k in stride(from: 0, to: value.length, by: 2) {
                units.append(UInt16(bytes[bytes.startIndex + k]) << 8 | UInt16(bytes[bytes.startIndex + k + 1]))
            }
            let s = String(decoding: units, as: UTF16.self)
            return s.isEmpty ? nil : s
        default:
            return nil
        }
    }

    /// Minimal DER TLV reader (for `spkiFromCertificate`).
    struct TLV {
        var tag: UInt8
        var length: Int
        var headerLength: Int
        var totalLength: Int
        /// Absolute offset of the content's first byte.
        var valueOffset: Int

        static func read(_ data: Data, at: Int) -> TLV? {
            guard at + 2 <= data.count else { return nil }
            let tag = data[data.startIndex + at]
            let first = data[data.startIndex + at + 1]
            var length = 0
            var header = 2
            if first < 0x80 {
                length = Int(first)
            } else {
                let n = Int(first & 0x7F)
                guard n >= 1, n <= 4, at + 2 + n <= data.count else { return nil }
                for j in 0..<n { length = (length << 8) | Int(data[data.startIndex + at + 2 + j]) }
                header = 2 + n
            }
            guard length >= 0, at + header + length <= data.count else { return nil }
            return TLV(tag: tag, length: length, headerLength: header,
                       totalLength: header + length, valueOffset: at + header)
        }
    }
}
