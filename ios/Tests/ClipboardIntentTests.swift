import FluxKit
import XCTest
@testable import Flux

final class ClipboardIntentTests: XCTestCase {
    func testTheTextCheck() {
        XCTAssertEqual(ClipboardIntentText.check("hello", skipUnchanged: false, unchanged: false), .send)
        XCTAssertEqual(ClipboardIntentText.check("", skipUnchanged: false, unchanged: false), .empty)
        XCTAssertEqual(ClipboardIntentText.check(" \n\t", skipUnchanged: false, unchanged: false), .empty, "spaces only are no text")
        XCTAssertEqual(ClipboardIntentText.check(String(repeating: "x", count: SharePlugin.maxText), skipUnchanged: false, unchanged: false), .send)
        XCTAssertEqual(ClipboardIntentText.check(String(repeating: "x", count: SharePlugin.maxText + 1), skipUnchanged: false, unchanged: false), .tooLarge,
                       "the computer takes at most 1 MB")
    }

    func testSkipUnchangedText() {
        XCTAssertEqual(ClipboardIntentText.check("hello", skipUnchanged: true, unchanged: true), .unchanged,
                       "an automation does not send the last text again")
        XCTAssertEqual(ClipboardIntentText.check("hello", skipUnchanged: false, unchanged: true), .send, "a tap always sends")
        XCTAssertEqual(ClipboardIntentText.check("hello", skipUnchanged: true, unchanged: false), .send)
        XCTAssertEqual(ClipboardIntentText.check(" ", skipUnchanged: true, unchanged: true), .empty)
    }

    /// iOS starts Flux in the background for Send Text to Computer. The
    /// links start and stay while the action runs, and close after it.
    @MainActor
    func testAnIntentKeepsTheLinksUntilItEnds() async throws {
        let model = try TestApp.model()
        XCTAssertFalse(FeatureHooks.runsInBackground(model: model))
        let ids = await model.withBackgroundLink(timeout: .milliseconds(300)) { ids -> [String] in
            XCTAssertTrue(model.core.isRunning, "the action starts the links in the background")
            XCTAssertTrue(FeatureHooks.runsInBackground(model: model), "the links do not close in the middle of the action")
            return ids
        }
        XCTAssertEqual(ids, [], "no computer is paired")
        XCTAssertEqual(model.intentsRunning, 0)
        XCTAssertFalse(FeatureHooks.runsInBackground(model: model))
        XCTAssertFalse(model.core.isRunning, "the links close again, because Flux is not on the screen")
    }
}
