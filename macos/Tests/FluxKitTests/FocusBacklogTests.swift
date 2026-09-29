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
        XCTAssertFalse(b.report(true, paired: ["a"]), "the first state is the start value")
        XCTAssertFalse(b.report(true, paired: ["a"]), "the same state is not a change")
        XCTAssertNil(b.take(for: "a"), "no change waits")
    }

    func testAChangeWaitsForEachComputer() throws {
        let b = FocusBacklog(defaults: try makeDefaults())
        _ = b.report(false, paired: ["a", "b"])
        XCTAssertTrue(b.report(true, paired: ["a", "b"]), "a change while no computer is connected")
        XCTAssertEqual(b.take(for: "a"), true, "the computer gets the change when it connects")
        XCTAssertNil(b.take(for: "a"), "a computer gets a change once")
        XCTAssertEqual(b.take(for: "b"), true, "each computer gets the change")
    }

    func testAComputerThatPairsLaterGetsNoChange() throws {
        let defaults = try makeDefaults()
        let b = FocusBacklog(defaults: defaults)
        _ = b.report(false, paired: ["a"])
        _ = b.report(true, paired: ["a"])
        XCTAssertNil(b.take(for: "c"), "a computer that was not paired at the change gets nothing at pairing")
        XCTAssertEqual(b.take(for: "a"), true)
        XCTAssertNil(defaults.object(forKey: FocusBacklog.unsentKey), "the change is gone after each computer got it")
        XCTAssertNil(b.take(for: "d"))
    }

    func testAChangeWithNoPairedComputerWaitsForNothing() throws {
        let b = FocusBacklog(defaults: try makeDefaults())
        _ = b.report(false, paired: [])
        XCTAssertTrue(b.report(true, paired: []))
        XCTAssertNil(b.take(for: "a"), "the first computer that pairs later gets nothing")
    }

    func testComputersThatGotTheChangeGetNoCopy() throws {
        let defaults = try makeDefaults()
        let b = FocusBacklog(defaults: defaults)
        _ = b.report(false, paired: ["a", "b"])
        _ = b.report(true, paired: ["a", "b"])
        b.reached(["a"], on: true)
        XCTAssertNil(b.take(for: "a"), "the change went to the connected computer")
        b.reached(["b"], on: false)
        XCTAssertEqual(b.take(for: "b"), true, "a report for an older state does not count")
        _ = b.report(false, paired: ["a", "b"])
        b.reached(["a", "b"], on: false)
        XCTAssertNil(defaults.object(forKey: FocusBacklog.unsentKey), "the change is gone when each computer got it at once")
    }

    func testAnUnpairedComputerStopsItsWait() throws {
        let b = FocusBacklog(defaults: try makeDefaults())
        _ = b.report(false, paired: ["a", "b"])
        _ = b.report(true, paired: ["a", "b"])
        b.forget("a")
        XCTAssertNil(b.take(for: "a"), "a computer that pairs again gets no old change")
        XCTAssertEqual(b.take(for: "b"), true, "the other computers still wait")
    }

    func testANewChangeReplacesTheOldOne() throws {
        let b = FocusBacklog(defaults: try makeDefaults())
        _ = b.report(false, paired: ["a"])
        _ = b.report(true, paired: ["a"])
        XCTAssertEqual(b.take(for: "a"), true)
        XCTAssertTrue(b.report(false, paired: ["a"]))
        XCTAssertEqual(b.take(for: "a"), false, "the newest state goes out")
    }

    func testTheChangeOutlivesFlux() throws {
        let defaults = try makeDefaults()
        let before = FocusBacklog(defaults: defaults)
        _ = before.report(false, paired: ["a"])
        _ = before.report(true, paired: ["a"])
        let after = FocusBacklog(defaults: defaults)
        XCTAssertFalse(after.report(true, paired: ["a"]), "the state at the next launch equals the last one")
        XCTAssertEqual(after.take(for: "a"), true, "iOS can end Flux before a computer connects")
    }

    func testAChangeWhileFluxDidNotRun() throws {
        let defaults = try makeDefaults()
        _ = FocusBacklog(defaults: defaults).report(false, paired: ["a"])
        let next = FocusBacklog(defaults: defaults)
        XCTAssertTrue(next.report(true, paired: ["a"]), "a new state at launch is a change")
        XCTAssertEqual(next.take(for: "a"), true)
    }

    func testNoChangeWaitsWhileTheSyncIsOff() throws {
        let b = FocusBacklog(defaults: try makeDefaults())
        _ = b.report(false, paired: ["a"])
        _ = b.report(true, paired: ["a"])
        XCTAssertFalse(b.report(false, paired: ["a"], keep: false))
        XCTAssertNil(b.take(for: "a"), "the sync is off, so the change goes nowhere")
        XCTAssertFalse(b.report(false, paired: ["a"]), "the state was recorded")
    }
}
