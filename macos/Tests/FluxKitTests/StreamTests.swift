import CoreGraphics
import XCTest
@testable import FluxKit

final class WebcamProtocolTests: XCTestCase {
    private let sps: [UInt8] = [0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1F]
    private let pps: [UInt8] = [0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80]
    private let idr: [UInt8] = [0, 0, 0, 1, 0x65, 0x11, 0x22]
    private let pFrame: [UInt8] = [0, 0, 0, 1, 0x41, 0x33, 0x44]

    func testStartBodyHasEveryField() {
        let p = WebcamPackets.start(port: 1742, width: 1920, height: 1080)
        XCTAssertEqual(p.type, PacketType.fluxWebcam)
        XCTAssertEqual(p.string("state"), "start")
        XCTAssertEqual(p.int("port"), 1742)
        XCTAssertEqual(p.int("width"), 1920)
        XCTAssertEqual(p.int("height"), 1080)
        XCTAssertEqual(p.int("fps"), 30)
        XCTAssertEqual(p.string("codec"), "h264")
        XCTAssertEqual(Packet.parse(p.serialize())?.int("port"), 1742)
    }

    func testStopBody() {
        XCTAssertEqual(WebcamPackets.stop().string("state"), "stop")
    }

    func testParsesReplies() {
        let live = WebcamReply.parse(Packet(PacketType.fluxWebcam, ["state": "live", "device": "/dev/video42", "label": "Flux Camera"]))
        XCTAssertEqual(live, .live(device: "/dev/video42", label: "Flux Camera"))
        let failed = WebcamReply.parse(Packet(PacketType.fluxWebcam, ["state": "error", "message": "v4l2loopback is missing"]))
        XCTAssertEqual(failed, .failed("v4l2loopback is missing"))
        XCTAssertEqual(WebcamReply.parse(Packet(PacketType.fluxWebcam, ["state": "stop"])), .stop)
        XCTAssertNil(WebcamReply.parse(Packet(PacketType.fluxWebcam, ["state": "start"])))
        XCTAssertNil(WebcamReply.parse(Packet(PacketType.ping)))
    }

    func testLiveWithoutLabelGetsTheDefaultName() {
        let live = WebcamReply.parse(Packet(PacketType.fluxWebcam, ["state": "live", "device": "/dev/video42"]))
        XCTAssertEqual(live, .live(device: "/dev/video42", label: "Flux Camera"))
        let empty = WebcamReply.parse(Packet(PacketType.fluxWebcam, ["state": "error", "message": ""]))
        XCTAssertEqual(empty, .failed("The computer could not start the camera"))
    }

    func testFindsNalTypes() {
        XCTAssertEqual(AnnexB.nalTypes(sps + pps + idr), [7, 8, 5])
        // A 3-byte start code works too.
        XCTAssertEqual(AnnexB.nalTypes([0, 0, 1, 0x41, 0x01]), [1])
    }

    func testAddsMissingStartCode() {
        XCTAssertEqual(AnnexB.withStartCode([0x65, 0x11, 0x22]), idr)
        XCTAssertEqual(AnnexB.withStartCode(idr), idr)
    }

    func testFramerPutsConfigBeforeEachIdr() {
        var f = AnnexBFramer()
        f.onConfig(sps + pps)
        XCTAssertEqual(f.onFrame(idr, keyFrame: true), sps + pps + idr)
        XCTAssertEqual(f.onFrame(pFrame, keyFrame: false), pFrame)
        XCTAssertEqual(f.onFrame(idr, keyFrame: true), sps + pps + idr)
    }

    func testFramerDropsFramesBeforeTheFirstIdr() {
        var f = AnnexBFramer()
        f.onConfig(sps + pps)
        XCTAssertNil(f.onFrame(pFrame, keyFrame: false))
        XCTAssertEqual(f.onFrame(idr, keyFrame: true), sps + pps + idr)
    }

    func testFramerDoesNotRepeatConfigThatTheFrameHas() {
        var f = AnnexBFramer()
        f.onConfig(sps + pps)
        XCTAssertEqual(f.onFrame(sps + pps + idr, keyFrame: true), sps + pps + idr)
    }

