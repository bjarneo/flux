import Foundation

/// The webcam settings. This Mac and the computer can both change them.
/// aspect, resolution, and camera set the stream. The other fields change
/// the image while it streams. The field names are the keys of the
/// flux.webcam "config" object.
public struct WebcamConfig: Equatable, Sendable {
    /// The frame shapes that the webcam offers, as width:height.
    public static let aspects = ["16:9", "4:3", "1:1", "9:16"]
    /// The short side of the frame, in pixels.
    public static let resolutions = [720, 1080]

    public var aspect = "16:9"
    public var resolution = 720
    public var camera = "back"
    public var mirror = false
    public var zoom = 1.0
    public var exposure = 0.0
    public var whiteBalance = "auto"
    public var brightness = 0.0
    public var contrast = 1.0
    public var saturation = 1.0
    public var warmth = 0.0

    public init() {}

    public var width: Int { Self.frameSize(aspect: aspect, short: resolution).width }
    public var height: Int { Self.frameSize(aspect: aspect, short: resolution).height }
    public var bitrate: Int { Self.bitrate(width: width, height: height) }

    /// Returns the config with the fields of partial applied. A field with the
    /// wrong type or a value that is not a finite number is ignored.
    public func merged(_ partial: [String: JSONValue]?) -> WebcamConfig {
        guard let partial else { return self }
        var c = self
        c.aspect = partial.text("aspect") ?? aspect
        // A resolution outside 1 to 10000 pixels is not a value that a
        // camera has. The clamp to the caps picks the next valid value.
        c.resolution = partial.number("resolution").flatMap { (1...10_000).contains($0) ? roundHalfUp($0) : nil } ?? resolution
        c.camera = partial.text("camera")?.lowercased() ?? camera
        c.mirror = partial.flag("mirror") ?? mirror
        c.zoom = partial.number("zoom") ?? zoom
        c.exposure = partial.number("exposure") ?? exposure
        c.whiteBalance = partial.text("whiteBalance")?.lowercased() ?? whiteBalance
        c.brightness = partial.number("brightness") ?? brightness
        c.contrast = partial.number("contrast") ?? contrast
        c.saturation = partial.number("saturation") ?? saturation
        c.warmth = partial.number("warmth") ?? warmth
        return c
    }

    /// Returns the config with each field inside the limits of caps.
    public func clamped(_ caps: WebcamCaps) -> WebcamConfig {
        let evMin = min(caps.exposureMin, caps.exposureMax)
        let evMax = max(caps.exposureMin, caps.exposureMax)
        var ev = exposure.limited(evMin, evMax)
        if caps.exposureStep > 0 {
            ev = (Double(roundHalfUp(ev / caps.exposureStep)) * caps.exposureStep).limited(evMin, evMax)
        }
        var c = self
        c.aspect = caps.aspects.contains(aspect) ? aspect : caps.aspects.first ?? "16:9"
        // The distance in Double cannot overflow, also for a resolution
        // that update gets from a caller. The small range keeps the Double
        // exact, so a huge resolution gives the largest one in caps.
        let r = Double(min(max(resolution, 0), 1 << 20))
        c.resolution = caps.resolutions.min { abs(Double($0) - r) < abs(Double($1) - r) } ?? 720
        c.camera = caps.cameras.contains(camera) ? camera : caps.cameras.first ?? "back"
        c.zoom = round(zoom.limited(1, max(1, caps.zoomMax)), 100)
        c.exposure = round(ev, 1000)
        c.whiteBalance = caps.whiteBalance.contains(whiteBalance) ? whiteBalance : "auto"
        c.brightness = round(brightness.limited(-1, 1), 100)
        c.contrast = round(contrast.limited(0, 2), 100)
        c.saturation = round(saturation.limited(0, 2), 100)
        c.warmth = round(warmth.limited(-1, 1), 100)
        return c
    }

    /// Returns the neutral image values. The shape, the quality, and the
    /// camera stay.
    public func reset() -> WebcamConfig {
        var neutral = WebcamConfig()
        neutral.aspect = aspect
        neutral.resolution = resolution
        neutral.camera = camera
        return neutral
    }

