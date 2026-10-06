import XCTest
@testable import FluxKit

/// The fitting of full-screen agent output, for example opencode, to a
/// phone screen. The same cases as TermTextTest.kt of the Android app.
final class TermPhoneTests: XCTestCase {
    private let esc = "\u{1B}"

    private let white = 0xFFFFFF
    private let text = 0xC5C8C6
    private let gray = 0xA9A9A9
    private let accent = 0xF0C674
    private let panel = 0x2B2E31
    private let added = 0x3E4231
    private let sidebar = 0x202033

    private func lines(_ s: String) -> [TermLine] { TermText.lines(s) }

    private func blanks(_ n: Int) -> String { String(repeating: " ", count: n) }

    /// One cell run with a 24-bit foreground and an optional background, as herdr sends it.
    private func cell(_ s: String, _ fg: Int, _ bg: Int? = nil) -> String {
        let b = bg.map { ";48;2;\($0 >> 16 & 0xFF);\($0 >> 8 & 0xFF);\($0 & 0xFF)" } ?? ""
        return "\(esc)[0m\(esc)[38;2;\(fg >> 16 & 0xFF);\(fg >> 8 & 0xFF);\(fg & 0xFF)\(b)m\(s)"
    }

    /// A row of an opencode panel: a margin, the bar, the text, the panel background, and a margin.
    private func panelRow(_ body: String, bar: Int? = nil, width: Int = 80) -> String {
        cell("  ", white) + cell("┃", bar ?? panel, panel) + cell("  \(body)", text, panel) +
            cell(blanks(width - body.count), white, panel) + cell("  ", white) + "\(esc)[0m"
    }

    private func plainRow(_ body: String, indent: Int = 5, width: Int = 86) -> String {
        cell(blanks(indent), white) + cell(body, text) + cell(blanks(width - indent - body.count), white) + "\(esc)[0m"
    }

    private func blankRow() -> String { cell(blanks(86), white) + "\(esc)[0m" }

    /// The shape of an opencode screen: a message, a tool panel, a gap, the prompt box, and the status line.
    private var opencode: [String] {
        [
            blankRow(),
            panelRow("", bar: accent),
            panelRow("Add a test", bar: accent),
            panelRow("", bar: accent),
            blankRow(),
            plainRow("I added the test."),
            blankRow(),
            panelRow(""),
            panelRow("$ make test"),
            panelRow(""),
            panelRow("ok  4 tests"),
            panelRow(""),
            blankRow(),
            plainRow("▣  Build · Big Pickle · 12s"),
        ] + Array(repeating: blankRow(), count: 20) + [
            panelRow("", bar: accent),
            panelRow("", bar: accent),
            panelRow("", bar: accent),
            panelRow("Build · Big Pickle", bar: accent),
            cell("  ", white) + cell("╹", accent) + cell(String(repeating: "▀", count: 81), panel) + cell("  ", white) + "\(esc)[0m",
            cell("   ", white) + cell("~/code/app", gray) + cell(blanks(40), white) + cell("ctrl+p ", text) + cell("commands", gray) + "\(esc)[0m",
            blankRow(),
        ]
    }

    func testFitsAnOpencodeScreen() {
        let out = lines(opencode.joined(separator: "\r\n"))
        XCTAssertEqual(out.map(\.text), [
            "┃",
            "┃  Add a test",
            "┃",
            "",
            "   I added the test.",
            "",
            "┃",
            "┃  $ make test",
            "┃",
            "┃  ok  4 tests",
            "┃",
            "",
            "   ▣  Build · Big Pickle · 12s",
            "",
            "┃",
            "┃  Build · Big Pickle",
            " ~/code/app" + blanks(40) + "ctrl+p commands",
        ])
        XCTAssertEqual(out[1].fill, .rgb(panel), "a panel row keeps the panel background")
        XCTAssertEqual(out[0].fill, .rgb(panel), "an empty panel row too")
        XCTAssertNil(out[4].fill, "a row of the conversation has no fill")
        XCTAssertNil(out[3].fill)
    }

    /// A row of a wide opencode screen: `main` in 60 columns, a gap of 2, and `side` in a sidebar of 30 columns.
    private func wideRow(_ main: String, _ side: String, trimmed: Bool = false) -> String {
        func pad(_ s: String, _ n: Int) -> String { s + blanks(max(0, n - s.count)) }
        let bar = trimmed && side.isEmpty ? "" : cell("  ", white) + cell(trimmed ? "  \(side)" : pad("  \(side)", 30), text, sidebar)
        return cell(trimmed && bar.isEmpty ? main : pad(main, 60), text) + bar + "\(esc)[0m"
    }

