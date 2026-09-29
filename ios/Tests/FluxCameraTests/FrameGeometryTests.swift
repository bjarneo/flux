import XCTest
@testable import FluxCamera

/// `FrameGeometry` vectors. Ports Android `FrameGeometryTest` verbatim.
final class FrameGeometryTests: XCTestCase {
    private let wide: Float = 16.0 / 9.0
    private let tall: Float = 9.0 / 16.0

    private func point(_ m: [Float], _ x: Float, _ y: Float) -> (Float, Float) {
        FrameGeometry.apply(m, x: x, y: y)
    }

    private func assertPoint(_ expected: (Float, Float), _ actual: (Float, Float), _ what: String = "") {
        XCTAssertEqual(expected.0, actual.0, accuracy: 1e-4, what)
        XCTAssertEqual(expected.1, actual.1, accuracy: 1e-4, what)
    }

    func testLandscapeContentWithoutRotationIsIdentity() {
        let m = FrameGeometry.matrix(rotation: 0, contentAspect: wide, outputAspect: wide, mirror: false)
        assertPoint((0, 0), point(m, 0, 0))
        assertPoint((1, 1), point(m, 1, 1))
    }

    func testRotation90MapsCornersClockwise() {
        let m = FrameGeometry.matrix(rotation: 90, contentAspect: tall, outputAspect: wide, mirror: false)
        assertPoint((0, 0), point(m, 0, 1))
        assertPoint((1, 1), point(m, 1, 0))
        assertPoint((0.5, 0.5), point(m, 0.5, 0.5))
    }

    func testRotation180FlipsBothAxes() {
        let m = FrameGeometry.matrix(rotation: 180, contentAspect: wide, outputAspect: wide, mirror: false)
        assertPoint((1, 1), point(m, 0, 0))
        assertPoint((0, 0), point(m, 1, 1))
    }

    func testRotation270MapsCornersCounterClockwise() {
        let m = FrameGeometry.matrix(rotation: 270, contentAspect: tall, outputAspect: wide, mirror: false)
        assertPoint((1, 1), point(m, 0, 1))
        assertPoint((0, 0), point(m, 1, 0))
    }

    func testPortraitContentWithoutRotationIsCroppedToACenterBand() {
        let m = FrameGeometry.matrix(rotation: 0, contentAspect: tall, outputAspect: wide, mirror: false)
        let band = tall / wide
        assertPoint((0, 0.5 - band / 2), point(m, 0, 0))
        assertPoint((1, 0.5 + band / 2), point(m, 1, 1))
    }

    func testMirrorFlipsTheOutputHorizontally() {
        let m = FrameGeometry.matrix(rotation: 0, contentAspect: wide, outputAspect: wide, mirror: true)
        assertPoint((1, 0), point(m, 0, 0))
        assertPoint((0, 1), point(m, 1, 1))
    }

    func testUprightRotationForNaturalContent() {
        XCTAssertEqual(0, FrameGeometry.uprightRotation(deviceOrientation: 0, sensorOrientation: 90, front: false, naturalContent: true))
        XCTAssertEqual(90, FrameGeometry.uprightRotation(deviceOrientation: 90, sensorOrientation: 90, front: false, naturalContent: true))
        XCTAssertEqual(270, FrameGeometry.uprightRotation(deviceOrientation: 270, sensorOrientation: 90, front: false, naturalContent: true))
        XCTAssertEqual(270, FrameGeometry.uprightRotation(deviceOrientation: 90, sensorOrientation: 270, front: true, naturalContent: true))
    }

    func testUprightRotationForSensorContentUsesTheSensorOrientation() {
        XCTAssertEqual(90, FrameGeometry.uprightRotation(deviceOrientation: 0, sensorOrientation: 90, front: false, naturalContent: false))
        XCTAssertEqual(180, FrameGeometry.uprightRotation(deviceOrientation: 90, sensorOrientation: 90, front: false, naturalContent: false))
        XCTAssertEqual(0, FrameGeometry.uprightRotation(deviceOrientation: 90, sensorOrientation: 90, front: true, naturalContent: false))
    }

    func testSnapRoundsToQuarterTurns() {
        XCTAssertEqual(0, FrameGeometry.snap(20))
        XCTAssertEqual(90, FrameGeometry.snap(80))
        XCTAssertEqual(0, FrameGeometry.snap(350))
        XCTAssertEqual(270, FrameGeometry.snap(-80))
    }

    func testDetectsAxisSwap() {
        let flipOnly: [Float] = [1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1]
        let rotated: [Float] = [0, -1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 1]
        XCTAssertFalse(FrameGeometry.swapsAxes(flipOnly))
        XCTAssertTrue(FrameGeometry.swapsAxes(rotated))
    }
}
