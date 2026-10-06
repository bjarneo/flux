import XCTest
@testable import FluxKit

/// The screen layout of output lines: wrapping, fills, panel bars, and block elements.
final class TermRowLayoutTests: XCTestCase {
    private func wrap(_ s: String, cols: Int, hang: Int = 0) -> [String] {
        let chars = Array(s)
        return TermRowLayout.wrap(chars, cols: cols, hang: hang).map { String(chars[$0]) }
    }

    func testWrapsAtBlanks() {
        XCTAssertEqual(wrap("short", cols: 10), ["short"])
        XCTAssertEqual(wrap("", cols: 10), [""], "an empty line keeps 1 row")
        XCTAssertEqual(wrap("one two three four five", cols: 10), ["one two ", "three four", "five"])
        XCTAssertEqual(wrap("abcdefghijklmn", cols: 5), ["abcde", "fghij", "klmn"], "a long word breaks at the edge")
        XCTAssertEqual(wrap("abcde   fgh", cols: 5), ["abcde", "fgh"], "the blanks at a break between words go")
    }

    func testWrappedRowsStartAtTheHang() {
        // The wrapped rows are cols - hang wide.
        XCTAssertEqual(wrap("┃  aaaa bbbb cccc", cols: 10, hang: 3), ["┃  aaaa ", "bbbb ", "cccc"])
        let layout = TermRowLayout(TermLine([TermSpan("┃  aaaa bbbb cccc")]), cols: 10)
        XCTAssertEqual(layout.hang, 3)
        XCTAssertEqual(layout.place(8)?.row, 1)
        XCTAssertEqual(layout.place(8)?.col, 3, "a wrapped row starts under the text, after the bar")
        XCTAssertNil(layout.place(99))
    }

    func testAHangOverHalfTheWidthIsNotUsed() {
        let layout = TermRowLayout(TermLine([TermSpan("            - a long item that wraps")]), cols: 20)
        XCTAssertEqual(layout.hang, 0)
    }

    func testFindsThePanelBarAndTheFill() {
        let panel = TermColor.rgb(0x2B2E31)
        let line = TermLine([TermSpan("┃", TermStyle(fg: .rgb(0xF0C674), bg: panel)), TermSpan("  Add a test", TermStyle(bg: panel))], fill: panel)
        let layout = TermRowLayout(line, cols: 40)
        XCTAssertEqual(layout.bar?.col, 0)
        XCTAssertEqual(layout.bar?.width, TermRowLayout.heavyBar)
        XCTAssertEqual(layout.fillCol, 0, "the fill starts at the first cell with a background")
        XCTAssertEqual(layout.edge, panel, "the left padding gets the panel background")
        XCTAssertEqual(layout.edgeCols, 13)
    }

    func testTheFillStartsAfterPlainText() {
        let added = TermColor.rgb(0x3E4231)
        let line = TermLine([TermSpan("  5 "), TermSpan("+ code", TermStyle(bg: added))], fill: added)
        let layout = TermRowLayout(line, cols: 40)
        XCTAssertEqual(layout.fillCol, 4)
        XCTAssertNil(layout.edge)
        XCTAssertNil(layout.bar)
        XCTAssertEqual(TermRowLayout(TermLine([TermSpan("│ x")]), cols: 40).bar?.width, TermRowLayout.lightBar)
    }

    func testAnEmptyPanelRowGetsTheFillAsItsEdge() {
        let panel = TermColor.rgb(0x2B2E31)
        let layout = TermRowLayout(TermLine([], fill: panel), cols: 40)
        XCTAssertEqual(layout.edge, panel)
        XCTAssertEqual(layout.rows, [0..<0])
    }

    func testFindsTheBlockElements() {
        let layout = TermRowLayout(TermLine([TermSpan("█▀▀█ x ▄")]), cols: 40)
        XCTAssertEqual(layout.blocks.map(\.offset), [0, 1, 2, 3, 7])
        XCTAssertEqual(layout.blocks.first?.shape, TermText.blockShape("█"))
    }
}
