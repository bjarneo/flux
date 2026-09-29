import Foundation

// The phone layout of terminal text: full-screen agents such as opencode
// draw panels across a wide terminal, and a phone screen is narrow. This is
// a port of the phone functions of TermText.kt of the Android app, so both
// phones show the same output. The Mac shows the output as the terminal has it.

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

    /// Makes terminal lines fit a phone screen. It removes the blanks at the
    /// end of each line, scroll bars, and the edges of boxes. It shortens
    /// lines of box rules, because they fill the width of the terminal. It
    /// also removes the blank columns that all lines share at the start, and
    /// the extra empty rows, because full-screen agents such as opencode fill
    /// the terminal with them.
    static func tidyForPhone(_ lines: [TermLine]) -> [TermLine] {
        var out: [TermLine] = []
        for line in dropSidebar(lines) {
            let trimmed = trimEndKeepingFill(dropScrollBar(line))
            let text = trimmed.text
            if isBoxEdge(text.trimmingCharacters(in: .whitespaces)) { continue }
            if text.count > ruleWidth && text.allSatisfy({ ruleChars.contains($0) }) {
                out.append(take(trimmed, ruleWidth))
            } else {
                out.append(trimmed)
            }
        }
        return dropEmptyRows(dedent(out))
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

    /// Removes the blank columns that all lines with text share at the start.
    private static func dedent(_ lines: [TermLine]) -> [TermLine] {
        let n = lines.filter { !$0.spans.isEmpty }.map(leadingBlanks).min() ?? 0
        return n == 0 ? lines : lines.map { dropColumns($0, n) }
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

    /// Moves the centered blocks of lines that are wider than `cols` columns
    /// to the left when they fit without some of the blanks before them. An
    /// example is the logo of opencode. A block is a run of lines between
    /// blank rows. It is centered when it starts at column `fitMinLead` or
    /// later, and when it has at least half as many blank columns at the left
    /// as at the right. The block keeps its place relative to the width of
    /// the output, so it stays centered.
    public static func fit(_ lines: [TermLine], cols: Int) -> [TermLine] {
        let width = lines.map(\.text.count).max() ?? 0
        guard width > cols else { return lines }
        var out = lines
        var start = 0
        while start < lines.count {
            var end = start
            while end < lines.count && !lines[end].spans.isEmpty { end += 1 }
            if end > start {
                let block = lines[start..<end]
                let lead = block.map(leadingBlanks).min() ?? 0
                let right = block.map(\.text.count).max() ?? 0
                let size = right - lead
                if right > cols && size <= cols && lead >= fitMinLead && 2 * lead >= width - right {
                    // The share of the free columns at the left stays the same.
                    let shift = lead - lead * (cols - size) / (width - size)
                    for i in start..<end { out[i] = dropColumns(lines[i], shift) }
                }
            }
            start = end + 1
        }
        return out
    }

    private static let listMarker = try! NSRegularExpression(pattern: #"^(?:[-*+•·◦▪‣⏺●⎿→←✓✔✗✘△▣■□]|\[[ x✓•]\]|\d{1,3}[.)])\s+"#)

    /// Returns the column where the wrapped rows of a line start, so that
    /// they line up with its text. The column is after the blanks at the
    /// start, the bar of a panel, and a list marker.
    public static func hangingIndent(_ text: String) -> Int {
        let chars = Array(text)
        guard var i = chars.firstIndex(where: { $0 != " " }) else { return 0 }
        if bars.contains(chars[i]) {
            i += 1
            while i < chars.count && chars[i] == " " { i += 1 }
        }
        let rest = String(chars[i...])
        if let m = listMarker.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
           let range = Range(m.range, in: rest) {
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
