import Foundation

/// Stream framing math. Ports of Android `mic/MicProtocol.kt` (`Pcm`) and
/// `screen/ScreenProtocol.kt` (`MirrorSize`).
///
/// Wire packets live in `FluxProto/Streams.swift`; the byte listeners live
/// in `FluxCore/StreamEngine` (Android `stream/PinnedStream.kt`).

// MARK: - PCM (mic)

/// Helpers for 16-bit PCM. The mic streams raw s16le 48 kHz mono
/// (`MicPackets.rate/channels/format`); the desktop plays it into the
/// PipeWire source "Flux Microphone".
public enum Pcm {
    /// Encodes the first `n` samples in little-endian order, 2 bytes each.
    public static func toLittleEndian(_ samples: [Int16], count n: Int) -> Data {
        var out = Data(capacity: n * 2)
        for i in 0 ..< n {
            var v = samples[i].littleEndian
            out.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
        }
        return out
    }

    /// Returns the peak of the first `n` samples, 0 for silence to 1 for
    /// full scale (Mic screen level, ~15 Hz like Android).
    public static func peak(_ samples: [Int16], count n: Int) -> Float {
        var m: Int = 0
        for i in 0 ..< n {
            m = max(m, abs(Int(samples[i])))
        }
        return min(1, Float(m) / 32768)
    }

    /// Renders `seconds` of a sine wave at `freq` Hz (harness fixture:
    /// deterministic mic bytes with a verifiable checksum).
    public static func sine(seconds: Double, rate: Int = 48_000, freq: Double = 440) -> Data {
        let n = Int(seconds * Double(rate))
        var samples = [Int16](repeating: 0, count: n)
        for i in 0 ..< n {
            samples[i] = Int16(Double(Int16.max) * sin(2 * .pi * freq * Double(i) / Double(rate)))
        }
        return toLittleEndian(samples, count: n)
    }
}

// MARK: - Mirror size (screen)

/// The frame size of the mirror. Port of Android `MirrorSize`.
public enum MirrorSize {
    /// The longest side of the stream, in pixels.
    public static let maxLong = 1080

    /// Returns the encoder size for a screen of `width` × `height`: the
    /// same shape, at most `maxLong` pixels on the long side, both sides a
    /// multiple of `align`, as hardware encoders want.
    public static func fit(width: Int, height: Int, maxLong: Int = maxLong, align: Int = 16) -> (Int, Int) {
        precondition(width > 0 && height > 0, "the screen size must be positive")
        let scale = min(1, Double(maxLong) / Double(max(width, height)))
        func down(_ v: Int) -> Int { max(align, Int(Double(v) * scale) / align * align) }
        return (down(width), down(height))
    }

    /// Returns the bitrate for a frame size. Screen text needs more bits
    /// than a camera image.
    public static func bitrate(width: Int, height: Int) -> Int {
        max(2_000_000, width * height * 8)
    }
}
