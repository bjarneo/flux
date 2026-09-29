import Foundation
import FluxProto

/// Webcam settings + capabilities. Port of Android
/// `webcam/WebcamConfig.kt` (`WebcamConfig`, `WebcamCaps`, `frameSize`,
/// `bitrateFor`).
///
/// The phone and the computer both change the settings through the same
/// keys (`flux webcam set` refuses anything else — see `webcamKeys` in
/// `cmd/flux/main.go` and the table in `docs/camera.md`):
/// `aspect`, `resolution`, `camera`, `mirror`, `zoom`, `exposure`,
/// `whiteBalance`, `brightness`, `contrast`, `saturation`, `warmth`.
/// `aspect`/`resolution`/`camera` restart the stream; the rest apply live.

/// The frame shapes the phone offers, as width:height.
public let webcamAspects = ["16:9", "4:3", "1:1", "9:16"]

/// The short side of the frame, in pixels.
public let webcamResolutions = [720, 1080]

/// The white-balance modes in the protocol, in phone-display order.
public let webcamWhiteBalanceModes = ["auto", "daylight", "cloudy", "shade", "incandescent", "fluorescent", "twilight"]

/// The webcam settings. `aspect`/`resolution`/`camera` set the stream; the
/// other fields change the image while it streams.
public struct WebcamConfig: Sendable, Equatable {
    public var aspect: String
    public var resolution: Int
    public var camera: String
    public var mirror: Bool
    public var zoom: Float
    public var exposure: Float
    public var whiteBalance: String
    public var brightness: Float
    public var contrast: Float
    public var saturation: Float
    public var warmth: Float

    public init(
        aspect: String = "16:9", resolution: Int = 720, camera: String = "back",
        mirror: Bool = false, zoom: Float = 1, exposure: Float = 0,
        whiteBalance: String = "auto", brightness: Float = 0,
        contrast: Float = 1, saturation: Float = 1, warmth: Float = 0
    ) {
        self.aspect = aspect
        self.resolution = resolution
        self.camera = camera
        self.mirror = mirror
        self.zoom = zoom
        self.exposure = exposure
        self.whiteBalance = whiteBalance
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
    }

    public var width: Int { frameSize(aspect: aspect, short: resolution).0 }
    public var height: Int { frameSize(aspect: aspect, short: resolution).1 }
    public var bitrate: Int { bitrateFor(width: width, height: height) }

    /// Returns the config with the fields of `partial` applied. A field
    /// with the wrong type or a non-finite number is ignored (Android
    /// `merged` parity: numbers arrive as text too, `"NaN"` is dropped).
    public func merged(_ partial: [String: JSONValue]?) -> WebcamConfig {
        guard let partial else { return self }
        var next = self
        if let v = partialText(partial, "aspect") { next.aspect = v }
        if let v = partialNumber(partial, "resolution") { next.resolution = Int(v.rounded()) }
        if let v = partialText(partial, "camera") { next.camera = v.lowercased() }
        if let v = partialFlag(partial, "mirror") { next.mirror = v }
        if let v = partialNumber(partial, "zoom") { next.zoom = Float(v) }
        if let v = partialNumber(partial, "exposure") { next.exposure = Float(v) }
        if let v = partialText(partial, "whiteBalance") { next.whiteBalance = v.lowercased() }
        if let v = partialNumber(partial, "brightness") { next.brightness = Float(v) }
        if let v = partialNumber(partial, "contrast") { next.contrast = Float(v) }
        if let v = partialNumber(partial, "saturation") { next.saturation = Float(v) }
        if let v = partialNumber(partial, "warmth") { next.warmth = Float(v) }
        return next
    }

    /// Returns the config with each field inside the limits of `caps`.
    public func clamped(_ caps: WebcamCaps) -> WebcamConfig {
        let evMin = min(caps.exposureMin, caps.exposureMax)
        let evMax = max(caps.exposureMin, caps.exposureMax)
        var ev = exposure.clamped(to: evMin...evMax)
        if caps.exposureStep > 0 {
            ev = (Float((ev / caps.exposureStep).rounded()) * caps.exposureStep).clamped(to: evMin...evMax)
        }
        return WebcamConfig(
            aspect: caps.aspects.contains(aspect) ? aspect : (caps.aspects.first ?? "16:9"),
            resolution: nearest(caps.resolutions, to: resolution) ?? 720,
            camera: caps.cameras.contains(camera) ? camera : (caps.cameras.first ?? "back"),
            mirror: mirror,
            zoom: roundTo(zoom.clamped(to: 1...max(1, caps.zoomMax)), scale: 100),
            exposure: roundTo(ev, scale: 1000),
            whiteBalance: caps.whiteBalance.contains(whiteBalance) ? whiteBalance : "auto",
            brightness: roundTo(brightness.clamped(to: -1...1), scale: 100),
            contrast: roundTo(contrast.clamped(to: 0...2), scale: 100),
            saturation: roundTo(saturation.clamped(to: 0...2), scale: 100),
            warmth: roundTo(warmth.clamped(to: -1...1), scale: 100)
        )
    }

