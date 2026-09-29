import Foundation
import FluxProto
import FluxCamera

/// Deterministic stream fixtures. The golden NAL units are byte-identical
/// to Android `WebcamTest` (`sps`/`pps`/`idr`/`pframe`); the builders run
/// them through the real `AnnexBFramer`, so harness bytes exercise the
/// same framing the camera and the mirror use.

public enum StreamFixtures {
    /// Golden codec config: SPS + PPS with 4-byte start codes.
    public static let sps = Data([0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1F])
    public static let pps = Data([0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80])

    /// Golden frames: an IDR and a P frame with 4-byte start codes.
    public static let idr = Data([0, 0, 0, 1, 0x65, 0x11, 0x22])
    public static let pframe = Data([0, 0, 0, 1, 0x41, 0x33, 0x44])

    /// Builds a deterministic Annex-B webcam/screen stream: config once,
    /// then `idrCount` IDRs each followed by `pPerIdr` P frames, all
    /// through `AnnexBFramer` (SPS/PPS land before every IDR).
    public static func videoStream(idrCount: Int = 8, pPerIdr: Int = 7) -> Data {
        let framer = AnnexBFramer()
        framer.onConfig(sps + pps)
        var out = Data()
        for _ in 0 ..< idrCount {
            if let idr = framer.onFrame(idr, keyFrame: true) { out += idr }
            for _ in 0 ..< pPerIdr {
                if let p = framer.onFrame(pframe, keyFrame: false) { out += p }
            }
        }
        return out
    }

    /// Builds deterministic mic bytes: one second of 440 Hz sine s16le mono.
    public static func micStream(seconds: Double = 1) -> Data {
        Pcm.sine(seconds: seconds, rate: MicPackets.rate, freq: 440)
    }

    /// Lowercase hex SHA-256 (log comparison both sides of a stream).
    /// Small pure-Swift digest so fixtures stay dependency-free (CryptoKit
    /// does the same in the app/peer; vectors cross-check).
    public static func sha256Hex(_ data: Data) -> String {
        SHA256Digest.hex(of: data)
    }
}

/// Minimal pure-Swift SHA-256 (test-fixture scope; the app uses CryptoKit).
enum SHA256Digest {
    static func hex(of data: Data) -> String {
        hash(data).map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ data: Data) -> [UInt8] {
        var msg = Array(data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0 ..< 8).reversed() { msg.append(UInt8((bitLen >> (i * 8)) & 0xFF)) }
        var h: [UInt32] = [
            0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
            0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
        ]
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
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0 ..< 16 {
                w[i] = UInt32(msg[chunk + i * 4]) << 24 | UInt32(msg[chunk + i * 4 + 1]) << 16
                    | UInt32(msg[chunk + i * 4 + 2]) << 8 | UInt32(msg[chunk + i * 4 + 3])
            }
            for i in 16 ..< 64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0 ..< 64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { w in [UInt8((w >> 24) & 0xFF), UInt8((w >> 16) & 0xFF), UInt8((w >> 8) & 0xFF), UInt8(w & 0xFF)] }
    }
}