    private let wideScreen = [("┃  Say hello", "Greeting"), ("", "Context"), ("   Hello.", "1% used"), ("", ""), ("   ▣  Build", "LSP")]

    func testDropsTheSidebar() {
        let expected = ["┃  Say hello", "", "   Hello.", "", "   ▣  Build"]
        XCTAssertEqual(lines(wideScreen.map { wideRow($0.0, $0.1) }.joined(separator: "\n")).map(\.text), expected)
        // An older fluxd removes the blanks at the end of a line, also when they have a background.
        XCTAssertEqual(lines(wideScreen.map { wideRow($0.0, $0.1, trimmed: true) }.joined(separator: "\n")).map(\.text), expected)
    }

    func testKeepsColumnsThatAreNotASidebar() {
        let wide = wideScreen.map { wideRow($0.0, $0.1) }
        func sideText(_ line: TermLine?) -> String {
            String((line?.text ?? "").dropFirst(60)).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        // A line with other cells in the sidebar column.
        XCTAssertEqual(sideText(lines((wide + [String(repeating: "x", count: 70)]).joined(separator: "\n")).first), "    Greeting")
        // Rows with a background from a column near the left, for example diff lines.
        let diff = (0..<5).map { "  \($0) " + cell("+ added line \($0)" + blanks(60), text, added) }
        XCTAssertEqual(lines(diff.joined(separator: "\n")).first?.text, "  0 + added line 0")
        // Too few rows.
        XCTAssertEqual(sideText(lines(wide.prefix(3).joined(separator: "\n")).first), "    Greeting")
    }

    func testFillsWithTheBackgroundAfterTheText() {
        // A diff row: the panel, then the added code, then blanks in the color of the added code.
        let row = cell("┃ ", panel, panel) + cell(" 5 + ", gray, added) + cell("def add(a, b):", text, added) +
            cell(blanks(30), white, added) + cell("    ", white, panel) + cell("  ", white)
        let out = lines(row)
        XCTAssertEqual(out.map(\.text), ["┃  5 + def add(a, b):"])
        XCTAssertEqual(out.first?.fill, .rgb(added))
        XCTAssertNil(lines("text   \(esc)[41m  ").first?.fill, "blanks with the default background give no fill")
    }

    func testDropsAScrollBarButKeepsADrawing() {
        let row = cell("┃  1   def greet(name):", text, panel) + cell(blanks(20), white, panel) + cell("█", gray, panel) + cell("   ", white, panel)
        let out = lines(row)
        XCTAssertEqual(out.map(\.text), ["┃  1   def greet(name):"])
        XCTAssertEqual(out.first?.fill, .rgb(panel))
        XCTAssertEqual(lines(blanks(30) + "▄\n  █▀▀█").first?.text, blanks(28) + "▄", "a lone block with no text before it stays")
        XCTAssertEqual(lines("bar ████").map(\.text), ["bar ████"], "a block that follows text directly stays")
    }

    func testDropsTheEdgesOfBoxes() {
        XCTAssertEqual(lines("┃ a\n╹" + String(repeating: "▀", count: 40) + "\n" + String(repeating: "▄", count: 20) + "\nb").map(\.text), ["┃ a", "b"])
        XCTAssertEqual(lines("▀▀▀").map(\.text), ["▀▀▀"], "a short run stays")
        XCTAssertEqual(lines("▀▀▀▀ █▀▀▀ ▀▀▀▀").map(\.text), ["▀▀▀▀ █▀▀▀ ▀▀▀▀"], "a logo row with gaps stays")
    }

    func testKeepsOneOfEachRunOfEmptyRows() {
        XCTAssertEqual(lines("\n\n\na\n\n\n\n\nb\n\n").map(\.text), ["a", "", "b"])
        XCTAssertEqual(lines("┃\n┃\n┃\n┃ x\n┃\n┃").map(\.text), ["┃", "┃ x", "┃"])
        XCTAssertEqual(lines("a\n\n┃\n\nb").map(\.text), ["a", "", "┃", "", "b"], "different empty rows stay")
    }

    func testRemovesTheSharedMargin() {
        XCTAssertEqual(lines("   a\n\n     b").map(\.text), ["a", "", "  b"])
        XCTAssertEqual(lines("  a\nb").map(\.text), ["  a", "b"], "a line at the first column keeps the margin")
        // Blanks with a background are not margin.
        XCTAssertEqual(lines("\(esc)[44m  a\(esc)[0m\n   b").first?.text, "  a")
    }

    func testMovesACenteredBlockThatFits() {
        let logo = ["█▀▀█ █▀▀█", "█  █ █▀▀▀", "▀▀▀▀ ▀▀▀▀"]
        let screen = lines((logo.map { blanks(30) + $0 } + ["", String(repeating: "x", count: 70)]).joined(separator: "\n"))
        let fitted = TermText.fit(screen, cols: 30)
        // The logo is 9 wide in 70 columns, with 30 blanks before it. On 30 columns, it keeps 30 / 61 of the 21 free columns.
        XCTAssertEqual(fitted.prefix(3).map(\.text), logo.map { blanks(10) + $0 })
        XCTAssertEqual(fitted.last?.text, String(repeating: "x", count: 70), "a line that cannot fit stays")
        XCTAssertEqual(TermText.fit(screen, cols: 80), screen, "lines that fit stay")
    }

    func testKeepsABlockThatCannotFit() {
        let screen = lines("   " + String(repeating: "word ", count: 12) + "\n   short\n\n" + String(repeating: "y", count: 70))
        XCTAssertEqual(TermText.fit(screen, cols: 40), screen)
    }

    func testKeepsTextNearTheLeft() {
        // An answer of opencode starts at column 3. A line that is a little too wide wraps, and it keeps its column.
        let screen = lines("   " + String(repeating: "z", count: 40) + "\n\n" + String(repeating: "y", count: 70))
        XCTAssertEqual(TermText.fit(screen, cols: 40), screen)
    }

    /// Wraps `text` at `width` columns as an agent does: `first` before the first row and `rest` before the others.
    private func agentWrap(_ text: String, _ width: Int, _ first: String, _ rest: String? = nil) -> [String] {
        let rest = rest ?? blanks(first.count)
        var rows: [String] = []
        var row = first
        var empty = true
        for word in text.split(separator: " ") {
            if !empty && row.count + 1 + word.count > width {
                rows.append(row)
                row = rest
                empty = true
            }
            if !empty { row += " " }
            row += word
            empty = false
        }
        rows.append(row)
        return rows
    }

    private let answer = "The release is out. It contains the fix for the login page and the new export, and the deploy runs now."
    private let item = "Server: production runs the new build with the fix for the login page and the new export."

    func testJoinsTheRowsThatTheAgentWrapped() {
        let rule = String(repeating: "─", count: 60)
        let wrapped = agentWrap(answer, 60, "● ")
        XCTAssertGreaterThan(wrapped.count, 1)
        let screen = wrapped + [""] + agentWrap(item, 60, "  - ") + ["  - CLI: the new version is out.", "",
            "  A short line.", "  The next line stays.", rule, "❯ fix it", rule]
        let out = lines(screen.joined(separator: "\n"))
        XCTAssertEqual(out.map(\.text), [
            "● \(answer)", "", "  - \(item)", "  - CLI: the new version is out.", "",
            "  A short line.", "  The next line stays.", rule, "❯ fix it", rule,
        ])
        XCTAssertEqual(out.first?.cols, 60, "the lines keep the width of the terminal")
        XCTAssertEqual(lines(wrapped.joined(separator: "\n")).map(\.text), wrapped, "without a rule or a padded row, the width is not known")
    }

    func testJoinsTheRowsOfAPanel() {
        let text = "The agent read the two files and found the bug in the parser. It added a test, and it fixed the wrap of long rows."
        let rows = agentWrap(text, 80, "")
        XCTAssertGreaterThan(rows.count, 1)
        let out = lines((rows.map { panelRow($0, bar: accent) } + [plainRow("Done.")]).joined(separator: "\n"))
        XCTAssertEqual(out.map(\.text), ["┃  \(text)", "   Done."])
        XCTAssertEqual(out[0].fill, .rgb(panel), "the joined line keeps the panel background")
        XCTAssertNil(out[1].fill, "a row outside the panel does not join it")
    }

    func testFitsRulesAndHintsToTheScreen() {
        let screen = lines([
            "● Done.", blanks(32) + "new task? /clear to save 12k", String(repeating: "─", count: 50) + " session ─", "❯ fix it",
            String(repeating: "─", count: 60),
        ].joined(separator: "\n"))
        XCTAssertEqual(TermText.fit(screen, cols: 40).map(\.text), [
            "● Done.", blanks(12) + "new task? /clear to save 12k", String(repeating: "─", count: 30) + " session ─", "❯ fix it",
            String(repeating: "─", count: 40),
        ])
        XCTAssertEqual(TermText.fit(screen, cols: 60), screen, "lines that fit stay")
    }

    /// A row of a box that is `inner` columns wide inside.
    private func boxRow(_ text: String, inner: Int = 58) -> String { "│ " + text + blanks(inner - 1 - text.count) + "│" }

    func testOpensABoxThatIsTooWide() {
        let rule58 = String(repeating: "─", count: 58)
        let box = ["╭\(rule58)╮"] + ["Bash command", "", "  rm -rf build", "Do you want to proceed?", "❯ 1. Yes", "  2. No"].map { boxRow($0) } + ["╰\(rule58)╯"]
        let out = lines(box.joined(separator: "\n"))
        XCTAssertEqual(out.map(\.text), box, "a box keeps its rows")
        let rule39 = String(repeating: "─", count: 39)
        XCTAssertEqual(TermText.fit(out, cols: 40).map(\.text), [
            "╭\(rule39)", "│ Bash command", "│", "│   rm -rf build", "│ Do you want to proceed?", "│ ❯ 1. Yes", "│   2. No", "╰\(rule39)",
        ])
        XCTAssertEqual(TermText.fit(out, cols: 60), out, "a box that fits stays")
        let row = "│ a" + blanks(26) + "│ b" + blanks(27) + "│"
        let table = ["┌" + String(repeating: "─", count: 28) + "┬" + String(repeating: "─", count: 29) + "┐", row,
                     "└" + String(repeating: "─", count: 28) + "┴" + String(repeating: "─", count: 29) + "┘"]
        XCTAssertEqual(TermText.fit(lines(table.joined(separator: "\n")), cols: 40)[1].text, row, "a table keeps its sides")
    }

    func testShowsSymbolsThatPhoneFontsLack() {
        XCTAssertEqual(TermText.parse("⏵⏵ auto mode on").map(\.text), ["▸▸ auto mode on"])
        XCTAssertEqual(TermText.parse("⏺ Done").map(\.text), ["● Done"])
    }

    /// Expanded V2 tabs at the left, with the background of the selected tab on its first 3 cells.
    private func tabsRow(_ tab: String, _ main: String, width: Int = 42) -> String {
        func pad(_ s: String, _ n: Int) -> String { s + blanks(max(0, n - s.count)) }
        return cell(pad(String(tab.prefix(3)), 3), text, sidebar + 1) + cell(pad(String(tab.dropFirst(3)), width - 3), text, sidebar) + main
    }

    func testDropsVerticalSessionTabsBeforeFittingPanels() {
        let rows = [
            tabsRow("", blankRow()),
            tabsRow(" 1 Fix alignment", plainRow("Questions")),
            tabsRow("   flux", panelRow("Accept the license?", bar: accent)),
            tabsRow("", panelRow("1. Continue", bar: accent)),
            tabsRow(" + New session", panelRow("Build · Model", bar: accent)),
            tabsRow("", plainRow("esc interrupt")),
        ]
        let expected = lines([
            blankRow(), plainRow("Questions"), panelRow("Accept the license?", bar: accent),
            panelRow("1. Continue", bar: accent), panelRow("Build · Model", bar: accent), plainRow("esc interrupt"),
        ].joined(separator: "\n"))
        XCTAssertEqual(lines(rows.joined(separator: "\n")), expected)
        XCTAssertEqual(lines("Older plain history\n" + rows.joined(separator: "\n")).first?.text, "Older plain history")
        for indicator in ["?", "!", "⠋", " "] {
            var status = rows
            status[1] = tabsRow(" \(indicator) Fix alignment", plainRow("Questions"))
            XCTAssertEqual(lines(status.joined(separator: "\n")), expected)
        }
    }

    func testKeepsPanelsThatMentionNewSession() {
        let rows = [panelRow("1 Example"), panelRow("+ New session"), panelRow("Other text"), panelRow("Build")].joined(separator: "\n")
        XCTAssertEqual(lines(rows).map(\.text), ["┃  1 Example", "┃  + New session", "┃  Other text", "┃  Build"])
        let few = [tabsRow(" 1 Title", plainRow("Hello")), tabsRow(" + New session", plainRow("Build"))]
        XCTAssertTrue(lines(few.joined(separator: "\n")).first?.text.contains("1 Title") == true)
    }

    func testFindsTheHangingIndent() {
        XCTAssertEqual(TermText.hangingIndent("   Plain text of the answer"), 3)
        XCTAssertEqual(TermText.hangingIndent("┃  make test"), 3)
        XCTAssertEqual(TermText.hangingIndent("┃  $ make test"), 5, "a shell prompt is a mark")
        XCTAssertEqual(TermText.hangingIndent("❯ Fix the test"), 2, "the prompt mark of Claude Code")
        XCTAssertEqual(TermText.hangingIndent("※ recap: the tests pass"), 2, "the recap mark of Claude Code")
        XCTAssertEqual(TermText.hangingIndent("› Fix the test"), 2, "the prompt mark of Codex")
        XCTAssertEqual(TermText.hangingIndent(" ❯ 1. Yes, and keep going"), 6, "the cursor and the number of a choice")
        XCTAssertEqual(TermText.hangingIndent("   - A bullet"), 5)
        XCTAssertEqual(TermText.hangingIndent("┃  [✓] Build the APK"), 7)
        XCTAssertEqual(TermText.hangingIndent("⏺ Claude Code text"), 2)
        XCTAssertEqual(TermText.hangingIndent("  ⎿  Tool output"), 5)
        XCTAssertEqual(TermText.hangingIndent("12. A numbered item"), 4)
        XCTAssertEqual(TermText.hangingIndent("->x"), 0, "a dash without a blank is text")
        XCTAssertEqual(TermText.hangingIndent(""), 0)
    }

    func testFindsTheToneOfTheColors() {
        XCTAssertEqual(TermText.tone(lines(opencode.joined(separator: "\n"))), .dark, "light text is for a dark background")
        let darkText = cell("dark text on a light background", 0x202020) + cell(" more", 0x303030)
        XCTAssertEqual(TermText.tone(lines(darkText)), .light)
        // Claude Code uses theme colors for most text, and its orange is neither light nor dark.
        let claude = "\(esc)[38;2;215;119;87m●\(esc)[0m I added the migration in the database folder."
        XCTAssertNil(TermText.tone(lines(claude)))
        XCTAssertNil(TermText.tone(lines("\(esc)[37mwhite from the theme\(esc)[0m")), "palette colors come from the theme")
        // fluxd puts the plain history of an agent above its screen. The history has theme colors, so it does not count.
        let history = Array(repeating: "an older line of plain text", count: 150)
        XCTAssertEqual(TermText.tone(lines((history + opencode).joined(separator: "\n"))), .dark)
        XCTAssertNil(TermText.tone(lines(cell("light", white) + cell("dark", 0x101010))), "light and dark text close in number")
    }

    func testFindsTheShapesOfBlocks() {
        XCTAssertEqual(TermText.blockShape("█")?.rects, [CellRect(0, 0, 1, 1)])
        XCTAssertEqual(TermText.blockShape("▀")?.rects, [CellRect(0, 0, 1, 0.5)])
        XCTAssertEqual(TermText.blockShape("▄")?.rects, [CellRect(0, 0.5, 1, 1)])
        XCTAssertEqual(TermText.blockShape("▁")?.rects, [CellRect(0, 7.0 / 8, 1, 1)])
        XCTAssertEqual(TermText.blockShape("▌")?.rects, [CellRect(0, 0, 0.5, 1)])
        XCTAssertEqual(TermText.blockShape("▏")?.rects, [CellRect(0, 0, 1.0 / 8, 1)])
        XCTAssertEqual(TermText.blockShape("▐")?.rects, [CellRect(0.5, 0, 1, 1)])
        XCTAssertEqual(TermText.blockShape("▒")?.alpha, 0.5)
        XCTAssertEqual(TermText.blockShape("▖")?.rects, [CellRect(0, 0.5, 0.5, 1)])
        XCTAssertEqual(TermText.blockShape("▟")?.rects, [CellRect(0.5, 0, 1, 0.5), CellRect(0, 0.5, 0.5, 1), CellRect(0.5, 0.5, 1, 1)])
        XCTAssertNil(TermText.blockShape("┃"))
        XCTAssertNil(TermText.blockShape("a"))
    }

    func testInvertsTheLightness() {
        XCTAssertEqual(TermText.invertLightness(0xFFFFFF), 0x000000)
        XCTAssertEqual(TermText.invertLightness(0x000000), 0xFFFFFF)
        XCTAssertEqual(TermText.invertLightness(0xFF0000), 0xFF0000, "a color at half lightness stays")
        XCTAssertEqual(TermText.invertLightness(0xA3A3A3), 0x5C5C5C)
        XCTAssertEqual(TermText.invertLightness(0xFFCEAD), 0x522100, "a light orange becomes a dark orange")
    }
}