    /// Returns the neutral image values. Shape, quality, and camera stay
    /// (`flux webcam reset` semantics).
    public func reset() -> WebcamConfig {
        WebcamConfig(aspect: aspect, resolution: resolution, camera: camera)
    }

    /// Reports whether a change to `next` needs a new stream with a new
    /// frame size.
    public func restartsStream(_ next: WebcamConfig) -> Bool {
        width != next.width || height != next.height
    }

    /// Encodes the settings for the `config` packet (`WebcamPackets.config`).
    public func jsonObject() -> [String: JSONValue] {
        [
            "aspect": .string(aspect),
            "resolution": .integer(Int64(resolution)),
            "camera": .string(camera),
            "mirror": .bool(mirror),
            "zoom": .double(Double(zoom)),
            "exposure": .double(Double(exposure)),
            "whiteBalance": .string(whiteBalance),
            "brightness": .double(Double(brightness)),
            "contrast": .double(Double(contrast)),
            "saturation": .double(Double(saturation)),
            "warmth": .double(Double(warmth)),
        ]
    }
}

/// The persisted webcam settings (Android `WebcamSettings` parity, minus
/// the caps — those come from the live camera, not storage). The next
/// session starts with the same settings; a desktop `config` applies
/// through `merged` + `clamped` and saves the same way.
public struct WebcamPreferences: Sendable {
    private static let aspectKey = "org.omarchy.flux.webcam.aspect"
    private static let resolutionKey = "org.omarchy.flux.webcam.resolution"
    private static let cameraKey = "org.omarchy.flux.webcam.camera"
    private static let mirrorKey = "org.omarchy.flux.webcam.mirror"
    private static let zoomKey = "org.omarchy.flux.webcam.zoom"
    private static let exposureKey = "org.omarchy.flux.webcam.exposure"
    private static let whiteBalanceKey = "org.omarchy.flux.webcam.whiteBalance"
    private static let brightnessKey = "org.omarchy.flux.webcam.brightness"
    private static let contrastKey = "org.omarchy.flux.webcam.contrast"
    private static let saturationKey = "org.omarchy.flux.webcam.saturation"
    private static let warmthKey = "org.omarchy.flux.webcam.warmth"

    public var config: WebcamConfig

    public init(config: WebcamConfig = WebcamConfig()) {
        self.config = config
    }

    public static func load(store: UserDefaults = .standard) -> WebcamPreferences {
        var config = WebcamConfig()
        if let aspect = store.string(forKey: aspectKey) { config.aspect = aspect }
        if store.object(forKey: resolutionKey) != nil {
            config.resolution = store.integer(forKey: resolutionKey)
        }
        if let camera = store.string(forKey: cameraKey) { config.camera = camera }
        config.mirror = store.bool(forKey: mirrorKey)
        if store.object(forKey: zoomKey) != nil { config.zoom = store.float(forKey: zoomKey) }
        if store.object(forKey: exposureKey) != nil { config.exposure = store.float(forKey: exposureKey) }
        if let whiteBalance = store.string(forKey: whiteBalanceKey) { config.whiteBalance = whiteBalance }
        if store.object(forKey: brightnessKey) != nil { config.brightness = store.float(forKey: brightnessKey) }
        if store.object(forKey: contrastKey) != nil { config.contrast = store.float(forKey: contrastKey) }
        if store.object(forKey: saturationKey) != nil { config.saturation = store.float(forKey: saturationKey) }
        if store.object(forKey: warmthKey) != nil { config.warmth = store.float(forKey: warmthKey) }
        return WebcamPreferences(config: config)
    }

