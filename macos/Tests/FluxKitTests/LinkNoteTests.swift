import XCTest
@testable import FluxKit

/// Ported from LinkNoteTest.kt of the Android app, with the same vectors.
/// It covers AC91 and AC92.
final class LinkNoteTests: XCTestCase {
    private let time: (Date) -> String = { _ in "14:02" }
    private let minute: TimeInterval = 60

    /// The Kotlin vectors use milliseconds.
    private func ms(_ v: Double) -> Date { Date(timeIntervalSince1970: v / 1000) }

    func testAClosedLinkSaysThatTheComputerIsNotReachableAndWhenTheOutputIsFrom() throws {
        let n = try XCTUnwrap(LinkNote.threadNote(online: false, connecting: false, name: "omarchy-xps", outputAt: ms(5_000), now: ms(9_000_000), time: time))
        XCTAssertEqual(n.state, .unreachable)
        XCTAssertEqual(n.title, "omarchy-xps is not reachable.")
        XCTAssertEqual(n.detail, "This output is from 14:02.")
    }

    func testAClosedLinkWithNoKnownTimeHasNoSecondLine() throws {
        let n = try XCTUnwrap(LinkNote.threadNote(online: false, connecting: false, name: "omarchy-xps", outputAt: nil, now: ms(9_000), time: time))
        XCTAssertEqual(n.title, "omarchy-xps is not reachable.")
        XCTAssertEqual(n.detail, "")
    }

    func testAComputerThatConnectsShowsTheConnectingLine() throws {
        let n = try XCTUnwrap(LinkNote.threadNote(online: false, connecting: true, name: "omarchy-xps", outputAt: ms(5_000), now: ms(9_000), time: time))
        XCTAssertEqual(n.state, .connecting)
        XCTAssertEqual(n.title, "Connecting to omarchy-xps")
        XCTAssertEqual(n.detail, "")
    }

    func testAnOpenLinkShowsTheTimeAndTheAgeOfTheOutput() throws {
        let n = try XCTUnwrap(LinkNote.threadNote(online: true, connecting: false, name: "omarchy-xps", outputAt: ms(1_000), now: ms(31_000), time: time))
        XCTAssertEqual(n.state, .connected)
        XCTAssertEqual(n.title, "Output from 14:02")
        XCTAssertEqual(n.detail, "now")
        let later = try XCTUnwrap(LinkNote.threadNote(online: true, connecting: false, name: "omarchy-xps", outputAt: ms(1_000), now: ms(1_000 + 3 * minute * 1000), time: time))
        XCTAssertEqual(later.detail, "3m")
    }

    func testAnOpenLinkWithNoOutputHasNoNote() {
        XCTAssertNil(LinkNote.threadNote(online: true, connecting: false, name: "omarchy-xps", outputAt: nil, now: ms(9_000), time: time))
    }

    func testAnOpenLinkWinsOverTheConnectingFlag() throws {
        let n = try XCTUnwrap(LinkNote.threadNote(online: true, connecting: true, name: "omarchy-xps", outputAt: ms(1_000), now: ms(2_000), time: time))
        XCTAssertEqual(n.state, .connected)
    }

    func testTheAgeGrowsInSteps() {
        XCTAssertEqual(LinkNote.age(59.999), "now")
        XCTAssertEqual(LinkNote.age(minute), "1m")
        XCTAssertEqual(LinkNote.age(59 * minute), "59m")
        XCTAssertEqual(LinkNote.age(60 * minute), "1h")
        XCTAssertEqual(LinkNote.age(23 * 60 * minute), "23h")
        XCTAssertEqual(LinkNote.age(48 * 60 * minute), "2d")
        XCTAssertEqual(LinkNote.age(-0.005), "now", "a clock that moves back gives now")
    }

    func testARowOfAComputerThatIsNotReachableShowsSince() {
        XCTAssertEqual(LinkNote.rowLine(online: false, lastSeen: ms(5_000), time: time), "Not reachable since 14:02")
        XCTAssertEqual(LinkNote.rowLine(online: false, lastSeen: nil, time: time), "Not reachable")
        XCTAssertNil(LinkNote.rowLine(online: true, lastSeen: ms(5_000), time: time))
    }

    func testTheClockIsHoursAndMinutes() {
        XCTAssertEqual(LinkNote.clock(Date(timeIntervalSince1970: 0)).count, 5)
    }
}
