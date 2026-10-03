import CoreGraphics
import XCTest
@testable import FluxKit

final class DesktopTouchTests: XCTestCase {
    typealias Action = DesktopTouches.Action

    /// A 400 × 300 view with a 1280 × 720 video: 400 × 225 at the top 37.5.
    private let fit = DesktopViewport(view: CGSize(width: 400, height: 300), video: CGSize(width: 1280, height: 720))

    private func point(_ x: Double, _ y: Double) -> DesktopPoint { DesktopPoint(x: x, y: y) }

    private func assertPoint(_ p: DesktopPoint?, _ x: Double, _ y: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard let p else { return XCTFail("no position", file: file, line: line) }
        XCTAssertEqual(p.x, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 1e-9, file: file, line: line)
    }

    // MARK: Viewport

    func testViewportFitsTheVideo() {
        XCTAssertEqual(fit.fitRect, CGRect(x: 0, y: 37.5, width: 400, height: 225))
        XCTAssertEqual(fit.pixel, 0.3125)
        XCTAssertEqual(fit.videoFrame, fit.fitRect)
        assertPoint(fit.toVideo(CGPoint(x: 200, y: 150)), 0.5, 0.5)
        assertPoint(fit.toVideo(CGPoint(x: 0, y: 37.5)), 0, 0)
        XCTAssertNil(fit.toVideo(CGPoint(x: 200, y: 10)), "the bar over the video")
        assertPoint(fit.toVideo(CGPoint(x: 200, y: 10), clamp: true), 0.5, 0)
    }

    func testZoomKeepsTheFocusAndStaysOnTheView() {
        let z = fit.zoom(2, focus: CGPoint(x: 200, y: 150))
        XCTAssertEqual(z.scale, 2)
        XCTAssertEqual(z.offset, CGPoint(x: -200, y: -150))
        assertPoint(z.toVideo(CGPoint(x: 200, y: 150)), 0.5, 0.5)
        XCTAssertEqual(z.pixel, 0.625)
        XCTAssertEqual(z.videoFrame, CGRect(x: -200, y: -75, width: 800, height: 450))
        XCTAssertEqual(z.pan(dx: 1000, dy: 0).offset.x, 0, "the left edge of the video stays at the left edge of the view")
        XCTAssertEqual(z.pan(dx: -1000, dy: 0).offset.x, -400)
        XCTAssertEqual(z.pan(dx: 0, dy: 1000).offset.y, -75)
        XCTAssertEqual(z.pan(dx: 0, dy: -1000).offset.y, -225)
        XCTAssertEqual(fit.zoom(100, focus: .zero).scale, DesktopViewport.maxScale)
        let back = z.zoom(0.1, focus: CGPoint(x: 10, y: 10))
        XCTAssertEqual(back.scale, 1)
        XCTAssertEqual(back.offset, .zero, "at scale 1 the video is in the center")
        XCTAssertEqual(fit.pan(dx: 50, dy: 50).offset, .zero, "a fitted video does not move")
    }

    func testResizeOfOneSideKeepsTheZoom() {
        let z = fit.zoom(3, focus: .zero)
        XCTAssertEqual(z.resized(view: fit.view, video: fit.video), z, "the same sizes keep the zoom")
        // A panel at the side takes 100 points of the width.
        let r = z.resized(view: CGSize(width: 300, height: 300), video: fit.video)
        XCTAssertEqual(r.pixel, z.pixel, accuracy: 1e-9, "the video keeps its size on the screen")
        XCTAssertEqual(r.scale, 4, accuracy: 1e-9)
        XCTAssertEqual(r.toVideo(CGPoint(x: 150, y: 150))?.x ?? -1, 1.0 / 6, accuracy: 1e-9,
                       "the point at the center keeps its place where the video allows it")
        XCTAssertNil(DesktopViewport(view: .zero, video: fit.video).toVideo(.zero), "no view yet")
    }