    func testFramerFindsIdrWithoutTheKeyFlag() {
        var f = AnnexBFramer()
        f.onConfig(sps + pps)
        XCTAssertEqual(f.onFrame(idr, keyFrame: false), sps + pps + idr)
    }

    func testConvertsLengthPrefixedUnits() {
        // An SEI of 2 bytes and an IDR slice of 3 bytes, as VideoToolbox writes them.
        var four: [UInt8] = [0, 0, 0, 2, 0x06, 0x05, 0, 0, 0, 3, 0x65, 0x11, 0x22]
        XCTAssertTrue(AnnexB.convertLengthPrefixed(&four, headerLength: 4))
        XCTAssertEqual(four, [0, 0, 0, 1, 0x06, 0x05] + idr)
        XCTAssertEqual(AnnexB.nalTypes(four), [6, 5])

        var two: [UInt8] = [0, 2, 0x06, 0x05, 0, 3, 0x65, 0x11, 0x22]
        XCTAssertTrue(AnnexB.convertLengthPrefixed(&two, headerLength: 2))
        XCTAssertEqual(two, [0, 0, 0, 1, 0x06, 0x05] + idr)
    }

    func testRejectsLengthsPastTheEnd() {
        var truncated: [UInt8] = [0, 0, 0, 9, 0x65, 0x11]
        XCTAssertFalse(AnnexB.convertLengthPrefixed(&truncated, headerLength: 4))
        var partialHeader: [UInt8] = [0, 0, 0, 1, 0x65, 0, 0]
        XCTAssertFalse(AnnexB.convertLengthPrefixed(&partialHeader, headerLength: 4))
    }
}

final class WebcamConfigTests: XCTestCase {
    private func obj(_ s: String) -> [String: JSONValue] { JSONValue.parse(Data(s.utf8))!.object! }

    private var caps: WebcamCaps {
        var c = WebcamCaps()
        c.zoomMax = 8
        c.exposureMin = -2
        c.exposureMax = 2
        c.exposureStep = 1.0 / 3.0
        c.whiteBalance = ["auto", "daylight", "cloudy"]
        c.cameras = ["back", "front"]
        return c
    }

    private func config(_ change: (inout WebcamConfig) -> Void) -> WebcamConfig {
        var c = WebcamConfig()
        change(&c)
        return c
    }

    func testFrameSizePerAspect() {
        let cases: [(String, Int, Int, Int)] = [
            ("16:9", 720, 1280, 720), ("16:9", 1080, 1920, 1080),
            ("4:3", 720, 960, 720), ("4:3", 1080, 1440, 1080),
            ("1:1", 720, 720, 720), ("1:1", 1080, 1080, 1080),
            ("9:16", 720, 720, 1280), ("9:16", 1080, 1080, 1920),
            ("wide", 720, 1280, 720),
        ]
        for (aspect, short, w, h) in cases {
            let size = WebcamConfig.frameSize(aspect: aspect, short: short)
            XCTAssertEqual(size.width, w, "\(aspect) \(short)")
            XCTAssertEqual(size.height, h, "\(aspect) \(short)")
        }
    }

    func testConfigSizeFollowsAspectAndResolution() {
        let c = config { $0.aspect = "9:16"; $0.resolution = 1080 }
        XCTAssertEqual(c.width, 1080)
        XCTAssertEqual(c.height, 1920)
    }

    func testBitrateScalesWithPixels() {
        XCTAssertEqual(WebcamConfig.bitrate(width: 1280, height: 720), 4_000_000)
        XCTAssertEqual(WebcamConfig.bitrate(width: 1920, height: 1080), 8_000_000)
        XCTAssertEqual(WebcamConfig.bitrate(width: 720, height: 720), 2_250_000)
        XCTAssertEqual(WebcamConfig.bitrate(width: 1080, height: 1920), 8_000_000)
    }

