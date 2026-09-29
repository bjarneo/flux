import XCTest
@testable import FluxCamera

/// `TextAssembly` vectors. Ports Android `TextAssemblyTest` verbatim.
final class TextAssemblyTests: XCTestCase {
    private func block(_ left: Int, _ top: Int, _ right: Int, _ bottom: Int, _ lines: String...) -> ScanBlock {
        let h = lines.isEmpty ? 0 : (bottom - top) / lines.count
        return ScanBlock(
            lines: lines.enumerated().map { i, t in
                ScanLine(t, box: ScanBox(left: left, top: top + i * h, right: right, bottom: top + (i + 1) * h))
            },
            box: ScanBox(left: left, top: top, right: right, bottom: bottom))
    }

    func testStackedBlocksReadTopToBottom() {
        let title = block(10, 10, 300, 40, "Invoice 0925")
        let body = block(10, 80, 300, 140, "Total 12.40", "Due 30 Sep")
        XCTAssertEqual("Invoice 0925\n\nTotal 12.40\nDue 30 Sep", TextAssembly.assemble([body, title]))
    }

    func testBlocksInOneRowReadLeftToRight() {
        let right = block(200, 12, 300, 38, "B14")
        let left = block(10, 10, 120, 40, "Gate")
        let below = block(10, 60, 300, 90, "Boarding 15:40")
        XCTAssertEqual(
            ["Gate", "B14", "Boarding 15:40"],
            TextAssembly.readingOrder([below, right, left]).map { $0.lines.first!.text })
    }

    func testSmallOverlapStartsANewRow() {
        let a = block(200, 0, 300, 40, "first")
        let b = block(10, 30, 120, 70, "second")
        XCTAssertEqual(["first", "second"], TextAssembly.readingOrder([b, a]).map { $0.lines.first!.text })
    }

    func testLinesInABlockFollowTheirPosition() {
        let b = ScanBlock(
            lines: [ScanLine("second", box: ScanBox(left: 0, top: 30, right: 100, bottom: 50)),
                    ScanLine("first", box: ScanBox(left: 0, top: 0, right: 100, bottom: 20))],
            box: ScanBox(left: 0, top: 0, right: 100, bottom: 50))
        XCTAssertEqual("first\nsecond", TextAssembly.assemble([b]))
    }

    func testSplitWordsJoin() {
        XCTAssertEqual("the configuration file", TextAssembly.joinLines(["the configu-", "ration file"]))
    }

    func testHyphenBeforeCapitalStays() {
        XCTAssertEqual("Omarchy-\nFlux", TextAssembly.joinLines(["Omarchy-", "Flux"]))
    }

    func testDashAloneStays() {
        XCTAssertEqual("price -\nsee below", TextAssembly.joinLines(["price -", "see below"]))
    }

    func testBlankLinesAndBlocksDrop() {
        let empty = block(0, 0, 10, 10)
        let spaces = block(0, 20, 100, 40, "   ")
        let text = block(0, 50, 100, 70, "  ssh deploy@10.0.4.12  ")
        XCTAssertEqual("ssh deploy@10.0.4.12", TextAssembly.assemble([empty, spaces, text]))
    }

    func testNothingGivesEmptyText() {
        XCTAssertEqual("", TextAssembly.assemble([]))
    }
}
