import XCTest
@testable import FluxKit

/// Ported from DictationTextTest.kt and LanguageCatalogTest.kt of the
/// Android app. The Mac has no model downloads, so the catalog tests use
/// the on-device and the other languages.
final class DictationTests: XCTestCase {
    func testInsertsIntoAnEmptyField() {
        XCTAssertEqual(DictationText.insert("", start: 0, end: 0, spoken: " run the tests "), DictationEdit("Run the tests", 13))
    }

    func testAddsASpaceAfterAWord() {
        XCTAssertEqual(DictationText.insert("Fix the bug", start: 11, end: 11, spoken: "in parser.go"), DictationEdit("Fix the bug in parser.go", 24))
        XCTAssertEqual(DictationText.insert("Fix it ", start: 7, end: 7, spoken: "now"), DictationEdit("Fix it now", 10), "a space after the text stays one space")
    }

    func testCapitalizesANewSentence() {
        XCTAssertEqual(DictationText.insert("Done.", start: 5, end: 5, spoken: "now run it"), DictationEdit("Done. Now run it", 16))
        XCTAssertEqual(DictationText.insert("Why? ", start: 5, end: 5, spoken: "check the log"), DictationEdit("Why? Check the log", 18))
        XCTAssertEqual(DictationText.insert("First line\n", start: 11, end: 11, spoken: "second line"), DictationEdit("First line\nSecond line", 22))
        XCTAssertEqual(DictationText.insert("Use the", start: 7, end: 7, spoken: "go test"), DictationEdit("Use the go test", 15), "inside a sentence the case stays")
    }

    func testMakesASearchFromADictation() {
        XCTAssertEqual(DictationText.query(" Workspace. "), "Workspace")
        XCTAssertEqual(DictationText.query("Open the browser?!"), "Open the browser")
        XCTAssertEqual(DictationText.query("node.js"), "node.js", "a period inside the words stays")
        XCTAssertEqual(DictationText.query(" . "), "")
    }

    func testInsertsAtTheCursor() {
        // "Run tests" with the cursor after "Run".
        XCTAssertEqual(DictationText.insert("Run tests", start: 3, end: 3, spoken: "the unit"), DictationEdit("Run the unit tests", 12))
    }

    func testReplacesTheSelection() {
        XCTAssertEqual(DictationText.insert("Run the tests", start: 8, end: 13, spoken: "lint check"), DictationEdit("Run the lint check", 18))
        XCTAssertEqual(DictationText.insert("Run the tests", start: 13, end: 8, spoken: "lint check"), DictationEdit("Run the lint check", 18), "a reversed selection works")
    }

    func testKeepsPunctuationAgainstTheWord() {
        XCTAssertEqual(DictationText.insert("Stop, then wait", start: 4, end: 4, spoken: "here"), DictationEdit("Stop here, then wait", 9))
        XCTAssertEqual(DictationText.insert("Yes", start: 3, end: 3, spoken: ", please"), DictationEdit("Yes, please", 11))
    }

    func testIgnoresEmptySpeechAndBadPositions() {
        XCTAssertEqual(DictationText.insert("keep", start: 4, end: 4, spoken: "   "), DictationEdit("keep", 4))
        XCTAssertEqual(DictationText.insert("keep", start: 40, end: 50, spoken: "it"), DictationEdit("keep it", 7))
    }

    func testCountsTheCursorInUTF16() {
        // An emoji takes 2 UTF-16 units, as in the selection of a text view.
        XCTAssertEqual(DictationText.insert("Ship it 🚀", start: 10, end: 10, spoken: "now"), DictationEdit("Ship it 🚀 now", 14))
    }

    func testJoinsSessions() {
        XCTAssertEqual(DictationText.join("one ", " two"), "one two")
        XCTAssertEqual(DictationText.join("", "two"), "two")
        XCTAssertEqual(DictationText.join("one", "  "), "one")
    }

