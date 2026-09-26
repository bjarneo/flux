import XCTest
@testable import FluxKit

final class CapturePlanTests: XCTestCase {
    private let now: Int64 = 1_800_000_000

    private func shot(_ id: Int64, pending: Bool = false, added: Int64? = nil) -> CaptureItem {
        CaptureItem(id: id, kind: .screenshot, name: "Screenshot \(id).png", pending: pending, dateAdded: added ?? now)
    }

    private func photo(_ id: Int64, pending: Bool = false, added: Int64? = nil) -> CaptureItem {
        CaptureItem(id: id, kind: .photo, name: "IMG_\(id).jpg", pending: pending, dateAdded: added ?? now)
    }

    private func other(_ id: Int64) -> CaptureItem {
        CaptureItem(id: id, kind: nil, name: "notes-\(id).txt", dateAdded: now)
    }

    func testScreenshotRules() {
        XCTAssertTrue(CaptureRules.isScreenshot(name: "Screenshot 2026-09-26 at 10.00.00.png", marked: true))
        XCTAssertTrue(CaptureRules.isScreenshot(name: "Captura de Tela 2026-09-26.JPG", marked: true))
        XCTAssertTrue(CaptureRules.isScreenshot(name: "shot.heic", marked: true))
        XCTAssertFalse(CaptureRules.isScreenshot(name: "Screen Recording 2026-09-26.mov", marked: true), "a recording is not an image")
        XCTAssertFalse(CaptureRules.isScreenshot(name: "Screenshot 2026-09-26.png", marked: false), "only marked files are screenshots")
        XCTAssertFalse(CaptureRules.isScreenshot(name: "png", marked: true))
    }

    func testOnlyImagesAfterTheSwitchGoOut() {
        let state = CaptureState().enable(.photo, newest: 10)
        let plan = planCapture(state, items: [photo(9), photo(11)], now: now)
        XCTAssertEqual(plan.send.map(\.item.id), [11])
        XCTAssertEqual(plan.send.first?.kind, .photo)
    }

    func testAKindThatIsOffDoesNotGoOut() {
        let state = CaptureState().enable(.photo, newest: 10)
        let plan = planCapture(state, items: [shot(11), other(12)], now: now)
        XCTAssertTrue(plan.send.isEmpty)
        XCTAssertEqual(plan.state.baseline, 12, "both items need no more work")
    }

    func testASentImageDoesNotGoOutAgain() {
        var state = CaptureState().enable(.screenshot, newest: 10)
        let items = [shot(11)]
        let first = planCapture(state, items: items, now: now)
        XCTAssertEqual(first.send.count, 1)
        // The image did not go out yet, so the baseline stays before it.
        XCTAssertEqual(first.state.baseline, 10)
        state = first.state.markSent(11)
        let second = planCapture(state, items: items, now: now)
        XCTAssertTrue(second.send.isEmpty, "a reconnect or a restart does not send again")
        XCTAssertEqual(second.state.baseline, 11)
        XCTAssertTrue(second.state.sent.isEmpty, "the baseline covers the sent image")
    }

    func testAnUnsentImageIsTriedAgain() {
        let state = CaptureState().enable(.photo, newest: 10)
        let items = [photo(11), photo(12)]
        let first = planCapture(state, items: items, now: now)
        // No computer took 11. Only 12 went out.
        let second = planCapture(first.state.markSent(12), items: items, now: now)
        XCTAssertEqual(second.send.map(\.item.id), [11])
        XCTAssertEqual(second.state.baseline, 10)
    }

    func testAPendingImageWaits() {
        let state = CaptureState().enable(.photo, newest: 10)
        let pending = planCapture(state, items: [photo(11, pending: true), other(12)], now: now)
        XCTAssertTrue(pending.send.isEmpty)
        XCTAssertEqual(pending.state.baseline, 10, "the pending image stops the baseline")
        let done = planCapture(pending.state, items: [photo(11), other(12)], now: now)
        XCTAssertEqual(done.send.map(\.item.id), [11])
    }

    func testAnOldPendingImageDoesNotBlock() {
        let state = CaptureState().enable(.photo, newest: 10)
        let old = now - CaptureRules.pendingLimit - 1
        let plan = planCapture(state, items: [photo(11, pending: true, added: old), other(12)], now: now)
        XCTAssertEqual(plan.state.baseline, 12)
    }

    func testASecondSwitchStartsAtItsOwnTime() {
        var state = CaptureState().enable(.photo, newest: 10)
        state = state.enable(.screenshot, newest: 20)
        let plan = planCapture(state, items: [shot(15), shot(21)], now: now)
        XCTAssertEqual(plan.send.map(\.item.id), [21])
    }

    func testTurningAllOffAndOnSkipsTheGap() {
        var state = CaptureState().enable(.photo, newest: 10).disable(.photo)
        state = state.enable(.photo, newest: 50)
        XCTAssertEqual(state.baseline, 50)
        let plan = planCapture(state, items: [photo(30), photo(51)], now: now)
        XCTAssertEqual(plan.send.map(\.item.id), [51])
    }

    func testTheSentSetKeepsTheNewestIDs() {
        var state = CaptureState().enable(.photo, newest: 10)
        // Item 11 waits, so every sent ID stays after the baseline.
        for id in Int64(12)...Int64(12 + maxCaptureSent) { state = state.markSent(id) }
        let plan = planCapture(state, items: [photo(11, pending: true)], now: now)
        XCTAssertEqual(plan.state.sent.count, maxCaptureSent)
        XCTAssertFalse(plan.state.sent.contains(12), "the oldest ID goes first")
        XCTAssertTrue(plan.state.sent.contains(Int64(12 + maxCaptureSent)))
    }

    func testStateSurvivesARestart() throws {
        let state = CaptureState().enable(.screenshot, newest: 10).enable(.photo, newest: 20).markSent(11)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(CaptureState.self, from: data), state)
    }
}
