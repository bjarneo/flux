import XCTest
@testable import FluxCamera
@testable import FluxProto

/// `WebcamConfig` vectors. Ports Android `WebcamConfigTest` verbatim
/// (field shapes, clamp math, merge tolerance, reset/restart rules).
final class WebcamConfigTests: XCTestCase {
    private var caps: WebcamCaps {
        WebcamCaps(
            zoomMax: 8, exposureMin: -2, exposureMax: 2, exposureStep: 1.0 / 3.0,
            whiteBalance: ["auto", "daylight", "cloudy"], cameras: ["back", "front"])
    }

    private func assertSize(_ expected: (Int, Int), _ actual: (Int, Int)) {
        XCTAssertEqual(expected.0, actual.0)
        XCTAssertEqual(expected.1, actual.1)
    }

    func testFrameSizePerAspect() {
        assertSize((1280, 720), frameSize(aspect: "16:9", short: 720))
        assertSize((1920, 1080), frameSize(aspect: "16:9", short: 1080))
        assertSize((960, 720), frameSize(aspect: "4:3", short: 720))
        assertSize((1440, 1080), frameSize(aspect: "4:3", short: 1080))
        assertSize((720, 720), frameSize(aspect: "1:1", short: 720))
        assertSize((1080, 1080), frameSize(aspect: "1:1", short: 1080))
        assertSize((720, 1280), frameSize(aspect: "9:16", short: 720))
        assertSize((1080, 1920), frameSize(aspect: "9:16", short: 1080))
        assertSize((1280, 720), frameSize(aspect: "wide", short: 720))
    }

    func testConfigSizeFollowsAspectAndResolution() {
        let c = WebcamConfig(aspect: "9:16", resolution: 1080)
        XCTAssertEqual(1080, c.width)
        XCTAssertEqual(1920, c.height)
    }

    func testBitrateScalesWithPixels() {
        XCTAssertEqual(4_000_000, bitrateFor(width: 1280, height: 720))
        XCTAssertEqual(8_000_000, bitrateFor(width: 1920, height: 1080))
        XCTAssertEqual(2_250_000, bitrateFor(width: 720, height: 720))
        XCTAssertEqual(8_000_000, bitrateFor(width: 1080, height: 1920))
    }

    func testPartialChangesOnlyItsFields() {
        let c = WebcamConfig().merged(["brightness": .double(0.3), "aspect": .string("1:1")])
        XCTAssertEqual(0.3, c.brightness, accuracy: 1e-6)
        XCTAssertEqual("1:1", c.aspect)
        XCTAssertEqual(WebcamConfig(aspect: "1:1", brightness: c.brightness), c)
    }

    func testPartialAcceptsNumbersAsTextAndIgnoresWrongTypes() {
        let c = WebcamConfig().merged([
            "zoom": .string("2.5"), "resolution": .double(1080.0),
            "mirror": .string("true"), "camera": .string("FRONT"),
            "contrast": .string("x"), "saturation": .bool(true),
            "warmth": .string("NaN"),
        ])
        XCTAssertEqual(2.5, c.zoom, accuracy: 1e-6)
        XCTAssertEqual(1080, c.resolution)
        XCTAssertTrue(c.mirror)
        XCTAssertEqual("front", c.camera)
        XCTAssertEqual(1, c.contrast, accuracy: 0)
        XCTAssertEqual(1, c.saturation, accuracy: 0)
        XCTAssertEqual(0, c.warmth, accuracy: 0)
    }

    func testClampKeepsValuesInsideTheCaps() {
        let c = WebcamConfig(
            aspect: "21:9", resolution: 2160, camera: "side", zoom: 50, exposure: 5,
            whiteBalance: "shade", brightness: 3, contrast: -1, saturation: 9, warmth: -4
        ).clamped(caps)
        XCTAssertEqual("16:9", c.aspect)
        XCTAssertEqual(1080, c.resolution)
        XCTAssertEqual("back", c.camera)
        XCTAssertEqual(8, c.zoom, accuracy: 0)
        XCTAssertEqual(2, c.exposure, accuracy: 1e-3)
        XCTAssertEqual("auto", c.whiteBalance)
        XCTAssertEqual(1, c.brightness, accuracy: 0)
        XCTAssertEqual(0, c.contrast, accuracy: 0)
        XCTAssertEqual(2, c.saturation, accuracy: 0)
        XCTAssertEqual(-1, c.warmth, accuracy: 0)
    }

    func testClampRoundsExposureToTheStepAndZoomUpToOne() {
        let c = WebcamConfig(zoom: 0.5, exposure: 0.4).clamped(caps)
        XCTAssertEqual(0.333, c.exposure, accuracy: 1e-6)
        XCTAssertEqual(1, c.zoom, accuracy: 0)
        XCTAssertEqual(c, c.clamped(caps))
    }

    func testClampWithoutExposureSetsZero() {
        XCTAssertEqual(0, WebcamConfig(exposure: 1.5).clamped(WebcamCaps()).exposure, accuracy: 0)
    }

    func testLooseCapsKeepSavedValues() {
        let saved = WebcamConfig(camera: "front", zoom: 3, exposure: 1, whiteBalance: "twilight")
        XCTAssertEqual(saved, saved.clamped(WebcamCaps.loose))
    }

    func testResetKeepsShapeQualityAndCamera() {
        let c = WebcamConfig(
            aspect: "4:3", resolution: 1080, camera: "front", mirror: true, zoom: 3, exposure: 1,
            whiteBalance: "cloudy", brightness: 0.5, contrast: 1.5, saturation: 0.2, warmth: 0.7
        ).reset()
        XCTAssertEqual(WebcamConfig(aspect: "4:3", resolution: 1080, camera: "front"), c)
    }

    func testOnlyANewFrameSizeRestartsTheStream() {
        let c = WebcamConfig()
        XCTAssertTrue(c.restartsStream(WebcamConfig(resolution: 1080)))
        XCTAssertTrue(c.restartsStream(WebcamConfig(aspect: "1:1")))
        XCTAssertFalse(c.restartsStream(WebcamConfig(brightness: 0.5)))
        XCTAssertFalse(c.restartsStream(WebcamConfig(camera: "front")))
        XCTAssertFalse(c.restartsStream(c))
    }

    func testJsonRoundTrip() {
        let c = WebcamConfig(aspect: "4:3", resolution: 1080, camera: "front", mirror: true, zoom: 2.5,
                             exposure: 0.5, whiteBalance: "cloudy", brightness: 0.2, contrast: 1.2,
                             saturation: 0.8, warmth: -0.3)
        XCTAssertEqual(c, WebcamConfig().merged(c.jsonObject()))
    }

    func testPreferencesRoundTrip() {
        // An isolated suite (never the shared defaults): the next session
        // starts with the saved settings.
        let store = UserDefaults(suiteName: "org.omarchy.flux.test-webcam")!
        store.removePersistentDomain(forName: "org.omarchy.flux.test-webcam")
        XCTAssertEqual(WebcamConfig(), WebcamPreferences.load(store: store).config)
        let saved = WebcamConfig(aspect: "4:3", resolution: 1080, camera: "front", mirror: true, zoom: 2.5,
                                 exposure: 0.5, whiteBalance: "cloudy", brightness: 0.2, contrast: 1.2,
                                 saturation: 0.8, warmth: -0.3)
        WebcamPreferences(config: saved).save(store: store)
        XCTAssertEqual(saved, WebcamPreferences.load(store: store).config)
        store.removePersistentDomain(forName: "org.omarchy.flux.test-webcam")
    }
}
