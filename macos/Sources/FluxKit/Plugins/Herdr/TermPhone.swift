import Foundation

// The screen layout of terminal text: full-screen agents such as opencode
// draw panels across a wide terminal, and a phone screen or a window pane is
// narrower. This is a port of the layout functions of TermText.kt of the
// Android app, so the phones and the Mac show the same output.

/// The tone of the background that the colors of an output suit.
public enum TermTone: Sendable, Equatable {
    case dark, light
}

/// A rectangle in a cell, in fractions of the cell width and height from
/// the top left corner.
public struct CellRect: Sendable, Equatable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public init(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// How a block element fills its cell: rectangles in the text color, with
/// `alpha` for a shade.
public struct BlockShape: Sendable, Equatable {
    public var rects: [CellRect]
    public var alpha: Double

    public init(_ rects: [CellRect], alpha: Double = 1) {
        self.rects = rects
        self.alpha = alpha
    }
}

extension TermText {
    /// The bars at the left side of a panel, for example of a message in opencode.
    static let bars: Set<Character> = ["┃", "│", "║", "▌", "▎", "▏"]

    /// The right sides of boxes. A line that ends in one is a row of a box.
    private static let boxSides: Set<Character> = ["│", "┃", "║"]
    private static let boxTops: Set<Character> = ["╭", "┌", "╔", "┏"]
    private static let boxTopEnds: Set<Character> = ["╮", "┐", "╗", "┓"]
    private static let boxBottoms: Set<Character> = ["╰", "└", "╚", "┗"]
    private static let boxBottomEnds: Set<Character> = ["╯", "┘", "╝", "┛"]
    /// The joins of a table. A box with one of them in its top edge is a
    /// table, and `openBoxes` keeps it.
    private static let tableJoins = Set("┬┴┼├┤╤╧╪╦╩╬┳┻╋")

    /// A run of rule characters must be this long to count as a rule.
    static let ruleMin = 8
    /// The shortest run that a rule keeps when `fit` shortens it.
    private static let ruleKeep = 3
    /// The columns at the right edge that an agent can keep free when it
    /// wraps a line, for example for the margin of a panel.
    private static let wrapSlack = 2

    /// A lone block after this many blanks at the end of a line is the thumb of a scroll bar.
    private static let scrollBarGap = 4

    /// The caps at the ends of a box edge, see `isBoxEdge`.
    private static let edgeCaps: Set<Character> = ["╵", "╷", "╹", "╻"]

    /// A sidebar starts at this column or later, see `dropSidebar`.
    private static let sidebarMinCol = 40
    /// The widest sidebar, in columns.
    private static let sidebarMaxWidth = 60
    /// The fewest lines that end in a sidebar.
    private static let sidebarMinRows = 4

    /// A block must start at this column or later to move, see `fit`. Text
    /// in a column near the left keeps its place.
    private static let fitMinLead = 8

    /// Text with a luminance of at least this value is light.
    private static let lightText = 0.3
    /// Text with a luminance of at most this value is dark.
    private static let darkText = 0.1

    /// Makes terminal lines fit a screen. It removes the blanks at the end
    /// of each line, scroll bars, and the edges of boxes. It joins the rows
    /// that the agent wrapped at the width of the terminal, see `reflow`. It
    /// also removes the blank columns that all lines share at the start, and
    /// the extra empty rows, because full-screen agents such as opencode fill
    /// the terminal with them. `fit` then fits the rules, boxes, and drawings
    /// to the width of the screen.
    public static func tidy(_ lines: [TermLine]) -> [TermLine] {
        let rows = dropSidebar(dropSessionTabs(lines))
        let width = termWidth(rows)
        var out: [TermLine] = []
        for line in rows {
            let trimmed = trimEndKeepingFill(dropScrollBar(line))
            if !isBoxEdge(trimmed.text.trimmingCharacters(in: .whitespaces)) { out.append(trimmed) }
        }
        let joined = reflow(out, width: width)
        let margin = joined.filter { !$0.spans.isEmpty }.map(leadingBlanks).min() ?? 0
        var result = dropEmptyRows(margin == 0 ? joined : joined.map { dropColumns($0, margin) })
        if width > 0 {
            for i in result.indices { result[i].cols = width - margin }
        }
        return result
    }

    /// The start and the length of the longest run of 1 rule character.
    static func longestRule(_ chars: [Character]) -> (start: Int, count: Int) {
        var best = (start: 0, count: 0)
        var i = 0
        while i < chars.count {
            var j = i + 1
            if ruleChars.contains(chars[i]) {
                while j < chars.count && chars[j] == chars[i] { j += 1 }
                if j - i > best.count { best = (i, j - i) }
            }
            i = j
        }
        return best
    }

    /// Returns the width of the terminal in columns, or 0 when the lines do
    /// not show it. The widest line shows the width when it ends in blanks,
    /// which a screen row with a background has, or when it holds a rule. A
    /// plain read has no blanks at the end, so its widest line can be
    /// narrower than the terminal.
    private static func termWidth(_ lines: [TermLine]) -> Int {
        let texts = lines.map { Array($0.text) }
        guard let width = texts.map(\.count).max(), width > 0 else { return 0 }
        let shown = texts.contains { t in t.count == width && (t.last == " " || longestRule(t).count >= ruleMin) }
        return shown ? width : 0
    }

    /// Joins the rows that an agent wrapped at the terminal `width` into 1
    /// line. Claude Code, Codex, and opencode wrap their text at the width of
    /// the terminal, so on a narrow screen each row breaks again and leaves a
    /// short piece. The screen then wraps the joined line at its own width. A
    /// row continues the line above it when the first word of the row did not
    /// fit at the end of the line above, and when the row starts at the
    /// hanging indent of that line, under the same panel bar and with the
    /// same fill. A row with a list marker starts a new line. Rules and the
    /// rows of a box stay as they are. Without a known width, the lines stay
    /// as they are.
    private static func reflow(_ lines: [TermLine], width: Int) -> [TermLine] {
        guard width > 0 else { return lines }
        var out: [TermLine] = []
        out.reserveCapacity(lines.count)
        // The length of the last row of the last line, or 0 when no row can join it.
        var end = 0
        var hang = 0
        // The first row of the last line. Its panel bars must be in the next row too.
        var first: [Character] = []
        for line in lines {
            let text = Array(line.text)
            if let prev = out.last, let last = prev.spans.last, end > 0, 2 * end >= width, line.fill == prev.fill,
               continues(first, text, hang: hang) {
                let word = (text[hang...].firstIndex(of: " ") ?? text.count) - hang
                if end + 1 + word > width - wrapSlack {
                    var gap = last.style
                    gap.underline = false
                    gap.strike = false
                    out[out.count - 1] = TermLine(prev.spans + [TermSpan(" ", gap)] + dropColumns(line, hang).spans, fill: prev.fill)
                    end = canContinue(text) ? text.count : 0
                    continue
                }
            }
            out.append(line)
            first = text
            end = canContinue(text) ? text.count : 0
            hang = hangingIndent(line.text)
        }
        return out
    }

    /// True when the next row can continue a line that ends with `row`: the
    /// row has text, and it is not a rule or a row of a box.
    private static func canContinue(_ row: [Character]) -> Bool {
        guard let last = row.last, row.contains(where: { $0 != " " }) else { return false }
        return !boxSides.contains(last) && longestRule(row).count < ruleMin
    }

    /// True when `row` can continue the line with the first row `prev`,
    /// which wraps at column `hang`. Before that column, the row has only
    /// blanks and the panel bars of the line. At that column, its text
    /// starts, without a list marker.
    private static func continues(_ prev: [Character], _ row: [Character], hang: Int) -> Bool {
        guard hang < row.count, row[hang] != " ", canContinue(row) else { return false }
        for i in 0..<hang where row[i] != " " {
            guard bars.contains(row[i]), i < prev.count, prev[i] == row[i] else { return false }
        }
        let rest = String(row[hang...])
        return listMarker.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) == nil
    }

    private static let sessionMarker = try! NSRegularExpression(pattern: #"^\s*\+ New session\s*$"#)
    private static let sessionTitle = try! NSRegularExpression(pattern: #"^\s*(?:\d+|[!?●•·⠁-⣿])?\s+\S"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Drops the expanded session tabs of OpenCode V2 at the left, without
    /// moving the plain history above them. The tabs are a column of cells
    /// with a background, from 8 to 60 columns wide, with the New session row
    /// and at least 1 session title.
    private static func dropSessionTabs(_ lines: [TermLine]) -> [TermLine] {
        for (index, line) in lines.enumerated() {
            var col = 0
            for span in line.spans {
                if span.style.bg == nil || span.style.inverse { break }
                col += span.text.count
            }
            guard (8...60).contains(col), matches(sessionMarker, String(line.text.prefix(col))) else { continue }
            func inRail(_ row: TermLine) -> Bool {
                var at = 0
                for span in row.spans {
                    if at >= col { return true }
                    if span.style.bg == nil || span.style.inverse { return false }
                    at += span.text.count
                }
                return at >= col
            }
            var start = index
            var end = index + 1
            while start > 0 && inRail(lines[start - 1]) { start -= 1 }
            while end < lines.count && inRail(lines[end]) { end += 1 }
            guard end - start >= sidebarMinRows else { continue }
            let hasTitle = lines[start..<end].contains { row in
                let prefix = String(row.text.prefix(col))
                return !matches(sessionMarker, prefix) && matches(sessionTitle, prefix)
            }
            guard hasTitle else { continue }
            return lines.enumerated().map { i, row in (start..<end).contains(i) ? dropColumns(row, col) : row }
        }
        return lines
    }

    /// True for the top or bottom edge of a box that half blocks draw, for
    /// example the prompt box of opencode: at least 8 upper or 8 lower half
    /// blocks, with an optional cap at each end.
    private static func isBoxEdge(_ text: String) -> Bool {
        var s = Substring(text)
        if let c = s.first, edgeCaps.contains(c) { s = s.dropFirst() }
        if let c = s.last, edgeCaps.contains(c) { s = s.dropLast() }
        guard s.count >= 8, let first = s.first, first == "▀" || first == "▄" else { return false }
        return s.allSatisfy { $0 == first }
    }

    private struct RunEnd: Hashable {
        var col: Int
        var bg: TermColor
    }

    /// Removes the sidebar at the right of a full-screen agent, for example
    /// the sidebar that opencode shows in a wide terminal. Each line holds a
    /// row of the conversation and a row of the sidebar, so on a narrow
    /// screen the two mix. A sidebar is a column of cells with one
    /// background, from the same column to the end of the lines. At least
    /// `sidebarMinRows` lines must end in it, and no line can have other cells there.
    private static func dropSidebar(_ lines: [TermLine]) -> [TermLine] {
        var ends: [RunEnd: Int] = [:]
        for line in lines {
            if let end = endRun(line) { ends[end, default: 0] += 1 }
        }
        // The most lines win. Between equal counts the leftmost column wins,
        // so that the result does not depend on the order of the dictionary.
        guard let (start, count) = ends.max(by: { ($0.value, -$0.key.col) < ($1.value, -$1.key.col) }) else { return lines }
        guard count >= sidebarMinRows, start.col >= sidebarMinCol else { return lines }
        guard (lines.map(\.text.count).max() ?? 0) - start.col <= sidebarMaxWidth else { return lines }
        for line in lines {
            var at = 0
            for s in line.spans {
                let n = s.text.count
                if at + n > start.col && (s.style.inverse || s.style.bg != start.bg) { return lines }
                at += n
            }
        }
        return lines.map { take($0, start.col) }
    }

    /// Returns the start column and the background of the run of cells with
    /// one background at the end of a line, or nil when the last cell has no background.
    private static func endRun(_ line: TermLine) -> RunEnd? {
        guard let last = line.spans.last, !last.style.inverse, let bg = last.style.bg else { return nil }
        var start = line.text.count
        for s in line.spans.reversed() {
            if s.style.inverse || s.style.bg != bg { break }
            start -= s.text.count
        }
        return RunEnd(col: start, bg: bg)
    }

    /// True when a blank cell with this style shows no color.
    private static func plain(_ s: TermStyle) -> Bool { s.bg == nil && !s.inverse }

    /// Removes the blanks at the end of a line. The background of the first
    /// blank after the text becomes the fill of the line. A line with no text
    /// gets the first background of its blanks.
    private static func trimEndKeepingFill(_ line: TermLine) -> TermLine {
        var spans = line.spans
        var fill: TermColor?
        var blankFill: TermColor?
        while let last = spans.last {
            var t = Substring(last.text)
            while let c = t.last, c.isWhitespace { t.removeLast() }
            if t.count < last.text.count {
                fill = plain(last.style) ? nil : last.style.bg
                if fill != nil { blankFill = fill }
            }
            if !t.isEmpty {
                spans[spans.count - 1].text = String(t)
                return TermLine(spans, fill: fill)
            }
            spans.removeLast()
        }
        return TermLine(spans, fill: blankFill)
    }

    /// Removes the thumb of a scroll bar: a lone block at the end of a line,
    /// after text and a gap of blanks. The cell becomes a blank with the same
    /// style, so the line keeps its fill. A block with no text before it
    /// stays, because it is part of a drawing, for example the logo of opencode.
    private static func dropScrollBar(_ line: TermLine) -> TermLine {
        let text = Array(line.text)
        guard let end = text.lastIndex(where: { $0 != " " }), end > scrollBarGap,
              let scalar = text[end].unicodeScalars.first, text[end].unicodeScalars.count == 1,
              (0x2580...0x259F).contains(scalar.value) else { return line }
        if text[(end - scrollBarGap)..<end].contains(where: { $0 != " " }) { return line }
        if text[0..<end].allSatisfy(\.isWhitespace) { return line }
        var offset = 0
        let spans = line.spans.map { s -> TermSpan in
            let chars = Array(s.text)
            let i = end - offset
            offset += chars.count
            guard chars.indices.contains(i) else { return s }
            var out = s
            out.text = String(chars[..<i]) + " " + String(chars[(i + 1)...])
            return out
        }
        return TermLine(spans, fill: line.fill)
    }

    /// The number of blank cells with no color at the start of a line.
    private static func leadingBlanks(_ line: TermLine) -> Int {
        var n = 0
        for s in line.spans {
            if !plain(s.style) { return n }
            for c in s.text {
                if c != " " { return n }
                n += 1
            }
        }
        return n
    }

    /// Removes the first `n` cells of a line.
    private static func dropColumns(_ line: TermLine, _ n: Int) -> TermLine {
        var out: [TermSpan] = []
        var left = n
        for s in line.spans {
            let count = s.text.count
            if left >= count {
                left -= count
                continue
            }
            out.append(TermSpan(String(s.text.dropFirst(left)), s.style))
            left = 0
        }
        return TermLine(out, fill: line.fill)
    }

    /// True when a row shows no text. The bar of an empty panel row is not text.
    private static func isEmptyRow(_ line: TermLine) -> Bool {
        let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.count == 1 && t.first.map(bars.contains) == true
    }

    /// Removes the blank rows at the start and at the end, and keeps 1 row of
    /// each run of equal empty rows.
    private static func dropEmptyRows(_ lines: [TermLine]) -> [TermLine] {
        var out: [TermLine] = []
        for line in lines {
            let blank = line.spans.isEmpty && line.fill == nil
            if blank && out.isEmpty || isEmptyRow(line) && out.last == line { continue }
            out.append(line)
        }
        while let last = out.last, last.spans.isEmpty && last.fill == nil { out.removeLast() }
        return out
    }

    /// Fits the lines that are wider than `cols` columns to the screen:
    ///
    /// - A box that is too wide loses its right side, see `openBoxes`.
    /// - A rule gets shorter, so that its line fills the width of the screen.
    ///   A line can hold a title next to the rule, for example the session
    ///   name that Claude Code shows above its prompt.
    /// - A centered block of lines moves to the left when it fits without
    ///   some of the blanks before it. An example is the logo of opencode. A
    ///   block is a run of lines between blank rows. It is centered when it
    ///   starts at column `fitMinLead` or later, and when it has at least
    ///   half as many blank columns at the left as at the right. The block
    ///   keeps its place relative to the width of the output, so it stays
    ///   centered.
    /// - A single line at the right edge of the terminal moves in the same
    ///   way, for example a hint of Claude Code. It then ends at the right
    ///   edge of the screen.
    public static func fit(_ lines: [TermLine], cols: Int) -> [TermLine] {
        guard (lines.map(\.text.count).max() ?? 0) > cols else { return lines }
        // A joined line is wider than the terminal, so the width comes from tidy when it can.
        let known = lines.map(\.cols).max() ?? 0
        let width = known > 0 ? known : (lines.map(\.text.count).max() ?? 0)
        var out = openBoxes(lines, cols: cols).map { fitRule($0, cols: cols) }
        func move(_ start: Int, _ end: Int, single: Bool) {
            let block = out[start..<end]
            let lead = block.map(leadingBlanks).min() ?? 0
            let right = block.map(\.text.count).max() ?? 0
            let size = right - lead
            // A single line moves only when it ends at the right edge, so that the rows of a drawing keep their places.
            guard right > cols, right <= width, size <= cols, lead >= fitMinLead, 2 * lead >= width - right,
                  !single || right >= width - wrapSlack else { return }
            // The share of the free columns at the left stays the same.
            let shift = lead - lead * (cols - size) / (width - size)
            for i in start..<end { out[i] = dropColumns(out[i], shift) }
        }
        var start = 0
        while start < out.count {
            var end = start
            while end < out.count && !out[end].spans.isEmpty { end += 1 }
            if end > start { move(start, end, single: false) }
            start = end + 1
        }
        for i in out.indices where out[i].text.count > cols { move(i, i + 1, single: true) }
        return out
    }

    /// Shortens the longest rule of a line that is wider than `cols`, so that the line fits.
    private static func fitRule(_ line: TermLine, cols: Int) -> TermLine {
        let text = Array(line.text)
        guard text.count > cols else { return line }
        let rule = longestRule(text)
        guard rule.count >= ruleMin else { return line }
        let cut = min(text.count - cols, rule.count - ruleKeep)
        return TermLine(take(line, rule.start).spans + dropColumns(line, rule.start + cut).spans, fill: line.fill)
    }

    /// Removes the right side of each box that is wider than `cols` columns,
    /// for example a dialog that fills the width of the terminal. The rows of
    /// the box then wrap on the screen, and the left side stays as a panel
    /// bar. A box starts with a top edge, for example ╭──╮, has rows with a
    /// side at both ends, and ends with a bottom edge. `fitRule` then
    /// shortens the edges.
    private static func openBoxes(_ lines: [TermLine], cols: Int) -> [TermLine] {
        let texts = lines.map { Array($0.text) }
        var out = lines
        var i = 0
        while i < lines.count {
            let top = texts[i]
            let right = top.count - 1
            guard right >= cols, let left = top.firstIndex(where: { $0 != " " }), boxTops.contains(top[left]),
                  boxTopEnds.contains(top[right]), !top.contains(where: { tableJoins.contains($0) }),
                  longestRule(top).count >= ruleMin else {
                i += 1
                continue
            }
            var end = i + 1
            while end < lines.count {
                let row = texts[end]
                if row.count != right + 1 { break }
                if boxBottoms.contains(row[left]) && boxBottomEnds.contains(row[right]) { break }
                if !boxSides.contains(row[left]) || !boxSides.contains(row[right]) { break }
                end += 1
            }
            guard end < lines.count, texts[end].count == right + 1, boxBottoms.contains(texts[end][left]) else {
                i += 1
                continue
            }
            for k in i...end { out[k] = trimEndKeepingFill(take(lines[k], right)) }
            i = end + 1
        }
        return out
    }

    /// A list marker: a symbol before a blank, for example the bullet of
    /// Claude Code or the prompt mark of Codex, a check box, or a number.
    private static let listMarker = try! NSRegularExpression(pattern: #"^(?:[^\p{L}\p{N}\s]|\[[ x✓•]\]|\d{1,3}[.)])\s+"#)

    /// Returns the column where the wrapped rows of a line start, so that
    /// they line up with its text. The column is after the blanks at the
    /// start, the bar of a panel, and up to 2 list markers, for example the
    /// cursor and the number of a choice.
    public static func hangingIndent(_ text: String) -> Int {
        let chars = Array(text)
        guard var i = chars.firstIndex(where: { $0 != " " }) else { return 0 }
        if bars.contains(chars[i]) {
            i += 1
            while i < chars.count && chars[i] == " " { i += 1 }
        }
        for _ in 0..<2 {
            let rest = String(chars[i...])
            guard let m = listMarker.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                  let range = Range(m.range, in: rest) else { break }
            i += rest[range].count
        }
        return i
    }

    private static let fullCell = CellRect(0, 0, 1, 1)

    /// The quadrants of the elements from ▖ to ▟. Bit 1 is the top left, 2
    /// the top right, 4 the bottom left, and 8 the bottom right.
    private static let quadrants = [4, 8, 1, 13, 9, 7, 11, 2, 6, 14]

    /// Returns the shape of a block element from ▀ to ▟, or nil for another
    /// character. A terminal fills the cell with these elements, but a font
    /// draws them shorter than a row of the output view, so the view draws the shapes.
    public static func blockShape(_ c: Character) -> BlockShape? {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return nil }
        switch v {
        case 0x2580: return BlockShape([CellRect(0, 0, 1, 0.5)])
        case 0x2581...0x2588: return BlockShape([CellRect(0, 1 - Double(v - 0x2580) / 8, 1, 1)])
        case 0x2589...0x258F: return BlockShape([CellRect(0, 0, Double(0x2590 - v) / 8, 1)])
        case 0x2590: return BlockShape([CellRect(0.5, 0, 1, 1)])
        case 0x2591: return BlockShape([fullCell], alpha: 0.25)
        case 0x2592: return BlockShape([fullCell], alpha: 0.5)
        case 0x2593: return BlockShape([fullCell], alpha: 0.75)
        case 0x2594: return BlockShape([CellRect(0, 0, 1, 1.0 / 8)])
        case 0x2595: return BlockShape([CellRect(7.0 / 8, 0, 1, 1)])
        case 0x2596...0x259F:
            let bits = quadrants[Int(v - 0x2596)]
            let parts: [(Int, CellRect)] = [
                (1, CellRect(0, 0, 0.5, 0.5)), (2, CellRect(0.5, 0, 1, 0.5)),
                (4, CellRect(0, 0.5, 0.5, 1)), (8, CellRect(0.5, 0.5, 1, 1)),
            ]
            return BlockShape(parts.filter { bits & $0.0 != 0 }.map(\.1))
        default: return nil
        }
    }

    /// Finds the tone of the background that the fixed text colors suit.
    /// Full-screen agents such as opencode give all text a color from the
    /// desktop theme, so light text means a dark background. Text in a theme
    /// color does not count, because the view shows it in the colors of the
    /// app. An example is the plain history that fluxd puts above the screen.
    /// The result is nil when there are no fixed colors, or when light and
    /// dark text colors are close in number.
    public static func tone(_ lines: [TermLine]) -> TermTone? {
        var light = 0
        var dark = 0
        for line in lines {
            for s in line.spans {
                guard let fg = s.style.fg, let rgb = fixedRgb(fg), !s.style.inverse else { continue }
                let n = s.text.filter { $0 != " " }.count
                let l = luminance(rgb)
                if l >= lightText { light += n } else if l <= darkText { dark += n }
            }
        }
        if light > 2 * dark { return .dark }
        if dark > 2 * light { return .light }
        return nil
    }

    /// Returns the 0xRRGGBB value of a color that does not come from the
    /// theme, or nil for a theme color.
    public static func fixedRgb(_ c: TermColor) -> Int? {
        switch c {
        case .rgb(let v): v
        case .indexed(let i): paletteRgb(i)
        }
    }

    /// The relative luminance of a 0xRRGGBB color, from 0 for black to 1 for white.
    private static func luminance(_ rgb: Int) -> Double {
        func channel(_ v: Int) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb >> 16 & 0xFF) + 0.7152 * channel(rgb >> 8 & 0xFF) + 0.0722 * channel(rgb & 0xFF)
    }

    /// Inverts the lightness of a 0xRRGGBB color and keeps its hue and
    /// saturation. White becomes black, and a light orange becomes a dark orange.
    public static func invertLightness(_ rgb: Int) -> Int {
        let r = Double(rgb >> 16 & 0xFF) / 255
        let g = Double(rgb >> 8 & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        // In HSL, 1 - L with the same hue and saturation moves each channel to 1 - max - min + channel.
        let shift = 1 - max(r, g, b) - min(r, g, b)
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v + shift)) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