    public func save(store: UserDefaults = .standard) {
        store.set(config.aspect, forKey: Self.aspectKey)
        store.set(config.resolution, forKey: Self.resolutionKey)
        store.set(config.camera, forKey: Self.cameraKey)
        store.set(config.mirror, forKey: Self.mirrorKey)
        store.set(config.zoom, forKey: Self.zoomKey)
        store.set(config.exposure, forKey: Self.exposureKey)
        store.set(config.whiteBalance, forKey: Self.whiteBalanceKey)
        store.set(config.brightness, forKey: Self.brightnessKey)
        store.set(config.contrast, forKey: Self.contrastKey)
        store.set(config.saturation, forKey: Self.saturationKey)
        store.set(config.warmth, forKey: Self.warmthKey)
    }
}
/// What the current camera and the encoder support.
public struct WebcamCaps: Sendable, Equatable {
    public var zoomMax: Float
    public var exposureMin: Float
    public var exposureMax: Float
    public var exposureStep: Float
    public var whiteBalance: [String]
    public var cameras: [String]
    public var aspects: [String]
    public var resolutions: [Int]

    public init(
        zoomMax: Float = 1, exposureMin: Float = 0, exposureMax: Float = 0,
        exposureStep: Float = 0, whiteBalance: [String] = ["auto"],
        cameras: [String] = ["back"], aspects: [String] = webcamAspects,
        resolutions: [Int] = webcamResolutions
    ) {
        self.zoomMax = zoomMax
        self.exposureMin = exposureMin
        self.exposureMax = exposureMax
        self.exposureStep = exposureStep
        self.whiteBalance = whiteBalance
        self.cameras = cameras
        self.aspects = aspects
        self.resolutions = resolutions
    }

    /// Wide limits for the time before the camera reports its real limits.
    public static let loose = WebcamCaps(
        zoomMax: 10, exposureMin: -10, exposureMax: 10,
        whiteBalance: webcamWhiteBalanceModes, cameras: ["back", "front"]
    )

    /// Encodes the caps for the `config` packet (`WebcamPackets.config`).
    public func jsonObject() -> [String: JSONValue] {
        [
            "zoomMax": .double(Double(zoomMax)),
            "exposureMin": .double(Double(exposureMin)),
            "exposureMax": .double(Double(exposureMax)),
            "exposureStep": .double(Double(exposureStep)),
            "whiteBalance": .array(whiteBalance.map { .string($0) }),
            "cameras": .array(cameras.map { .string($0) }),
            "aspects": .array(aspects.map { .string($0) }),
            "resolutions": .array(resolutions.map { .integer(Int64($0)) }),
        ]
    }
}

/// Returns the frame size for `aspect` with `short` pixels on the short
/// side. Both sides are even, as H.264 needs. An unknown aspect is 16:9.
public func frameSize(aspect: String, short: Int) -> (Int, Int) {
    let parts = aspect.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    let (a, b): (Int, Int) =
        if parts.count == 2, parts[0] > 0, parts[1] > 0 { (parts[0], parts[1]) } else { (16, 9) }
    func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
    if a >= b {
        return (even(Double(short) * Double(a) / Double(b)), short)
    }
    return (short, even(Double(short) * Double(b) / Double(a)))
}

/// Returns the encoder bitrate for a frame size: 4 Mbit/s for 1280x720 and
/// 8 Mbit/s for 1920x1080, scaled by the number of pixels for other shapes.
public func bitrateFor(width: Int, height: Int) -> Int {
    let perPixel =
        min(width, height) >= 1080
        ? 8_000_000.0 / Double(1920 * 1080)
        : 4_000_000.0 / Double(1280 * 720)
    return max(1_000_000, Int((Double(width * height) * perPixel).rounded()))
}

// MARK: - Partial-value readers (Android JsonObject.text/number/flag parity)

private func partialText(_ o: [String: JSONValue], _ key: String) -> String? {
    guard case .string(let s) = o[key] else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

private func partialNumber(_ o: [String: JSONValue], _ key: String) -> Double? {
    switch o[key] {
    case .double(let d): return d.isFinite ? d : nil
    case .integer(let i): return Double(i)
    case .string(let s):
        guard let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), d.isFinite else { return nil }
        return d
    default: return nil
    }
}

private func partialFlag(_ o: [String: JSONValue], _ key: String) -> Bool? {
    switch o[key] {
    case .bool(let b): return b
    case .string(let s):
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    default: return nil
    }
}

private func roundTo(_ v: Float, scale: Float) -> Float {
    (v * scale).rounded() / scale
}

/// First minimal element (Kotlin `minByOrNull` keeps the first on ties).
private func nearest(_ values: [Int], to target: Int) -> Int? {
    var best: Int?
    var bestDist = Int.max
    for v in values {
        let d = abs(v - target)
        if d < bestDist {
            bestDist = d
            best = v
        }
    }
    return best
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
