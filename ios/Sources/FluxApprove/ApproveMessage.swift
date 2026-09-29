import Foundation

/// Approval message bytes. Must match `docs/approve.md` and
/// `internal/approve/message.go` byte-for-byte, plus Android
/// `core/ApproveMessage.kt` vectors.
///
/// - Approval message: 8 lines, each `\n`-terminated.
/// - Enrollment message: 7 lines.
/// - Field rules: UTF-8, ≤256 bytes, no control chars,
///   `host`/`user`/`service` non-empty, `nonce` 64 lowercase hex.
/// - Phone refuses requests with clock skew >10 min.
public enum ApproveMessage {
    public static let approveVersion = "flux-approve-v1"
    public static let enrollVersion = "flux-approve-enroll-v1"
    /// Phone-side freshness window (10 minutes, matches Android `fresh`).
    public static let freshnessWindow: Int64 = 600
    public static let maxFieldBytes = 256

    public static let testNonce = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    // MARK: - Message construction

    public static func approval(host: String, user: String, service: String, tty: String, rhost: String, time: Int64, nonce: String) throws -> Data {
        try checkFields(["host": host, "user": user, "service": service], required: true)
        try checkFields(["tty": tty, "rhost": rhost], required: false)
        try checkNonce(nonce)
        return Data(
            "\(approveVersion)\nhost=\(host)\nuser=\(user)\nservice=\(service)\ntty=\(tty)\nrhost=\(rhost)\ntime=\(time)\nnonce=\(nonce)\n".utf8
        )
    }

    public static func enrollment(host: String, user: String, spki: Data, time: Int64, nonce: String) throws -> Data {
        try checkFields(["host": host, "user": user], required: true)
        try checkNonce(nonce)
        let keyHex = sha256Hex(spki)
        return Data(
            "\(enrollVersion)\nhost=\(host)\nuser=\(user)\nkey=\(keyHex)\ntime=\(time)\nnonce=\(nonce)\n".utf8
        )
    }

    /// Key code shown on both screens: first 8 bytes of SHA-256 of the key
    /// in DER, as 4 groups of 4 uppercase hex digits.
    /// Vector: `fingerprint("test-key") == "62AF 8704 764F AF8E"`.
    public static func fingerprint(_ spki: Data) -> String {
        let hex = sha256Hex(spki).uppercased()
        let p = String(hex.prefix(16))
        return "\(p.prefix(4)) \(p.dropFirst(4).prefix(4)) \(p.dropFirst(8).prefix(4)) \(p.dropFirst(12).prefix(4))"
    }

    // MARK: - Validation

    public static func validField(_ v: String) -> Bool {
        guard v.utf8.count <= maxFieldBytes else { return false }
        for scalar in v.unicodeScalars {
            let r = scalar.value
            if r < 0x20 || r == 0x7F || (r >= 0x80 && r < 0xA0) { return false }
        }
        // Reject lone surrogates / non-scalars that String would still hold.
        if v.contains("\u{FFFD}") && !v.unicodeScalars.contains("\u{FFFD}") { return false }
        return true
    }

    public static func validNonce(_ n: String) -> Bool {
        guard n.count == 64 else { return false }
        return n.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }
    }

    /// Phone-side freshness: `abs(now - signedTime) <= 600 s`.
    public static func fresh(signedTime: Int64, now: Int64) -> Bool {
        abs(now - signedTime) <= freshnessWindow
    }

    // MARK: - Internal

    public enum ValidationError: Error, Equatable {
        case emptyField(String)
        case badField(String)
        case badNonce
    }

    static func checkFields(_ fields: [String: String], required: Bool) throws {
        for (name, v) in fields {
            if required, v.isEmpty { throw ValidationError.emptyField(name) }
            if !validField(v) { throw ValidationError.badField(name) }
        }
    }

    static func checkNonce(_ n: String) throws {
        if !validNonce(n) { throw ValidationError.badNonce }
    }

    static func sha256Hex(_ data: Data) -> String {
        // Pure-Swift SHA-256 so FluxApprove stays dependency-free and
        // testable on Linux CI. Matches Go crypto/sha256.
        var h = SHA256State()
        h.update(data)
        return h.finalizeHex()
    }
}

// MARK: - Minimal SHA-256 (no CryptoKit dependency for Linux CI)

private struct SHA256State {
    private var h: [UInt32] = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
    private var buffer = Data()
    private var total = 0

    mutating func update(_ data: Data) {
        buffer.append(data)
        total += data.count
        while buffer.count >= 64 {
            compress(Data(buffer.prefix(64)))
            buffer.removeFirst(64)
        }
    }

    func finalizeHex() -> String {
        var copy = self
        return copy.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private mutating func finalize() -> Data {
        let bitLen = UInt64(total) * 8
        update(Data([0x80]))
        while buffer.count % 64 != 56 { update(Data([0x00])) }
        var len = bitLen.bigEndian
        update(Data(bytes: &len, count: 8))
        var out = Data()
        for v in h {
            var be = v.bigEndian
            out.append(Data(bytes: &be, count: 4))
        }
        return out
    }

    private mutating func compress(_ block: Data) {
        let k: [UInt32] = [
            0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
            0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
            0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
            0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
            0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
            0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
            0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
            0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
        ]
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = UInt32(block[block.startIndex + i * 4]) << 24
                | UInt32(block[block.startIndex + i * 4 + 1]) << 16
                | UInt32(block[block.startIndex + i * 4 + 2]) << 8
                | UInt32(block[block.startIndex + i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = rot(w[i-15], 7) ^ rot(w[i-15], 18) ^ (w[i-15] >> 3)
            let s1 = rot(w[i-2], 17) ^ rot(w[i-2], 19) ^ (w[i-2] >> 10)
            w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
        }
        var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
        for i in 0..<64 {
            let s1 = rot(e, 6) ^ rot(e, 11) ^ rot(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rot(a, 2) ^ rot(a, 13) ^ rot(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
        h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }

    private func rot(_ v: UInt32, _ n: UInt32) -> UInt32 { (v >> n) | (v << (32 - n)) }
}
