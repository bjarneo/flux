import FluxKit
import SwiftUI
import UIKit
import XCTest
@testable import Flux

/// Renders the output of an opencode screen in both appearances: panels
/// with their fill, the panel bars, a wrapped line, and the logo. Each must
/// draw a screen, see `ScreenRender`, and the dark one must be darker.
@MainActor
final class TermRowsRenderTests: XCTestCase {
    private let esc = "\u{1B}"

    private func cell(_ s: String, _ fg: Int, _ bg: Int? = nil) -> String {
        let b = bg.map { ";48;2;\($0 >> 16 & 0xFF);\($0 >> 8 & 0xFF);\($0 & 0xFF)" } ?? ""
        return "\(esc)[0m\(esc)[38;2;\(fg >> 16 & 0xFF);\(fg >> 8 & 0xFF);\(fg & 0xFF)\(b)m\(s)"
    }

    /// A screen of opencode in a terminal of 100 columns: the logo, a message
    /// panel, an answer, a tool panel, and the prompt box.
    private var screen: String {
        let white = 0xEEEEEE, text = 0xC5C8C6, gray = 0x808080, accent = 0xF0C674, panel = 0x2B2E31
        func blanks(_ n: Int) -> String { String(repeating: " ", count: n) }
        func panelRow(_ body: String, bar: Int = panel) -> String {
            cell("  ", white) + cell("┃", bar, panel) + cell("  \(body)", text, panel) + cell(blanks(90 - body.count), white, panel) + "\(esc)[0m"
        }
        let logo = ["█▀▀█ █▀▀█ █▀▀▀ █▀▀▄", "█  █ █▀▀▀ █▀▀▀ █  █", "▀▀▀▀ ▀    ▀▀▀▀ ▀  ▀"].map { blanks(40) + cell($0, white) }
        let rows = logo + [
            "",
            panelRow("", bar: accent),
            panelRow("Add a test for the parser and run it", bar: accent),
            panelRow("", bar: accent),
            "",
            cell("   I added the test in parser_test.go. It covers empty input, a single line, and a line that is longer than the terminal.", text),
            "",
            panelRow(""),
            panelRow("$ go test ./parser/..."),
            panelRow("ok   flux/parser  0.412s"),
            panelRow(""),
            "",
            cell("   ▣  Build · Big Pickle · 12s", gray),
            "",
            panelRow("", bar: accent),
            panelRow("Build · Big Pickle", bar: accent),
            cell("  ╹", accent) + cell(String(repeating: "▀", count: 90), panel),
        ]
        return rows.joined(separator: "\n")
    }

    private func render(_ scheme: ColorScheme, name: String) throws -> Double {
        let output = HerdrOutput(pane: "w1:p2", loading: false, lines: TermText.lines(screen))
        let view = PaneOutput(output: output).padding(16).background(Color(.systemGroupedBackground))
        return try ScreenRender.render(view, name: name, scheme: scheme, wait: 0.8)
    }

    func testRendersAnOpencodeScreen() throws {
        let dark = try render(.dark, name: "p10-opencode-dark")
        let light = try render(.light, name: "p10-opencode-light")
        XCTAssertLessThan(dark, light, "the dark screen is darker")
    }
}