    func testMapsLevels() {
        XCTAssertEqual(DictationText.level(decibels: -50), 0)
        XCTAssertEqual(DictationText.level(decibels: -90), 0)
        XCTAssertEqual(DictationText.level(decibels: -12), 1)
        XCTAssertEqual(DictationText.level(decibels: 0), 1)
        XCTAssertEqual(DictationText.level(decibels: .nan), 0)
        XCTAssertGreaterThan(DictationText.level(decibels: -40), 0.45, "quiet speech shows")
    }

    func testFormatsTheClock() {
        XCTAssertEqual(DictationText.clock(0), "0:00")
        XCTAssertEqual(DictationText.clock(7.9), "0:07")
        XCTAssertEqual(DictationText.clock(750), "12:30")
        XCTAssertEqual(DictationText.clock(-5), "0:00")
    }

    func testMergesNewWords() {
        XCTAssertEqual(DictationText.merge("Run the tests", "and fix lint"), "Run the tests and fix lint")
        XCTAssertEqual(DictationText.merge("", " fix lint "), "fix lint")
        XCTAssertEqual(DictationText.merge("Run the tests", "  "), "Run the tests")
    }

    func testMergesTheWholeTextAgain() {
        // A recognizer can send the whole text with each final text, with new case and punctuation.
        XCTAssertEqual(DictationText.merge("run the tests", "Run the tests, then fix lint."), "Run the tests, then fix lint.")
        XCTAssertEqual(DictationText.merge("Run the tests.", "Run the tests."), "Run the tests.")
    }

    func testDropsARepeatedText() {
        XCTAssertEqual(DictationText.merge("Please check it. Fix it now", "fix it now."), "Please check it. Fix it now")
        XCTAssertEqual(DictationText.merge("Say yes", "yes"), "Say yes yes", "a repeated single word can be real speech")
    }

    func testFindsTheUnsettledWords() {
        XCTAssertEqual(DictationText.unsettled("Run the tests.", "run the tests and fix"), "and fix")
        XCTAssertEqual(DictationText.unsettled("Run the tests.", "and fix"), "and fix")
        XCTAssertEqual(DictationText.unsettled("", " hello "), "hello")
        XCTAssertEqual(DictationText.unsettled("Run the tests.", "run the tests"), "")
    }

    func testFindsARestartedText() {
        XCTAssertTrue(DictationText.restarted(previous: "Run the tests", next: "And"), "new words after a pause")
        XCTAssertFalse(DictationText.restarted(previous: "Run the tests", next: "Run the tests and"))
        XCTAssertFalse(DictationText.restarted(previous: "Ron the tests", next: "Run the tests"), "a revision keeps the length")
        XCTAssertFalse(DictationText.restarted(previous: "Run the", next: "Run"), "a revision keeps the first word")
        XCTAssertFalse(DictationText.restarted(previous: "Run", next: "And"), "1 word is too short to tell")
        XCTAssertFalse(DictationText.restarted(previous: "", next: "Run"))
    }

    func testSplitsWords() {
        XCTAssertEqual(DictationText.words("  one two\n three "), ["one", "two", "three"])
        XCTAssertEqual(DictationText.words("   "), [])
    }

    func testCleansTheMacLanguages() {
        XCTAssertEqual(DictationText.languages(["nb-NO", " en_GB", "", "und", "en-US", "en-GB"]), ["nb-NO", "en-GB", "en-US"])
        XCTAssertEqual(DictationText.languages(["und"]), [])
    }

    func testNamesLanguages() {
        XCTAssertEqual(DictationText.languageName("en-GB"), "English (United Kingdom)")
        XCTAssertEqual(DictationText.languageName("en"), "English")
        XCTAssertEqual(DictationText.languageName("und"), "und", "an undefined tag keeps its text")
        let none = DictationText.unsupported(["en-GB", "de-DE"])
        XCTAssertTrue(none.contains("English (United Kingdom), German (Germany)"), none)
        XCTAssertTrue(DictationText.notSupported("de-DE").contains("German (Germany)"))
    }

