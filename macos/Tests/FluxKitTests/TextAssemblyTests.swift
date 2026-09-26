import XCTest
@testable import FluxKit

final class TextAssemblyTests: XCTestCase {
    private func block(_ left: Int, _ top: Int, _ right: Int, _ bottom: Int, _ lines: String...) -> ScanBlock {
        let h = lines.isEmpty ? 0 : (bottom - top) / lines.count
        return ScanBlock(
            lines.enumerated().map { i, t in ScanLine(t, ScanBox(left, top + i * h, right, top + (i + 1) * h)) },
            ScanBox(left, top, right, bottom)
        )
    }

    func testStackedBlocksReadTopToBottom() {
        let title = block(10, 10, 300, 40, "Invoice 0925")
        let body = block(10, 80, 300, 140, "Total 12.40", "Due 30 Sep")
        XCTAssertEqual(TextAssembly.assemble([body, title]), "Invoice 0925\n\nTotal 12.40\nDue 30 Sep")
    }

    func testBlocksInOneRowReadLeftToRight() {
        let right = block(200, 12, 300, 38, "B14")
        let left = block(10, 10, 120, 40, "Gate")
        let below = block(10, 60, 300, 90, "Boarding 15:40")
        XCTAssertEqual(TextAssembly.readingOrder([below, right, left]).map { $0.lines[0].text }, ["Gate", "B14", "Boarding 15:40"])
    }

    func testSmallOverlapStartsANewRow() {
        let a = block(200, 0, 300, 40, "first")
        let b = block(10, 30, 120, 70, "second")
        XCTAssertEqual(TextAssembly.readingOrder([b, a]).map { $0.lines[0].text }, ["first", "second"])
    }

    func testLinesInABlockFollowTheirPosition() {
        let b = ScanBlock([ScanLine("second", ScanBox(0, 30, 100, 50)), ScanLine("first", ScanBox(0, 0, 100, 20))], ScanBox(0, 0, 100, 50))
        XCTAssertEqual(TextAssembly.assemble([b]), "first\nsecond")
    }

    func testSplitWordsJoin() {
        XCTAssertEqual(TextAssembly.joinLines(["the configu-", "ration file"]), "the configuration file")
    }

    func testHyphenBeforeCapitalStays() {
        XCTAssertEqual(TextAssembly.joinLines(["Omarchy-", "Flux"]), "Omarchy-\nFlux")
    }

    func testDashAloneStays() {
        XCTAssertEqual(TextAssembly.joinLines(["price -", "see below"]), "price -\nsee below")
    }

    func testBlankLinesAndBlocksDrop() {
        let empty = block(0, 0, 10, 10)
        let spaces = block(0, 20, 100, 40, "   ")
        let text = block(0, 50, 100, 70, "  ssh deploy@10.0.4.12  ")
        XCTAssertEqual(TextAssembly.assemble([empty, spaces, text]), "ssh deploy@10.0.4.12")
    }

    func testNothingGivesEmptyText() {
        XCTAssertEqual(TextAssembly.assemble([]), "")
    }

    // MARK: Vision lines to blocks

    func testParagraphLinesFormOneBlock() {
        let lines = [
            ScanLine("Due 30 Sep", ScanBox(10, 130, 180, 150)),
            ScanLine("Total 12.40", ScanBox(10, 100, 200, 120)),
            ScanLine("Invoice 0925", ScanBox(10, 10, 400, 50)),
        ]
        XCTAssertEqual(TextAssembly.assemble(TextAssembly.blocks(from: lines)), "Invoice 0925\n\nTotal 12.40\nDue 30 Sep")
    }

    func testColumnsFormSeparateBlocks() {
        let lines = [
            ScanLine("left one", ScanBox(10, 10, 200, 30)),
            ScanLine("right one", ScanBox(400, 10, 600, 30)),
            ScanLine("left two", ScanBox(10, 36, 190, 56)),
            ScanLine("right two", ScanBox(400, 36, 590, 56)),
        ]
        XCTAssertEqual(TextAssembly.assemble(TextAssembly.blocks(from: lines)), "left one\nleft two\n\nright one\nright two")
    }

    func testPiecesOfALineJoin() {
        let lines = [ScanLine("12.40", ScanBox(130, 12, 190, 32)), ScanLine("Total", ScanBox(10, 10, 110, 30))]
        XCTAssertEqual(TextAssembly.assemble(TextAssembly.blocks(from: lines)), "Total 12.40")
    }
}
