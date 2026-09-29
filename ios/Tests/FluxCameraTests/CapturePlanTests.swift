import XCTest
@testable import FluxCamera

/// `planCapture` vectors. Ports Android `CapturePlanTest` verbatim: folder
/// rules, switch baselines, sent ledger, pending images, baseline motion.
final class CapturePlanTests: XCTestCase {
    private let now: Int64 = 1_800_000_000

    private func img(_ id: Int64, _ path: String, pending: Bool = false, added: Int64? = nil) -> MediaImage {
        MediaImage(id: id, relativePath: path, name: "IMG_\(id).jpg", pending: pending, dateAdded: added ?? now)
    }

    func testFolderRules() {
        XCTAssertEqual(.screenshot, CaptureRules.kind(of: "Pictures/Screenshots/"))
        XCTAssertEqual(.screenshot, CaptureRules.kind(of: "DCIM/Screenshots/"))
        XCTAssertEqual(.screenshot, CaptureRules.kind(of: "dcim/screenshots"))
        XCTAssertEqual(.photo, CaptureRules.kind(of: "DCIM/Camera/"))
        XCTAssertNil(CaptureRules.kind(of: "Pictures/WhatsApp/"))
        XCTAssertNil(CaptureRules.kind(of: "DCIM/CameraRoll/"))
        XCTAssertNil(CaptureRules.kind(of: ""))
    }

    func testOnlyImagesAfterTheSwitchGoOut() {
        let state = CaptureState().enable(.photo, newest: 10)
        let plan = planCapture(state: state, images: [img(9, "DCIM/Camera/"), img(11, "DCIM/Camera/")], now: now)
        XCTAssertEqual([11], plan.send.map(\.0.id))
        XCTAssertEqual(.photo, plan.send.first?.1)
    }

    func testAKindThatIsOffDoesNotGoOut() {
        let state = CaptureState().enable(.photo, newest: 10)
        let plan = planCapture(state: state, images: [img(11, "Pictures/Screenshots/"), img(12, "Download/")], now: now)
        XCTAssertTrue(plan.send.isEmpty)
        XCTAssertEqual(12, plan.state.baseline, "both images need no more work")
    }

    func testASentImageDoesNotGoOutAgain() {
        let state = CaptureState().enable(.screenshot, newest: 10)
        let images = [img(11, "Pictures/Screenshots/")]
        let first = planCapture(state: state, images: images, now: now)
        XCTAssertEqual(1, first.send.count)
        XCTAssertEqual(10, first.state.baseline, "the image did not go out yet, so the baseline stays before it")
        let second = planCapture(state: first.state.markSent(11), images: images, now: now)
        XCTAssertTrue(second.send.isEmpty, "a reconnect or a restart does not send again")
        XCTAssertEqual(11, second.state.baseline)
        XCTAssertTrue(second.state.sent.isEmpty, "the baseline covers the sent image")
    }

    func testAnUnsentImageIsTriedAgain() {
        let state = CaptureState().enable(.photo, newest: 10)
        let images = [img(11, "DCIM/Camera/"), img(12, "DCIM/Camera/")]
        let first = planCapture(state: state, images: images, now: now)
        // No computer took 11. Only 12 went out.
        let second = planCapture(state: first.state.markSent(12), images: images, now: now)
        XCTAssertEqual([11], second.send.map(\.0.id))
        XCTAssertEqual(10, second.state.baseline)
    }

    func testAPendingImageWaits() {
        let state = CaptureState().enable(.photo, newest: 10)
        let pending = planCapture(
            state: state,
            images: [img(11, "DCIM/Camera/", pending: true), img(12, "Download/")], now: now)
        XCTAssertTrue(pending.send.isEmpty)
        XCTAssertEqual(10, pending.state.baseline, "the pending image stops the baseline")
        let done = planCapture(
            state: pending.state,
            images: [img(11, "DCIM/Camera/"), img(12, "Download/")], now: now)
        XCTAssertEqual([11], done.send.map(\.0.id))
    }

    func testAnOldPendingImageDoesNotBlock() {
        let state = CaptureState().enable(.photo, newest: 10)
        let old = now - CaptureRules.pendingLimitSec - 1
        let plan = planCapture(
            state: state,
            images: [img(11, "DCIM/Camera/", pending: true, added: old), img(12, "Download/")], now: now)
        XCTAssertEqual(12, plan.state.baseline)
    }

    func testASecondSwitchStartsAtItsOwnTime() {
        var state = CaptureState().enable(.photo, newest: 10)
        state = state.enable(.screenshot, newest: 20)
        let plan = planCapture(
            state: state,
            images: [img(15, "Pictures/Screenshots/"), img(21, "Pictures/Screenshots/")], now: now)
        XCTAssertEqual([21], plan.send.map(\.0.id))
    }

    func testTurningAllOffAndOnSkipsTheGap() {
        var state = CaptureState().enable(.photo, newest: 10).disable(.photo)
        state = state.enable(.photo, newest: 50)
        XCTAssertEqual(50, state.baseline)
        let plan = planCapture(
            state: state,
            images: [img(30, "DCIM/Camera/"), img(51, "DCIM/Camera/")], now: now)
        XCTAssertEqual([51], plan.send.map(\.0.id))
    }
}
