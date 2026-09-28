import FluxKit
import XCTest
@testable import Flux

final class ApproveLogicTests: XCTestCase {
    func testSheetShowsEachNewRequest() {
        var p = ApprovePresentation()
        XCTAssertFalse(p.isPresented, "no request, no sheet")
        p.shownChanged("a")
        XCTAssertTrue(p.isPresented)
        XCTAssertFalse(p.dismissed(open: true), "a swipe hides a waiting request")
        XCTAssertFalse(p.isPresented)
        p.shownChanged("a")
        XCTAssertFalse(p.isPresented, "the same request stays hidden")
        p.present()
        XCTAssertTrue(p.isPresented, "the banner or the notification shows it again")
        _ = p.dismissed(open: true)
        p.shownChanged("b")
        XCTAssertTrue(p.isPresented, "a new request shows even after a swipe")
        p.shownChanged(nil)
        XCTAssertFalse(p.isPresented, "the sheet closes when the request ends")
        p.present()
        XCTAssertFalse(p.isPresented, "a tap on an old notification shows nothing")
    }

    func testSwipeClosesAResult() {
        var p = ApprovePresentation()
        p.shownChanged("a")
        XCTAssertTrue(p.dismissed(open: false), "the key code or the failure closes, because no banner brings it back")
        var none = ApprovePresentation()
        XCTAssertFalse(none.dismissed(open: false))
    }

    func testCountdown() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(ApproveCountdown.secondsLeft(until: now.addingTimeInterval(20), now: now), 20)
        XCTAssertEqual(ApproveCountdown.secondsLeft(until: now.addingTimeInterval(19.2), now: now), 20, "it rounds up, so 0 shows only at the end")
        XCTAssertEqual(ApproveCountdown.secondsLeft(until: now.addingTimeInterval(-3), now: now), 0)
        XCTAssertEqual(ApproveCountdown.fractionLeft(until: now.addingTimeInterval(20), total: 20, now: now), 1)
        XCTAssertEqual(ApproveCountdown.fractionLeft(until: now.addingTimeInterval(5), total: 20, now: now), 0.25)
        XCTAssertEqual(ApproveCountdown.fractionLeft(until: now.addingTimeInterval(-1), total: 20, now: now), 0)
        XCTAssertEqual(ApproveCountdown.fractionLeft(until: now.addingTimeInterval(30), total: 20, now: now), 1, "a late clock never overfills")
        XCTAssertEqual(ApproveCountdown.fractionLeft(until: now, total: 0, now: now), 0)
    }

    func testTileSubtitles() {
        XCTAssertEqual(ApproveTile.subtitle(user: "alice", waiting: true, availability: .ready), "A request waits")
        XCTAssertEqual(ApproveTile.subtitle(user: "alice", waiting: false, availability: .ready), "Enrolled for alice")
        XCTAssertEqual(ApproveTile.subtitle(user: nil, waiting: false, availability: .noSecureEnclave("x")), "Not available on this iPhone")
        XCTAssertEqual(ApproveTile.subtitle(user: nil, waiting: false, availability: .biometry("x")), "Approve sudo on the computer")
        XCTAssertEqual(ApproveTile.subtitle(user: nil, waiting: false, availability: .ready), "Approve sudo on the computer")
    }
}
