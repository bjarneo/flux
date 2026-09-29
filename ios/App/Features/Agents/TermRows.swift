import FluxKit
import SwiftUI
import UIKit

/// The layout of 1 output line on the screen: the rows that it wraps into,
/// and where the view draws the fill, the bar of a panel, the backgrounds of
/// cells, and block elements. Every cell has the same width, as in a
/// terminal. This is the phone layout of TermTextUi.kt of the Android app.
struct TermRowLayout: Equatable {
    /// A run of cells with one look. `start` and `end` are cell offsets in the line.
    struct Run: Equatable {
        var start: Int
        var end: Int
        var fg: TermColor?
        var bg: TermColor?
        /// Inverse text shows the text color as its background.
        var inverse: Bool
        var style: TermStyle
    }

    /// The cell offsets of each row. A long line wraps at a blank when it can.
    var rows: [Range<Int>]
    /// The column where the wrapped rows start.
    var hang: Int
    var runs: [Run]
    /// The column where the fill starts, see `TermLine.fill`.
    var fillCol: Int
    /// The background of the first cell, when the fill starts at column 0.
    /// It goes under the left padding and the first `edgeCols` columns, so
    /// the wrapped rows keep the background of a panel under its bar.
    var edge: TermColor?
    var edgeCols: Int
    /// The column of a panel bar at the start of the line, and its width in cells.
    var bar: (col: Int, width: Double)?
    /// The block elements, as cell offsets and shapes.
    var blocks: [(offset: Int, shape: BlockShape)]

    /// The width of a heavy panel bar, the bar of opencode, in cells.
    static let heavyBar = 0.25
    /// The width of a light panel bar, in cells.
    static let lightBar = 0.12

