import FluxKit
import SwiftUI
import AppKit

/// The side padding of each output line. The fill of a line goes under it.
let termPad: CGFloat = 12

/// The height of 1 row of output.
let termRowHeight: CGFloat = 16

/// The fewest columns that the output view assumes, for a very narrow screen.
private let minCols = 20

/// The width of 1 cell of the output font.
let termCell: CGFloat = {
    let font = NSFont.monospacedSystemFont(ofSize: TermColors.fontSize, weight: .regular)
    let sample = "0000000000"
    return (sample as NSString).size(withAttributes: [.font: font]).width / CGFloat(sample.count)
}()

/// Terminal lines in the colors of the app, in a view that is `width`
/// points wide. A long line wraps, and its wrapped rows line up with its
/// text. A line with a fill shows the fill up to the right edge, so the
/// panels of an agent look like panels. When the text colors suit the other
/// tone than the app, the view inverts their lightness. This is the view of
/// the iPhone app with the font of macOS.
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

    /// The color of a background, or nil for the background of the view.
    /// With `invert`, a black background is the background of the view and
    /// not white, because the agent drew it for a dark terminal. An example
    /// is the logo of Claude Code.
    private func background(_ c: TermColor) -> Color? {
        if invert, let v = TermText.fixedRgb(c), v >> 16 & 0xFF <= 0x10, v >> 8 & 0xFF <= 0x10, v & 0xFF <= 0x10 { return nil }
        return color(c)
    }

    private func fg(_ run: TermRowLayout.Run) -> Color {
        if run.inverse { return run.bg.map(color) ?? TermColors.background }
        let c = run.fg.map(color) ?? TermColors.text
        return run.style.dim ? c.opacity(TermColors.dimAlpha) : c
    }

    private func bg(_ run: TermRowLayout.Run) -> Color? {
        if run.inverse { return run.fg.map(color) ?? TermColors.text }
        return run.bg.flatMap(background)
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
        if let fill = line.fill.flatMap(background) {
            let x = min(size.width, termPad + CGFloat(layout.fillCol == 0 ? layout.edgeCols : layout.fillCol) * termCell)
            if layout.fillCol == 0 {
                context.fill(Path(CGRect(x: 0, y: 0, width: x, height: size.height)), with: .color(layout.edge.flatMap(background) ?? fill))
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
