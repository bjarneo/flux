import XCTest
@testable import FluxKit

/// Ported from ThemeBookTest.kt of the Android app.
final class ThemeBookTests: XCTestCase {
    private let a = SampleThemes.neon
    private let b = SampleThemes.catppuccinLatte
    private let b2 = SampleThemes.cottonCandy

    private func lastTheme(_ book: ThemeBook) -> OmarchyTheme? { book.current(scope: nil)?.theme }

    func testTheFirstThemeBecomesTheLastTheme() {
        var book = ThemeBook()
        XCTAssertNil(book.current(scope: nil))
        XCTAssertTrue(book.put("A", a))
        XCTAssertEqual(book.lastId, "A")
        XCTAssertEqual(lastTheme(book), a)
        XCTAssertEqual(book.current(scope: nil)?.palette, ThemePalette.of(a))
        XCTAssertEqual(book.theme("A")?.deviceId, "A")
    }

    func testAReconnectWithTheSameThemeKeepsTheLastTheme() {
        var book = ThemeBook()
        book.put("A", a)
        // B sends its first theme. It does not take the place of the theme of A.
        XCTAssertTrue(book.put("B", b))
        XCTAssertEqual(lastTheme(book), a)
        // Both computers connect again in turns, with the same themes.
        for _ in 0..<3 {
            XCTAssertFalse(book.put("A", a))
            XCTAssertFalse(book.put("B", b))
            XCTAssertEqual(lastTheme(book), a)
            XCTAssertFalse(book.put("B", b))
            XCTAssertFalse(book.put("A", a))
            XCTAssertEqual(lastTheme(book), a)
        }
        // The theme on B changes, so B has the last theme.
        XCTAssertTrue(book.put("B", b2))
        XCTAssertEqual(lastTheme(book), b2)
        // A connects again with the same theme. The last theme stays.
        XCTAssertFalse(book.put("A", a))
        XCTAssertEqual(lastTheme(book), b2)
        XCTAssertEqual(book.names(), ["A": "neon", "B": "cotton-candy"])
    }

    func testTheComputerWithTheLastThemeCanChangeItAgain() {
        var book = ThemeBook()
        book.put("A", a)
        book.put("B", b)
        XCTAssertTrue(book.put("A", b2))
        XCTAssertEqual(book.lastId, "A")
        XCTAssertEqual(lastTheme(book), b2)
    }

    func testAColdStartRestoresTheBook() {
        var first = ThemeBook()
        first.put("A", a)
        first.put("B", b)
        first.put("B", b2)
        let saved = JSONValue.parse(first.json().serialized())
        XCTAssertNotNil(saved)

        var next = ThemeBook()
        next.load(saved)
        XCTAssertEqual(next.lastId, "B")
        XCTAssertEqual(lastTheme(next), b2)
        XCTAssertEqual(first.current(scope: nil), next.current(scope: nil))
        XCTAssertEqual(first.names(), next.names())
        // The computers connect after the cold start and send the same themes.
        XCTAssertFalse(next.put("A", a))
        XCTAssertFalse(next.put("B", b2))
        XCTAssertEqual(lastTheme(next), b2)
    }

    func testAnUnpairOfTheLastComputerTakesTheNextTheme() {
        var book = ThemeBook()
        book.put("A", a)
        book.put("B", b)
        book.put("B", b2)
        XCTAssertFalse(book.forget("C"))
        XCTAssertTrue(book.forget("B"))
        XCTAssertEqual(book.lastId, "A")
        XCTAssertEqual(lastTheme(book), a)
        XCTAssertTrue(book.forget("A"))
        XCTAssertNil(book.lastId)
        XCTAssertNil(book.current(scope: nil))
        XCTAssertTrue(book.names().isEmpty)
    }

    func testAnUnpairOfAnotherComputerKeepsTheLastTheme() {
        var book = ThemeBook()
        book.put("A", a)
        book.put("B", b)
        XCTAssertTrue(book.forget("B"))
        XCTAssertEqual(lastTheme(book), a)
    }

    func testAScopeShowsOnlyTheThemeOfThatComputer() {
        var book = ThemeBook()
        book.put("A", a)
        book.put("B", b)
        XCTAssertEqual(book.current(scope: "A")?.theme, a)
        XCTAssertEqual(book.current(scope: "B")?.theme, b)
        // C sent no theme. The app does not draw the theme of another computer for it.
        XCTAssertNil(book.current(scope: "C"))
        XCTAssertEqual(book.current(scope: nil)?.theme, a)
    }

    func testALoadKeepsOnlyThePairedComputers() {
        var first = ThemeBook()
        first.put("A", a)
        first.put("B", b)
        first.put("B", b2)
        var next = ThemeBook()
        next.load(first.json(), keep: { $0 == "A" })
        XCTAssertEqual(next.lastId, "A")
        XCTAssertNil(next.current(scope: "B"))
        XCTAssertEqual(Set(next.names().keys), ["A"])
    }

    func testALoadIgnoresWhatItCannotRead() {
        var book = ThemeBook()
        book.put("A", a)
        book.load(nil)
        XCTAssertNil(book.current(scope: nil))
        let broken = JSONValue.parse(Data(##"""
        {"last":"X","computers":[{"theme":{"colors":{"background":"#000000"}}},
        {"id":"B","theme":{"colors":{}}},{"id":"C","theme":"red"},
        {"id":"D","theme":{"name":"bare","colors":{"background":"#101010"}}}]}
        """##.utf8))
        XCTAssertNotNil(broken)
        book.load(broken)
        XCTAssertEqual(Set(book.names().keys), ["D"])
        // The saved last computer is not in the book, so the last entry takes its place.
        XCTAssertEqual(book.lastId, "D")
    }
}
