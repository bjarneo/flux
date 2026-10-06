import Foundation

/// The layout of 1 output line on the screen: the rows that it wraps into,
/// and where the view draws the fill, the bar of a panel, the backgrounds of
/// cells, and block elements. Every cell has the same width, as in a
/// terminal. This is the layout of TermTextUi.kt of the Android app. The
/// iPhone and the Mac draw the rows from it.
public struct TermRowLayout: Equatable {
    /// A run of cells with one look. `start` and `end` are cell offsets in the line.
    public struct Run: Equatable {
        public var start: Int
        public var end: Int
        public var fg: TermColor?
        public var bg: TermColor?
        /// Inverse text shows the text color as its background.
        public var inverse: Bool
        public var style: TermStyle
    }

    /// The cell offsets of each row. A long line wraps at a blank when it can.
    public var rows: [Range<Int>]
    /// The column where the wrapped rows start.
    public var hang: Int
    public var runs: [Run]
    /// The column where the fill starts, see `TermLine.fill`.
    public var fillCol: Int
    /// The background of the first cell, when the fill starts at column 0.
    /// It goes under the left padding and the first `edgeCols` columns, so
    /// the wrapped rows keep the background of a panel under its bar.
    public var edge: TermColor?
    public var edgeCols: Int
    /// The column of a panel bar at the start of the line, and its width in cells.
    public var bar: (col: Int, width: Double)?
    /// The block elements, as cell offsets and shapes.
    public var blocks: [(offset: Int, shape: BlockShape)]

    /// The width of a heavy panel bar, the bar of opencode, in cells.
    public static let heavyBar = 0.25
    /// The width of a light panel bar, in cells.
    public static let lightBar = 0.12

    public init(_ line: TermLine, cols: Int) {
        let text = Array(line.text)
        let indent = TermText.hangingIndent(line.text)
        hang = indent <= cols / 2 ? indent : 0
        rows = Self.wrap(text, cols: cols, hang: hang)
        var runs: [Run] = []
        var at = 0
        for span in line.spans {
            let n = span.text.count
            runs.append(Run(start: at, end: at + n, fg: span.style.fg, bg: span.style.bg, inverse: span.style.inverse, style: span.style))
            at += n
        }
        self.runs = runs
        // The fill starts at the first cell with a background, as in the terminal.
        let firstBg = runs.firstIndex { !$0.inverse && $0.bg != nil }
        fillCol = line.fill == nil ? 0 : min(firstBg.map { runs[$0].start } ?? text.count, text.count)
        edge = runs.first.flatMap { $0.inverse ? nil : $0.bg } ?? (line.spans.isEmpty ? line.fill : nil)
        edgeCols = 0
        if let edge {
            for r in runs {
                if r.inverse || r.bg != edge { break }
                edgeCols = r.end
            }
        }
        if let col = text.firstIndex(where: { $0 != " " }) {
            switch text[col] {
            case "┃": bar = (col, Self.heavyBar)
            case "│": bar = (col, Self.lightBar)
            default: bar = nil
            }
        } else {
            bar = nil
        }
        blocks = text.enumerated().compactMap { i, c in TermText.blockShape(c).map { (i, $0) } }
    }

    public static func == (a: TermRowLayout, b: TermRowLayout) -> Bool {
        a.rows == b.rows && a.hang == b.hang && a.runs == b.runs && a.fillCol == b.fillCol && a.edge == b.edge
            && a.edgeCols == b.edgeCols && a.bar?.col == b.bar?.col && a.bar?.width == b.bar?.width
            && a.blocks.map(\.offset) == b.blocks.map(\.offset) && a.blocks.map(\.shape) == b.blocks.map(\.shape)
    }

    /// Splits a line of cells into rows of at most `cols` cells. The wrapped
    /// rows start at column `hang`. A row ends after a blank when one comes
    /// after the first cell, else it ends at the edge. The blanks at a break
    /// that falls between words go.
    public static func wrap(_ text: [Character], cols: Int, hang: Int) -> [Range<Int>] {
        guard !text.isEmpty else { return [0..<0] }
        var rows: [Range<Int>] = []
        var start = 0
        while start < text.count {
            let width = max(1, rows.isEmpty ? cols : cols - hang)
            if text.count - start <= width {
                rows.append(start..<text.count)
                break
            }
            var end = start + width
            if text[end] == " " {
                rows.append(start..<end)
                start = end
                while start < text.count && text[start] == " " { start += 1 }
                continue
            }
            if let space = (start..<end).last(where: { text[$0] == " " }),
               text[start..<space].contains(where: { $0 != " " }) {
                end = space + 1
            }
            rows.append(start..<end)
            start = end
        }
        return rows
    }

    /// The row and the column on the screen of a cell offset.
    public func place(_ offset: Int) -> (row: Int, col: Int)? {
        guard let r = rows.firstIndex(where: { $0.contains(offset) }) else { return nil }
        return (r, (r == 0 ? 0 : hang) + offset - rows[r].lowerBound)
    }
}
