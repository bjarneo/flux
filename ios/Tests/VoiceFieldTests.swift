import FluxKit
import XCTest
@testable import Flux

/// The text rules of the mic keys of the text fields.
final class VoiceFieldTests: XCTestCase {
    func testAppendsTheWordsAtTheEnd() {
        XCTAssertEqual(DictationText.append("", "hello there"), "Hello there")
        XCTAssertEqual(DictationText.append("See", "the link"), "See the link")
        XCTAssertEqual(DictationText.append("Done.", "next one"), "Done. Next one")
        XCTAssertEqual(DictationText.append("cd ~/Code &&", DictationText.command("Git status."), sentences: false), "cd ~/Code && git status")
    }

    func testSpacesDictationsOnTheComputer() {
        var spacing = SpokenSpacing()
        XCTAssertEqual(spacing.text(" Hello "), "Hello")
        XCTAssertEqual(spacing.text("world"), " world", "a dictation right after another starts with a space")
        XCTAssertNil(spacing.text("  "), "no words type nothing")
        spacing.moved()
        XCTAssertEqual(spacing.text("again"), "again", "after a key or a click, no space")
    }
}
