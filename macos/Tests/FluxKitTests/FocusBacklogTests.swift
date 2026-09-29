import XCTest
@testable import FluxKit

final class FocusBacklogTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "flux-focus-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testTheFirstStateIsTheStart() throws {
        let b = FocusBacklog(defaults: try makeDefaults())
        XCTAssertFalse(b.report(true), "the first state is the start value")
        XCTAssertFalse(b.report(true), "the same state is not a change")
        XCTAssertNil(b.take(for: "a"), "no change waits")
    }

    func testAChangeWaitsForEachComputer() throws {
        let b = FocusBacklog(defaults: try makeDefaults())
        _ = b.report(false)
        XCTAssertTrue(b.report(true), "a change while no computer is connected")
        XCTAssertEqual(b.take(for: "a"), true, "the computer gets the change when it connects")
        XCTAssertNil(b.take(for: "a"), "a computer gets a change once")
        XCTAssertEqual(b.take(for: "b"), true, "each computer gets the change")
    }

    func testComputersThatGotTheChangeGetNoCopy() throws {
        let b = FocusBacklog(defaults: try makeDefaults())
        _ = b.report(false)
        _ = b.report(true)
        b.reached(["a"], on: true)
        XCTAssertNil(b.take(for: "a"), "the change went to the connected computer")
        b.reached(["b"], on: false)
        XCTAssertEqual(b.take(for: "b"), true, "a report for an older state does not count")
    }

    func testANewChangeReplacesTheOldOne() throws {
        let b = FocusBacklog(defaults: try makeDefaults())
        _ = b.report(false)
        _ = b.report(true)
        XCTAssertEqual(b.take(for: "a"), true)
        XCTAssertTrue(b.report(false))
        XCTAssertEqual(b.take(for: "a"), false, "the newest state goes out")
    }

    func testTheChangeOutlivesFlux() throws {
        let defaults = try makeDefaults()
        let before = FocusBacklog(defaults: defaults)
        _ = before.report(false)
        _ = before.report(true)
        let after = FocusBacklog(defaults: defaults)
        XCTAssertFalse(after.report(true), "the state at the next launch equals the last one")
        XCTAssertEqual(after.take(for: "a"), true, "iOS can end Flux before a computer connects")
    }

    func testAChangeWhileFluxDidNotRun() throws {
        let defaults = try makeDefaults()
        _ = FocusBacklog(defaults: defaults).report(false)
        let next = FocusBacklog(defaults: defaults)
        XCTAssertTrue(next.report(true), "a new state at launch is a change")
        XCTAssertEqual(next.take(for: "a"), true)
    }

    func testNoChangeWaitsWhileTheSyncIsOff() throws {
        let b = FocusBacklog(defaults: try makeDefaults())
        _ = b.report(false)
        _ = b.report(true)
        XCTAssertFalse(b.report(false, keep: false))
        XCTAssertNil(b.take(for: "a"), "the sync is off, so the change goes nowhere")
        XCTAssertFalse(b.report(false), "the state was recorded")
    }
}