    func testNamesErrors() {
        XCTAssertTrue(DictationText.isSilence(domain: "kAFAssistantErrorDomain", code: 1110))
        XCTAssertFalse(DictationText.isSilence(domain: "kAFAssistantErrorDomain", code: 203))
        XCTAssertTrue(DictationText.message(domain: NSURLErrorDomain, code: -1009, description: "offline").contains("network"))
        XCTAssertTrue(DictationText.message(domain: "kLSRErrorDomain", code: 99, description: "Failed").contains("99"))
    }

    // MARK: Languages

    private let mac = ["nb-NO", "en-GB", "en-US"]

    func testOrdersTheSections() {
        let rows = LanguageCatalog.rows(
            onDevice: ["en-US", "de-DE", "en-GB"],
            supported: ["it-IT", "en-US", "fr-FR", "es-ES", "de-DE"],
            preferred: mac,
            query: ""
        )
        // The Mac languages come first in their settings order, then the other languages by name.
        XCTAssertEqual(rows.map(\.tag), ["en-GB", "en-US", "de-DE", "fr-FR", "it-IT", "es-ES"])
        XCTAssertEqual(rows.map(\.onDevice), [true, true, true, false, false, false])
    }

    func testRanksALanguageOfTheSameCode() {
        // A Mac language with the region of the Mac, such as en-NO, ranks the other English languages.
        let rows = LanguageCatalog.rows(onDevice: ["de-DE", "en-US"], supported: [], preferred: ["en-NO"], query: "")
        XCTAssertEqual(rows.map(\.tag), ["en-US", "de-DE"])
    }

    func testFindsByNameOwnNameAndTag() {
        let rows = { (q: String) in LanguageCatalog.rows(onDevice: ["en-US"], supported: ["de-DE", "fr-FR", "ja-JP"], preferred: self.mac, query: q).map(\.tag) }
        XCTAssertEqual(rows("germ"), ["de-DE"])
        XCTAssertEqual(rows("DEUTSCH"), ["de-DE"])
        XCTAssertEqual(rows(" fr-fr "), ["fr-FR"])
        XCTAssertEqual(rows("klingon"), [])
        XCTAssertEqual(rows("").count, 4)
    }

    func testNamesTheLanguage() throws {
        let row = try XCTUnwrap(LanguageCatalog.rows(onDevice: [], supported: ["de-DE"], preferred: mac, query: "").first)
        XCTAssertEqual(row.name, "German (Germany)")
        XCTAssertEqual(row.native, "Deutsch (Deutschland)")
        XCTAssertEqual(LanguageCatalog.nativeName("nb-NO"), "Norsk bokmål (Norge)", "the own name starts with a capital")
    }

    func testChoosesTheAutomaticLanguage() {
        XCTAssertEqual(LanguageCatalog.automatic(preferred: mac, available: ["en-US", "en-GB"]), "en-GB")
        XCTAssertNil(LanguageCatalog.automatic(preferred: ["nb-NO"], available: ["en-US"]))
    }

    func testMatchesTheLanguageOfTheMacRegion() {
        let english = ["en-AU", "en-GB", "en-US"]
        XCTAssertEqual(LanguageCatalog.match("en-NO", in: english), "en-US", "the most likely region of English")
        XCTAssertEqual(LanguageCatalog.match("en-NO", in: english, fallback: "en-GB"), "en-GB", "the language of the default recognizer")
        XCTAssertEqual(LanguageCatalog.match("en_gb", in: english), "en-GB")
        XCTAssertEqual(LanguageCatalog.match("zh-Hans-NO", in: ["zh-HK", "zh-TW", "zh-CN"]), "zh-CN")
        XCTAssertEqual(LanguageCatalog.match("de", in: ["de-CH", "de-AT"]), "de-AT", "no likely region: the first by tag")
        XCTAssertNil(LanguageCatalog.match("nb-NO", in: english))
        XCTAssertEqual(LanguageCatalog.automatic(preferred: ["nb-NO", "en-NO"], available: english, fallback: "en-GB"), "en-GB")
    }
}