    init(_ line: TermLine, cols: Int) {
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

    static func == (a: TermRowLayout, b: TermRowLayout) -> Bool {
        a.rows == b.rows && a.hang == b.hang && a.runs == b.runs && a.fillCol == b.fillCol && a.edge == b.edge
            && a.edgeCols == b.edgeCols && a.bar?.col == b.bar?.col && a.bar?.width == b.bar?.width
            && a.blocks.map(\.offset) == b.blocks.map(\.offset) && a.blocks.map(\.shape) == b.blocks.map(\.shape)
    }

    /// Splits a line of cells into rows of at most `cols` cells. The wrapped
    /// rows start at column `hang`. A row ends after a blank when one comes
    /// after the first cell, else it ends at the edge. The blanks at a break
    /// that falls between words go.
    static func wrap(_ text: [Character], cols: Int, hang: Int) -> [Range<Int>] {
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
    func place(_ offset: Int) -> (row: Int, col: Int)? {
        guard let r = rows.firstIndex(where: { $0.contains(offset) }) else { return nil }
        return (r, (r == 0 ? 0 : hang) + offset - rows[r].lowerBound)
    }
}

/// The side padding of each output line. The fill of a line goes under it.
let termPad: CGFloat = 12

/// The height of 1 row of output.
let termRowHeight: CGFloat = 16

/// The fewest columns that the output view assumes, for a very narrow screen.
private let minCols = 20

/// The width of 1 cell of the output font.
let termCell: CGFloat = {
    let font = UIFont.monospacedSystemFont(ofSize: TermColors.fontSize, weight: .regular)
    let sample = "0000000000"
    return (sample as NSString).size(withAttributes: [.font: font]).width / CGFloat(sample.count)
}()

/// Terminal lines in the colors of the app, in a view that is `width`
/// points wide. A long line wraps, and its wrapped rows line up with its
/// text. A line with a fill shows the fill up to the right edge, so the
/// panels of an agent look like panels. When the text colors suit the other
/// tone than the app, the view inverts their lightness.
struct TermLinesView: View {
    let lines: [TermLine]
    let width: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let cols = max(minCols, Int((width - termPad * 2) / termCell))
        let invert = TermText.tone(lines).map { ($0 == .dark) != (scheme == .dark) } ?? false
        // Up to 1000 lines: only the rows on the screen get a layout.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(TermText.fit(lines, cols: cols).enumerated()), id: \.offset) { _, line in
                TermRowView(line: line, layout: TermRowLayout(line, cols: cols), invert: invert)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TermRowView: View {
    let line: TermLine
    let layout: TermRowLayout
    let invert: Bool

    var body: some View {
        let height = CGFloat(layout.rows.count) * termRowHeight
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(layout.rows.enumerated()), id: \.offset) { r, range in
                Text(text(range))
                    .font(TermColors.font)
                    .foregroundStyle(TermColors.text)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: termRowHeight)
                    .padding(.leading, termPad + CGFloat(r == 0 ? 0 : layout.hang) * termCell)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(Canvas { context, size in drawBackground(context, size) })
        .overlay(Canvas { context, size in drawShapes(context, size) }.allowsHitTesting(false))
    }

    private func color(_ c: TermColor) -> Color { TermColors.color(c, invert: invert) }

    private func fg(_ run: TermRowLayout.Run) -> Color {
        if run.inverse { return run.bg.map(color) ?? TermColors.background }
        let c = run.fg.map(color) ?? TermColors.text
        return run.style.dim ? c.opacity(TermColors.dimAlpha) : c
    }

    private func bg(_ run: TermRowLayout.Run) -> Color? {
        if run.inverse { return run.fg.map(color) ?? TermColors.text }
        return run.bg.map(color)
    }

    /// The text of 1 row. The glyphs of the bar and of block elements are
    /// clear, because the font draws them shorter than the row. The view
    /// draws them instead, as a terminal does.
    private func text(_ range: Range<Int>) -> AttributedString {
        let chars = Array(line.text)
        let hidden = Set(layout.blocks.map(\.offset) + (layout.bar.map { [$0.col] } ?? []))
        var out = AttributedString()
        for run in layout.runs {
            let lo = max(run.start, range.lowerBound)
            let hi = min(run.end, range.upperBound)
            guard lo < hi else { continue }
            var i = lo
            while i < hi {
                let clear = hidden.contains(i)
                var j = i + 1
                while j < hi && hidden.contains(j) == clear { j += 1 }
                var a = AttributedString(String(chars[i..<j]))
                a.foregroundColor = clear ? .clear : fg(run)
                if run.style.bold || run.style.italic {
                    var font = Font.system(size: TermColors.fontSize, weight: run.style.bold ? .bold : .regular, design: .monospaced)
                    if run.style.italic { font = font.italic() }
                    a.font = font
                }
                if run.style.underline { a.underlineStyle = Text.LineStyle(pattern: .solid) }
                if run.style.strike { a.strikethroughStyle = Text.LineStyle(pattern: .solid) }
                out += a
                i = j
            }
        }
        return out
    }

    /// Draws the fill of the line and the backgrounds of its cells over the
    /// full height of each row.
    private func drawBackground(_ context: GraphicsContext, _ size: CGSize) {
        if let fill = line.fill.map(color) {
            let x = min(size.width, termPad + CGFloat(layout.fillCol == 0 ? layout.edgeCols : layout.fillCol) * termCell)
            if layout.fillCol == 0 {
                context.fill(Path(CGRect(x: 0, y: 0, width: x, height: size.height)), with: .color(layout.edge.map(color) ?? fill))
            }
            context.fill(Path(CGRect(x: x, y: 0, width: size.width - x, height: size.height)), with: .color(fill))
        }
        for run in layout.runs {
            guard let bg = bg(run) else { continue }
            for (r, range) in layout.rows.enumerated() {
                let lo = max(run.start, range.lowerBound)
                let hi = min(run.end, range.upperBound)
                guard lo < hi, let start = layout.place(lo) else { continue }
                let rect = CGRect(x: termPad + CGFloat(start.col) * termCell, y: CGFloat(r) * termRowHeight,
                                  width: CGFloat(hi - lo) * termCell, height: termRowHeight)
                context.fill(Path(rect.integral), with: .color(bg))
            }
        }
    }

    /// Draws the panel bar over the full height of the line, and the block
    /// elements in their cells. The edges snap to whole points, so the
    /// blocks of a drawing join with no seams.
    private func drawShapes(_ context: GraphicsContext, _ size: CGSize) {
        func run(at offset: Int) -> TermRowLayout.Run? { layout.runs.first { $0.start <= offset && offset < $0.end } }
        if let bar = layout.bar, let r = run(at: bar.col) {
            let w = max(1, termCell * bar.width)
            let x = termPad + CGFloat(bar.col) * termCell + (termCell - w) / 2
            context.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(fg(r)))
        }
        for block in layout.blocks {
            guard let r = run(at: block.offset), let p = layout.place(block.offset) else { continue }
            let color = fg(r).opacity(block.shape.alpha)
            let cellX = termPad + CGFloat(p.col) * termCell
            let cellY = CGFloat(p.row) * termRowHeight
            for rect in block.shape.rects {
                let left = (cellX + rect.left * termCell).rounded()
                let right = (cellX + rect.right * termCell).rounded()
                let top = (cellY + rect.top * termRowHeight).rounded()
                let bottom = (cellY + rect.bottom * termRowHeight).rounded()
                context.fill(Path(CGRect(x: left, y: top, width: right - left, height: bottom - top)), with: .color(color))
            }
        }
    }
}
