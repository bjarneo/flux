import Foundation

/// Helpers for H.264 in Annex-B form: NAL units that start with 00 00 01 or
/// 00 00 00 01. The computer reads the stream in this form.
enum AnnexB {
    static let nalIDR: UInt8 = 5
    static let nalSPS: UInt8 = 7
    static let nalPPS: UInt8 = 8

    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Returns the offsets of the first byte after each start code in b.
    static func nalStarts(_ b: [UInt8]) -> [Int] {
        var out: [Int] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                out.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        return out
    }

    /// Returns the NAL unit types in b, in order.
    static func nalTypes(_ b: [UInt8]) -> [UInt8] {
        nalStarts(b).filter { $0 < b.count }.map { b[$0] & 0x1F }
    }

    static func hasStartCode(_ b: [UInt8]) -> Bool {
        (b.count >= 3 && b[0] == 0 && b[1] == 0 && b[2] == 1) ||
            (b.count >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 1)
    }

    /// Returns b with a 4-byte start code in front, when it has none.
    static func withStartCode(_ b: [UInt8]) -> [UInt8] {
        hasStartCode(b) ? b : startCode + b
    }

    /// Turns NAL units with a big-endian length in front, as VideoToolbox
    /// writes them, into Annex-B form. headerLength is the size of each
    /// length field. With 4-byte lengths the bytes change in place. It
    /// returns false when a length runs past the end.
    static func convertLengthPrefixed(_ b: inout [UInt8], headerLength: Int) -> Bool {
        guard (1...4).contains(headerLength) else { return false }
        var units: [Range<Int>] = []
        var i = 0
        while i < b.count {
            guard i + headerLength <= b.count else { return false }
            var length = 0
            for k in 0..<headerLength { length = length << 8 | Int(b[i + k]) }
            let start = i + headerLength
            guard length <= b.count - start else { return false }
            units.append(start..<start + length)
            i = start + length
        }
        if headerLength == 4 {
            for unit in units { b.replaceSubrange(unit.lowerBound - 4..<unit.lowerBound, with: startCode) }
            return true
        }
        var out: [UInt8] = []
        out.reserveCapacity(b.count + units.count * (4 - headerLength))
        for unit in units {
            out += startCode
            out += b[unit]
        }
        b = out
        return true
    }
}

/// Turns encoder output into a stream that a decoder can join at any IDR
/// frame. The encoder gives SPS and PPS as codec config. The framer keeps
/// them and writes them in front of each IDR frame that lacks them.
struct AnnexBFramer {
    private var config: [UInt8]?
    private var started = false

    /// Stores codec config. It returns no bytes, because the config goes out
    /// with the next IDR frame.
    mutating func onConfig(_ data: [UInt8]) {
        config = AnnexB.withStartCode(data)
    }

    /// Returns the bytes to write for 1 encoded frame. It returns nil for a
    /// frame that a decoder cannot use yet: a frame before the first IDR frame.
    mutating func onFrame(_ data: [UInt8], keyFrame: Bool) -> [UInt8]? {
        let frame = AnnexB.withStartCode(data)
        let types = AnnexB.nalTypes(frame)
        let isIDR = keyFrame || types.contains(AnnexB.nalIDR)
        if !isIDR && !started { return nil }
        if isIDR { started = true }
        if !isIDR { return frame }
        if types.contains(AnnexB.nalSPS) && types.contains(AnnexB.nalPPS) { return frame }
        guard let config else { return frame }
        return config + frame
    }
}