    func testPartialChangesOnlyItsFields() {
        let c = WebcamConfig().merged(obj(#"{"brightness": 0.3, "aspect": "1:1"}"#))
        XCTAssertEqual(c, config { $0.brightness = 0.3; $0.aspect = "1:1" })
    }

    func testPartialAcceptsNumbersAsTextAndIgnoresWrongTypes() {
        let c = WebcamConfig().merged(obj(#"{"zoom": "2.5", "resolution": 1080.0, "mirror": "true", "camera": "FRONT", "contrast": "x", "saturation": true, "warmth": "NaN"}"#))
        XCTAssertEqual(c.zoom, 2.5)
        XCTAssertEqual(c.resolution, 1080)
        XCTAssertTrue(c.mirror)
        XCTAssertEqual(c.camera, "front")
        XCTAssertEqual(c.contrast, 1)
        XCTAssertEqual(c.saturation, 1)
        XCTAssertEqual(c.warmth, 0)
    }

    func testClampKeepsValuesInsideTheCaps() {
        let c = config {
            $0.aspect = "21:9"; $0.resolution = 2160; $0.camera = "side"; $0.zoom = 50; $0.exposure = 5
            $0.whiteBalance = "shade"; $0.brightness = 3; $0.contrast = -1; $0.saturation = 9; $0.warmth = -4
        }.clamped(caps)
        XCTAssertEqual(c.aspect, "16:9")
        XCTAssertEqual(c.resolution, 1080)
        XCTAssertEqual(c.camera, "back")
        XCTAssertEqual(c.zoom, 8)
        XCTAssertEqual(c.exposure, 2, accuracy: 1e-3)
        XCTAssertEqual(c.whiteBalance, "auto")
        XCTAssertEqual(c.brightness, 1)
        XCTAssertEqual(c.contrast, 0)
        XCTAssertEqual(c.saturation, 2)
        XCTAssertEqual(c.warmth, -1)
    }

    func testClampRoundsExposureToTheStepAndZoomUpToOne() {
        let c = config { $0.exposure = 0.4; $0.zoom = 0.5 }.clamped(caps)
        XCTAssertEqual(c.exposure, 0.333, accuracy: 1e-9)
        XCTAssertEqual(c.zoom, 1)
        // Clamping again changes nothing.
        XCTAssertEqual(c.clamped(caps), c)
    }

    /// A number that does not fit an Int trapped in the rounding or in the
    /// clamp. The resolution stays as it was.
    func testHugeResolutionDoesNotStopTheApp() {
        for value in ["1e300", "-1e300", "1e21", "9223372036854775807", "-9223372036854775808", #""1e300""#, #""-9.2233720368547748e18""#, "0", "-5"] {
            let c = WebcamConfig().merged(obj(#"{"resolution": \#(value)}"#))
            XCTAssertEqual(c.resolution, 720, value)
            XCTAssertEqual(c.clamped(caps).resolution, 720, value)
        }
        XCTAssertEqual(config { $0.resolution = Int.min }.clamped(caps).resolution, 720)
        XCTAssertEqual(config { $0.resolution = Int.max }.clamped(caps).resolution, 1080)
    }

    func testRoundingSaturates() {
        XCTAssertEqual(roundHalfUp(1e300), Int.max)
        XCTAssertEqual(roundHalfUp(-1e300), Int.min)
        XCTAssertEqual(roundHalfUp(.nan), 0)
        XCTAssertEqual(roundHalfUp(2.5), 3)
        XCTAssertEqual(roundHalfUp(-2.5), -2)
        let size = WebcamConfig.frameSize(aspect: "9223372036854775807:1", short: 720)
        XCTAssertEqual(size.height, 720)
        XCTAssertEqual(size.width % 2, 0)
    }

    func testClampWithoutExposureSetsZero() {
        XCTAssertEqual(config { $0.exposure = 1.5 }.clamped(WebcamCaps()).exposure, 0)
    }

    func testMacCapsKeepCamerasAndLimitDigitalControls() {
        let cameras = [
            CameraInfo(id: "facetime hd camera", uniqueID: "a", name: "FaceTime HD Camera", isContinuity: false),
            CameraInfo(id: "iphone camera", uniqueID: "b", name: "iPhone Camera", isContinuity: true),
        ]
        let caps = WebcamPlugin.caps(cameras)
        let saved = config { $0.camera = "iphone camera"; $0.zoom = 9; $0.exposure = -3; $0.whiteBalance = "daylight" }.clamped(caps)
        XCTAssertEqual(saved.camera, "iphone camera")
        XCTAssertEqual(saved.zoom, WebcamPlugin.zoomMax)
        XCTAssertEqual(saved.exposure, -WebcamPlugin.exposureLimit)
        XCTAssertEqual(saved.whiteBalance, "auto")
        // A camera that is gone falls back to the first one.
        XCTAssertEqual(config { $0.camera = "back" }.clamped(caps).camera, "facetime hd camera")
    }

    func testResetKeepsShapeQualityAndCamera() {
        let c = config {
            $0.aspect = "4:3"; $0.resolution = 1080; $0.camera = "front"; $0.mirror = true; $0.zoom = 3; $0.exposure = 1
            $0.whiteBalance = "cloudy"; $0.brightness = 0.5; $0.contrast = 1.5; $0.saturation = 0.2; $0.warmth = 0.7
        }.reset()
        XCTAssertEqual(c, config { $0.aspect = "4:3"; $0.resolution = 1080; $0.camera = "front" })
    }

    func testOnlyANewFrameSizeRestartsTheStream() {
        let c = WebcamConfig()
        XCTAssertTrue(c.restartsStream(config { $0.aspect = "4:3" }))
        XCTAssertTrue(c.restartsStream(config { $0.resolution = 1080 }))
        XCTAssertFalse(c.restartsStream(config { $0.camera = "front" }))
        XCTAssertFalse(c.restartsStream(config { $0.brightness = 0.4; $0.zoom = 2 }))
    }

    func testJSONRoundTrip() {
        let c = config {
            $0.aspect = "9:16"; $0.resolution = 1080; $0.camera = "front"; $0.mirror = true; $0.zoom = 2
            $0.whiteBalance = "daylight"; $0.warmth = -0.25
        }
        let text = JSONValue.object(c.json).serialized()
        XCTAssertEqual(WebcamConfig().merged(JSONValue.parse(text)?.object), c)
    }

    func testConfigPacketCarriesConfigAndCaps() {
        var withBrightness = WebcamConfig()
        withBrightness.brightness = 0.3
        let p = Packet.parse(WebcamPackets.config(withBrightness, caps).serialize())!
        XCTAssertEqual(p.type, PacketType.fluxWebcam)
        XCTAssertEqual(p.string("state"), "config")
        XCTAssertEqual(p.object("config")?["brightness"]?.double ?? 0, 0.3, accuracy: 1e-6)
        let c = p.object("caps")
        XCTAssertEqual(c?["zoomMax"]?.double, 8)
        XCTAssertEqual(c?["whiteBalance"]?.strings, ["auto", "daylight", "cloudy"])
        XCTAssertEqual(c?["resolutions"]?.array, [.int(720), .int(1080)])
    }

    func testParsesConfigFromTheComputer() {
        let partial = WebcamReply.parse(Packet(PacketType.fluxWebcam, ["state": "config", "config": ["brightness": 0.3]]))
        guard case .config(let fields, let reset)? = partial else { return XCTFail("not a config: \(String(describing: partial))") }
        XCTAssertFalse(reset)
        XCTAssertEqual(WebcamConfig().merged(fields).brightness, 0.3, accuracy: 1e-6)

        XCTAssertEqual(WebcamReply.parse(Packet(PacketType.fluxWebcam, ["state": "config", "reset": true])), .config(partial: nil, reset: true))
        // A config message with neither a config nor a reset means nothing.
        XCTAssertNil(WebcamReply.parse(Packet(PacketType.fluxWebcam, ["state": "config"])))
    }
}

final class FrameGeometryTests: XCTestCase {
    private let wide = 16.0 / 9.0
    private let tall = 9.0 / 16.0

    private func assertPoint(_ expected: CGPoint, _ actual: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-4, file: file, line: line)
    }

    private func point(_ m: CGAffineTransform, _ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y).applying(m) }

    func testLandscapeContentWithoutRotationIsIdentity() {
        let m = FrameGeometry.map(rotation: 0, contentAspect: wide, outputAspect: wide, mirror: false)
        assertPoint(CGPoint(x: 0, y: 0), point(m, 0, 0))
        assertPoint(CGPoint(x: 1, y: 1), point(m, 1, 1))
    }

    func testRotation90MapsCornersClockwise() {
        // Portrait content rotated clockwise by 90 degrees becomes landscape,
        // so no crop is needed. The top left of the output comes from the
        // bottom left of the content.
        let m = FrameGeometry.map(rotation: 90, contentAspect: tall, outputAspect: wide, mirror: false)
        assertPoint(CGPoint(x: 0, y: 0), point(m, 0, 1))
        assertPoint(CGPoint(x: 1, y: 1), point(m, 1, 0))
        assertPoint(CGPoint(x: 0.5, y: 0.5), point(m, 0.5, 0.5))
    }

    func testRotation180FlipsBothAxes() {
        let m = FrameGeometry.map(rotation: 180, contentAspect: wide, outputAspect: wide, mirror: false)
        assertPoint(CGPoint(x: 1, y: 1), point(m, 0, 0))
        assertPoint(CGPoint(x: 0, y: 0), point(m, 1, 1))
    }

    func testRotation270MapsCornersCounterClockwise() {
        let m = FrameGeometry.map(rotation: 270, contentAspect: tall, outputAspect: wide, mirror: false)
        assertPoint(CGPoint(x: 1, y: 1), point(m, 0, 1))
        assertPoint(CGPoint(x: 0, y: 0), point(m, 1, 0))
    }

    func testPortraitContentWithoutRotationIsCroppedToACenterBand() {
        // Upright portrait content in a 16:9 frame: the full width, and a
        // center band of the height.
        let m = FrameGeometry.map(rotation: 0, contentAspect: tall, outputAspect: wide, mirror: false)
        let band = tall / wide
        assertPoint(CGPoint(x: 0, y: 0.5 - band / 2), point(m, 0, 0))
        assertPoint(CGPoint(x: 1, y: 0.5 + band / 2), point(m, 1, 1))
    }

    func testMirrorFlipsTheOutputHorizontally() {
        let m = FrameGeometry.map(rotation: 0, contentAspect: wide, outputAspect: wide, mirror: true)
        assertPoint(CGPoint(x: 1, y: 0), point(m, 0, 0))
        assertPoint(CGPoint(x: 0, y: 1), point(m, 1, 1))
    }

    func testSnapRoundsToQuarterTurns() {
        XCTAssertEqual(FrameGeometry.snap(20), 0)
        XCTAssertEqual(FrameGeometry.snap(80), 90)
        XCTAssertEqual(FrameGeometry.snap(350), 0)
        XCTAssertEqual(FrameGeometry.snap(-80), 270)
    }

    func testTransformScalesTheCameraImageToTheFrame() {
        let t = FrameGeometry.transform(rotation: 0, source: CGSize(width: 1920, height: 1080), output: CGSize(width: 1280, height: 720), mirror: false, zoom: 1)
        assertPoint(CGPoint(x: 0, y: 0), point(t, 0, 0))
        assertPoint(CGPoint(x: 1280, y: 720), point(t, 1920, 1080))
    }

    func testTransformCropsAPortraitCameraToACenterBand() {
        let t = FrameGeometry.transform(rotation: 0, source: CGSize(width: 1080, height: 1920), output: CGSize(width: 1280, height: 720), mirror: false, zoom: 1)
        let band = tall / wide
        assertPoint(CGPoint(x: 0, y: 0), point(t, 0, (0.5 - band / 2) * 1920))
        assertPoint(CGPoint(x: 1280, y: 720), point(t, 1080, (0.5 + band / 2) * 1920))
    }

    func testZoomShowsTheCenterOfTheCamera() {
        let t = FrameGeometry.transform(rotation: 0, source: CGSize(width: 1920, height: 1080), output: CGSize(width: 1280, height: 720), mirror: true, zoom: 2)
        assertPoint(CGPoint(x: 640, y: 360), point(t, 960, 540))
        // With the mirror, the left of the center half lands on the right edge.
        assertPoint(CGPoint(x: 1280, y: 0), point(t, 480, 270))
        assertPoint(CGPoint(x: 0, y: 720), point(t, 1440, 810))
    }
}

final class ColorAdjustTests: XCTestCase {
    /// The fragment shader of the Android app, step by step.
    private func shader(_ c: [Double], _ a: ColorAdjust) -> [Double] {
        var c = c.map { $0 + a.brightness * 0.5 }
        c = c.map { ($0 - 0.5) * a.contrast + 0.5 }
        let l = zip(c, ColorAdjust.luma).map(*).reduce(0, +)
        c = c.map { l + ($0 - l) * a.saturation }
        return [c[0] + 0.08 * a.warmth, c[1], c[2] - 0.08 * a.warmth]
    }

    private func matrix(_ c: [Double], _ a: ColorAdjust) -> [Double] {
        (0..<3).map { i in zip(a.rows[i], c).map(*).reduce(0, +) + a.bias[i] }
    }

    func testNeutralValuesKeepTheImage() {
        let a = ColorAdjust()
        XCTAssertTrue(a.isNeutral)
        XCTAssertEqual(matrix([0.1, 0.5, 0.9], a), [0.1, 0.5, 0.9])
    }

    func testMatrixMatchesTheAndroidShader() {
        let looks = [
            ColorAdjust(brightness: 0.3, contrast: 1, saturation: 1, warmth: 0),
            ColorAdjust(brightness: 0, contrast: 1.6, saturation: 1, warmth: 0),
            ColorAdjust(brightness: 0, contrast: 1, saturation: 0, warmth: 0),
            ColorAdjust(brightness: -0.4, contrast: 0.7, saturation: 1.8, warmth: 0.9),
        ]
        for look in looks {
            for color in [[0.1, 0.5, 0.9], [0.8, 0.2, 0.3], [0.5, 0.5, 0.5]] {
                let expected = shader(color, look)
                for (a, b) in zip(matrix(color, look), expected) {
                    XCTAssertEqual(a, b, accuracy: 1e-12, "\(look) \(color)")
                }
            }
        }
    }
}

final class ScreenProtocolTests: XCTestCase {
    func testStartBodyHasTheSize() {
        let p = ScreenPackets.start(port: 1750, width: 496, height: 1072)
        XCTAssertEqual(p.type, PacketType.fluxScreen)
        XCTAssertEqual(p.string("state"), "start")
        XCTAssertEqual(p.int("port"), 1750)
        XCTAssertEqual(p.int("width"), 496)
        XCTAssertEqual(p.int("height"), 1072)
        XCTAssertEqual(p.string("codec"), "h264")
        XCTAssertEqual(ScreenPackets.stop().string("state"), "stop")
    }

    func testParsesReplies() {
        XCTAssertEqual(ScreenReply.parse(Packet(PacketType.fluxScreen, ["state": "live", "player": "mpv"])), .live(player: "mpv"))
        XCTAssertEqual(ScreenReply.parse(Packet(PacketType.fluxScreen, ["state": "error", "message": "no mpv"])), .failed("no mpv"))
        XCTAssertEqual(ScreenReply.parse(Packet(PacketType.fluxScreen, ["state": "stop"])), .stop)
        XCTAssertNil(ScreenReply.parse(Packet(PacketType.fluxScreen, ["state": "start"])))
        XCTAssertNil(ScreenReply.parse(Packet(PacketType.fluxMic, ["state": "stop"])))
    }

    private func assertFit(_ w: Int, _ h: Int, _ ew: Int, _ eh: Int, file: StaticString = #filePath, line: UInt = #line) {
        let size = MirrorSize.fit(width: w, height: h)
        XCTAssertEqual(size?.width, ew, file: file, line: line)
        XCTAssertEqual(size?.height, eh, file: file, line: line)
    }

    func testFitKeepsTheShapeUnder1080() {
        // A portrait screen: the long side is at most 1080 px, both sides a multiple of 16.
        assertFit(1080, 2340, 496, 1072)
        // The same screen in landscape swaps the sides.
        assertFit(2340, 1080, 1072, 496)
        // 720 x 1280 scales by 1080 / 1280, then aligns down to 16 px.
        assertFit(720, 1280, 592, 1072)
        // A screen under 1080 px keeps its size.
        assertFit(480, 800, 480, 800)
        // A Retina MacBook display.
        assertFit(3456, 2234, 1072, 688)
        XCTAssertNil(MirrorSize.fit(width: 0, height: 900))
    }

    func testBitrateHasAFloor() {
        XCTAssertEqual(MirrorSize.bitrate(width: 160, height: 160), 2_000_000)
        XCTAssertEqual(MirrorSize.bitrate(width: 496, height: 1072), 496 * 1072 * 8)
    }
}
