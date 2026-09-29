import Foundation

/// H.264 Annex-B helpers. Port of Android `webcam/AnnexB.kt` (`AnnexB`,
/// `AnnexBFramer`).
///
/// Annex-B NAL units start with `00 00 01` or `00 00 00 01`. The desktop
/// pipes the raw stream into ffmpeg (`-f h264`), which joins at any IDR
/// frame — so the phone must write SPS + PPS in front of each IDR frame
/// that lacks them.
public enum AnnexB {
    public static let nalIDR = 5
    public static let nalSPS = 7
    public static let nalPPS = 8

    private static let startCode = Data([0, 0, 0, 1])

    /// Returns the offsets of the first byte after each start code in `b`.
    public static func nalStarts(_ b: Data) -> [Int] {
        var out: [Int] = []
        var i = b.startIndex
        while i + 2 < b.endIndex {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                out.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        return out
    }

    /// Returns the NAL unit types in `b`, in order.
    public static func nalTypes(_ b: Data) -> [Int] {
        nalStarts(b).filter { $0 < b.count }.map { Int(b[$0]) & 0x1F }
    }

    public static func hasStartCode(_ b: Data) -> Bool {
        (b.count >= 3 && b[0] == 0 && b[1] == 0 && b[2] == 1)
            || (b.count >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 1)
    }

    /// Returns `b` with a 4-byte start code in front, when it has none.
    public static func withStartCode(_ b: Data) -> Data {
        hasStartCode(b) ? b : startCode + b
    }
}

/// Turns encoder output into a stream a decoder can join at any IDR frame.
/// The encoder sends SPS and PPS once, as codec config. The framer keeps
/// them and writes them in front of each IDR frame that lacks them.
public final class AnnexBFramer: @unchecked Sendable {
    private var config: Data?
    private var started = false

    public init() {}

    /// True after the codec config arrived.
    public var hasConfig: Bool { config != nil }

    /// Stores codec config. Returns no bytes — the config goes out with
    /// the next IDR frame.
    public func onConfig(_ data: Data) {
        config = AnnexB.withStartCode(data)
    }

    /// Returns the bytes to write for one encoded frame, or nil for a frame
    /// a decoder cannot use yet (before the first IDR frame).
    public func onFrame(_ data: Data, keyFrame: Bool) -> Data? {
        let frame = AnnexB.withStartCode(data)
        let types = AnnexB.nalTypes(frame)
        let isIDR = keyFrame || types.contains(AnnexB.nalIDR)
        if !isIDR, !started { return nil }
        if isIDR { started = true }
        if !isIDR { return frame }
        if types.contains(AnnexB.nalSPS), types.contains(AnnexB.nalPPS) { return frame }
        guard let c = config else { return frame }
        return c + frame
    }
}