    /// Reports whether a change to next needs a new stream with a new frame size.
    public func restartsStream(_ next: WebcamConfig) -> Bool {
        width != next.width || height != next.height
    }

    /// Returns the frame size for aspect with short pixels on the short
    /// side. Both sides are even, as H.264 needs. An unknown aspect is 16:9.
    public static func frameSize(aspect: String, short: Int) -> (width: Int, height: Int) {
        let parts = aspect.split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let (a, b) = parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? (parts[0], parts[1]) : (16, 9)
        // The half stays inside half the Int range, so the product cannot overflow.
        func even(_ v: Double) -> Int { max(min(roundHalfUp(v / 2), Int.max / 2), Int.min / 2) * 2 }
        return a >= b
            ? (even(Double(short) * Double(a) / Double(b)), short)
            : (short, even(Double(short) * Double(b) / Double(a)))
    }

    /// Returns the encoder bitrate for a frame size: 4 Mbit/s for 1280x720
    /// and 8 Mbit/s for 1920x1080, scaled by the number of pixels for other
    /// shapes.
    public static func bitrate(width: Int, height: Int) -> Int {
        let perPixel = min(width, height) >= 1080 ? 8_000_000.0 / (1920 * 1080) : 4_000_000.0 / (1280 * 720)
        return max(1_000_000, roundHalfUp(Double(width) * Double(height) * perPixel))
    }

    public var json: [String: JSONValue] {
        [
            "aspect": .string(aspect),
            "resolution": .int(Int64(resolution)),
            "camera": .string(camera),
            "mirror": .bool(mirror),
            "zoom": .double(zoom),
            "exposure": .double(exposure),
            "whiteBalance": .string(whiteBalance),
            "brightness": .double(brightness),
            "contrast": .double(contrast),
            "saturation": .double(saturation),
            "warmth": .double(warmth),
        ]
    }
}

/// What the current camera and the encoder support.
public struct WebcamCaps: Equatable, Sendable {
    public var zoomMax = 1.0
    public var exposureMin = 0.0
    public var exposureMax = 0.0
    public var exposureStep = 0.0
    public var whiteBalance = ["auto"]
    public var cameras = ["back"]
    public var aspects = WebcamConfig.aspects
    public var resolutions = WebcamConfig.resolutions

    public init() {}

    public var json: [String: JSONValue] {
        [
            "zoomMax": .double(zoomMax),
            "exposureMin": .double(exposureMin),
            "exposureMax": .double(exposureMax),
            "exposureStep": .double(exposureStep),
            "whiteBalance": .array(whiteBalance.map { .string($0) }),
            "cameras": .array(cameras.map { .string($0) }),
            "aspects": .array(aspects.map { .string($0) }),
            "resolutions": .array(resolutions.map { .int(Int64($0)) }),
        ]
    }
}

/// Rounds like Kotlin roundToInt, so both apps agree on the values: halves
/// go up. Like roundToInt it saturates at the Int range, and NaN is 0, so
/// that no value traps.
func roundHalfUp(_ v: Double) -> Int {
    let r = (v + 0.5).rounded(.down)
    if r.isNaN { return 0 }
    return Int(exactly: r) ?? (r > 0 ? Int.max : Int.min)
}

private func round(_ v: Double, _ scale: Double) -> Double { Double(roundHalfUp(v * scale)) / scale }

private extension Double {
    func limited(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func text(_ key: String) -> String? {
        guard case .string(let s)? = self[key] else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    func number(_ key: String) -> Double? {
        let v: Double?
        switch self[key] {
        case .int(let i)?: v = Double(i)
        case .double(let d)?: v = d
        case .string(let s)?: v = Double(s.trimmingCharacters(in: .whitespaces))
        default: v = nil
        }
        return v.flatMap { $0.isFinite ? $0 : nil }
    }

    func flag(_ key: String) -> Bool? {
        switch self[key] {
        case .bool(let b)?: return b
        case .string(let s)?:
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default: return nil
        }
    }
}