    func testRotationStartsAtScaleOne() {
        let z = fit.zoom(3, focus: CGPoint(x: 200, y: 150))
        let r = z.resized(view: CGSize(width: 300, height: 400), video: fit.video, focus: point(0.5, 0.5))
        XCTAssertEqual(r, DesktopViewport(view: CGSize(width: 300, height: 400), video: fit.video),
                       "both sides change, so the video fits the view again")
        XCTAssertEqual(r.scale, 1)
    }

    func testNewVideoOrFirstViewStartsAtScaleOne() {
        let z = fit.zoom(3, focus: .zero)
        let video = z.resized(view: fit.view, video: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(video.scale, 1)
        XCTAssertEqual(video.offset, .zero)
        let first = DesktopViewport(view: .zero, video: fit.video).resized(view: fit.view, video: fit.video)
        XCTAssertEqual(first, fit)
        let gone = z.resized(view: .zero, video: fit.video)
        XCTAssertEqual(gone.scale, 1)
    }

    func testKeyboardKeepsTheTappedPointInView() {
        // The keyboard takes the bottom half of the view.
        let short = CGSize(width: 400, height: 150)
        let center = fit.resized(view: short, video: fit.video)
        XCTAssertEqual(center.scale, 1.5, accuracy: 1e-9, "the video keeps its width, so the text keeps its size")
        XCTAssertEqual(center.pixel, fit.pixel, accuracy: 1e-9)
        assertPoint(center.toVideo(CGPoint(x: 200, y: 75)), 0.5, 0.5)

        let field = point(0.5, 0.9)
        let r = fit.resized(view: short, video: fit.video, focus: field)
        let y = r.videoFrame.minY + field.y * r.videoFrame.height
        XCTAssertTrue((0...short.height).contains(y), "a field near the bottom stays in view at \(y)")
        XCTAssertGreaterThan(y, 75, "the field stays in the lower part of the view")

        // The keyboard hides: the view comes back to the first fit.
        let back = r.resized(view: fit.view, video: fit.video, focus: field)
        XCTAssertEqual(back.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(back.videoFrame.minX, fit.fitRect.minX, accuracy: 1e-9)
        XCTAssertEqual(back.videoFrame.minY, fit.fitRect.minY, accuracy: 1e-9)
    }

    func testResizeKeepsTheScaleInItsLimits() {
        let z = fit.zoom(6, focus: CGPoint(x: 200, y: 150))
        let r = z.resized(view: CGSize(width: 100, height: 300), video: fit.video)
        XCTAssertEqual(r.scale, DesktopViewport.maxScale, "a smaller view cannot zoom past the limit")
        let wide = fit.resized(view: CGSize(width: 800, height: 300), video: fit.video)
        XCTAssertEqual(wide.scale, 1, "a wider view fits the video")
    }

    // MARK: Taps

    private func run(_ t: inout DesktopTouches, _ points: [Int: CGPoint], _ at: TimeInterval, _ v: DesktopViewport? = nil) -> [Action] {
        t.touches(points, at: at, viewport: v ?? fit)
    }

    func testTapClicksAtTheFinger() {
        var t = DesktopTouches()
        XCTAssertEqual(run(&t, [1: CGPoint(x: 100, y: 150)], 0), [])
        XCTAssertEqual(run(&t, [1: CGPoint(x: 103, y: 150)], 0.05), [], "a small motion is still a tap")
        XCTAssertEqual(run(&t, [:], 0.1), [.click(.left, point(0.25, 0.5))])
    }

    func testSecondTapNearTheFirstReusesItsPosition() {
        var t = DesktopTouches()
        _ = run(&t, [1: CGPoint(x: 100, y: 150)], 0)
        _ = run(&t, [:], 0.05)
        _ = run(&t, [2: CGPoint(x: 110, y: 160)], 0.2)
        XCTAssertEqual(run(&t, [:], 0.3), [.click(.left, point(0.25, 0.5))], "the computer sees a double click")
        _ = run(&t, [3: CGPoint(x: 200, y: 150)], 0.4)
        XCTAssertEqual(run(&t, [:], 0.45), [.click(.left, point(0.5, 0.5))], "a tap far away clicks at its own finger")
        _ = run(&t, [4: CGPoint(x: 200, y: 150)], 1.0)
        XCTAssertEqual(run(&t, [:], 1.0), [.click(.left, point(0.5, 0.5))])
        _ = run(&t, [5: CGPoint(x: 210, y: 150)], 1.5)
        XCTAssertEqual(run(&t, [:], 1.5), [.click(.left, point(0.525, 0.5))], "a late tap clicks at its own finger")
    }

    func testTapOnTheBarsDoesNothing() {
        var t = DesktopTouches()
        _ = run(&t, [1: CGPoint(x: 100, y: 10)], 0)
        XCTAssertEqual(run(&t, [:], 0.1), [])
    }

    // MARK: Hold

    func testHoldClicksTheRightButton() {
        var t = DesktopTouches()
        _ = run(&t, [1: CGPoint(x: 100, y: 150)], 0)
        XCTAssertEqual(t.holdDeadline, 0.45)
        XCTAssertEqual(t.holdIfDue(at: 0.3, viewport: fit), [])
        XCTAssertEqual(t.holdIfDue(at: 0.45, viewport: fit), [.held, .move(point(0.25, 0.5))], "the pointer goes under the finger")
        XCTAssertNil(t.holdDeadline)
        XCTAssertEqual(run(&t, [1: CGPoint(x: 102, y: 150)], 0.5), [])
        XCTAssertEqual(run(&t, [:], 0.6), [.click(.right, point(0.25, 0.5))])
    }

    func testHoldAndMoveDrags() {
        var t = DesktopTouches()
        _ = run(&t, [1: CGPoint(x: 100, y: 150)], 0)
        _ = t.holdIfDue(at: 0.5, viewport: fit)
        XCTAssertEqual(run(&t, [1: CGPoint(x: 120, y: 150)], 0.6), [.hold(true, point(0.25, 0.5)), .move(point(0.3, 0.5))])
        XCTAssertEqual(run(&t, [1: CGPoint(x: 120, y: 150)], 0.65), [], "no motion sends nothing")
        XCTAssertEqual(run(&t, [1: CGPoint(x: 500, y: 150)], 0.7), [.move(point(1, 0.5))], "a drag past the edge stays on the edge")
        XCTAssertEqual(run(&t, [:], 0.8), [.hold(false, point(1, 0.5))])
    }

    func testLateEventHoldsFirst() {
        var t = DesktopTouches()
        _ = run(&t, [1: CGPoint(x: 100, y: 150)], 0)
        XCTAssertEqual(run(&t, [1: CGPoint(x: 100, y: 150)], 0.5), [.held, .move(point(0.25, 0.5))])
    }

    func testCancelReleasesOnlyADrag() {
        var t = DesktopTouches()
        _ = run(&t, [1: CGPoint(x: 100, y: 150)], 0)
        XCTAssertEqual(t.cancel(viewport: fit), [], "a canceled tap does not click")
        _ = run(&t, [1: CGPoint(x: 100, y: 150)], 1)
        _ = t.holdIfDue(at: 1.5, viewport: fit)
        _ = run(&t, [1: CGPoint(x: 120, y: 150)], 1.6)
        XCTAssertEqual(t.cancel(viewport: fit), [.hold(false, point(0.3, 0.5))])
    }

    // MARK: Pan and zoom

    func testOneFingerMovesTheZoomedView() {
        let zoomed = fit.zoom(2, focus: CGPoint(x: 200, y: 150))
        var t = DesktopTouches()
        _ = run(&t, [1: CGPoint(x: 100, y: 150)], 0, zoomed)
        XCTAssertEqual(run(&t, [1: CGPoint(x: 104, y: 150)], 0.05, zoomed), [])
        XCTAssertEqual(run(&t, [1: CGPoint(x: 110, y: 150)], 0.1, zoomed), [.viewport(zoomed.pan(dx: 10, dy: 0))],
                       "the pan starts at the first position")
        let moved = zoomed.pan(dx: 10, dy: 0)
        XCTAssertEqual(run(&t, [1: CGPoint(x: 120, y: 145)], 0.15, moved), [.viewport(moved.pan(dx: 10, dy: -5))])
        XCTAssertNil(t.holdDeadline, "a pan does not hold")
        XCTAssertEqual(run(&t, [:], 0.2, moved), [], "a pan does not click")
    }

    func testTwoFingerTapClicksTheRightButtonAtTheCenter() {
        var t = DesktopTouches()
        _ = run(&t, [1: CGPoint(x: 100, y: 150)], 0)
        XCTAssertEqual(run(&t, [1: CGPoint(x: 100, y: 150), 2: CGPoint(x: 300, y: 150)], 0.02), [])
        XCTAssertNil(t.holdDeadline)
        XCTAssertEqual(run(&t, [2: CGPoint(x: 300, y: 150)], 0.1), [])
        XCTAssertEqual(run(&t, [:], 0.12), [.click(.right, point(0.5, 0.5))])
    }

    func testTwoFingersScrollAtTheirCenter() {
        var t = DesktopTouches()
        _ = run(&t, [1: CGPoint(x: 100, y: 150), 2: CGPoint(x: 200, y: 150)], 0)
        XCTAssertEqual(run(&t, [1: CGPoint(x: 100, y: 145), 2: CGPoint(x: 200, y: 145)], 0.02), [], "under the slop")
        XCTAssertEqual(run(&t, [1: CGPoint(x: 100, y: 140), 2: CGPoint(x: 200, y: 140)], 0.04),
                       [.move(point(0.375, 0.5)), .scroll(dx: 0, dy: 5 / 0.3125)],
                       "the pointer goes to the window under the fingers, and the content follows them")
        XCTAssertEqual(run(&t, [1: CGPoint(x: 90, y: 140), 2: CGPoint(x: 190, y: 140)], 0.06), [.scroll(dx: 10 / 0.3125, dy: 0)])
        XCTAssertEqual(run(&t, [1: CGPoint(x: 90, y: 140)], 0.08), [], "1 finger after a scroll does nothing")
        XCTAssertEqual(run(&t, [:], 0.1), [])
    }

    func testFingerThatLandsMovesNoScroll() {
        var t = DesktopTouches()
        _ = run(&t, [1: CGPoint(x: 100, y: 150), 2: CGPoint(x: 200, y: 150)], 0)
        _ = run(&t, [1: CGPoint(x: 100, y: 130), 2: CGPoint(x: 200, y: 130)], 0.02)
        XCTAssertEqual(run(&t, [1: CGPoint(x: 100, y: 130), 2: CGPoint(x: 200, y: 130), 3: CGPoint(x: 300, y: 10)], 0.04), [],
                       "the center jumps, and the next motion starts from there")
        XCTAssertEqual(run(&t, [1: CGPoint(x: 100, y: 127), 2: CGPoint(x: 200, y: 127), 3: CGPoint(x: 300, y: 7)], 0.06),
                       [.scroll(dx: 0, dy: 3 / 0.3125)])
    }

    func testPinchZoomsTheView() {
        var t = DesktopTouches()
        _ = run(&t, [1: CGPoint(x: 100, y: 150), 2: CGPoint(x: 200, y: 150)], 0)
        XCTAssertEqual(run(&t, [1: CGPoint(x: 80, y: 150), 2: CGPoint(x: 220, y: 150)], 0.02),
                       [.viewport(fit.zoom(70.0 / 50.0, focus: CGPoint(x: 150, y: 150)))])
        let z = fit.zoom(70.0 / 50.0, focus: CGPoint(x: 150, y: 150))
        XCTAssertEqual(run(&t, [1: CGPoint(x: 90, y: 160), 2: CGPoint(x: 230, y: 160)], 0.04, z),
                       [.viewport(z.zoom(1, focus: CGPoint(x: 150, y: 150), pan: CGVector(dx: 10, dy: 10)))],
                       "the pinch moves the view with the fingers")
        XCTAssertEqual(run(&t, [:], 0.1, z), [], "a pinch does not click")
    }
}
