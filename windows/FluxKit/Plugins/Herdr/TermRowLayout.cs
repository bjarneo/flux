namespace FluxKit;

// A range of cells of a line: from Start until End.
public readonly record struct CellRange(int Start, int End)
{
    public int Count => End - Start;
    public bool Contains(int offset) => offset >= Start && offset < End;
}

// The layout of 1 output line on the screen: the rows that it wraps into,
// and where the view draws the fill, the bar of a panel, the backgrounds of
// cells, and block elements. Every cell has the same width, as in a
// terminal. This is the layout of TermRowLayout.swift of the Mac app and
// TermTextUi.kt of the Android app. The WPF view draws the rows from it.
public sealed record TermRowLayout
{
    // A run of cells with 1 look. Start and End are cell offsets in the
    // line. Inverse text shows the text color as its background.
    public sealed record Run(int Start, int End, TermColor? Fg, TermColor? Bg, bool Inverse, TermStyle Style);

    // The width of a heavy panel bar, the bar of opencode, in cells.
    public const double HeavyBar = 0.25;

    // The width of a light panel bar, in cells.
    public const double LightBar = 0.12;

    public TermRowLayout(TermLine line, int cols)
    {
        var text = new CellText(line.Text);
        Cells = ValueList.From(Enumerable.Range(0, text.Count).Select(i => text[i]));
        var indent = TermText.HangingIndent(line.Text);
        Hang = indent <= cols / 2 ? indent : 0;
        Rows = ValueList.From(Wrap(text, cols, Hang));
        var runs = new List<Run>();
        var at = 0;
        foreach (var span in line.Spans)
        {
            var n = TermCells.Count(span.Text);
            runs.Add(new Run(at, at + n, span.Style.Fg, span.Style.Bg, span.Style.Inverse, span.Style));
            at += n;
        }
        Runs = ValueList.From(runs);
        // The fill starts at the first cell with a background, as in the terminal.
        var firstBg = runs.FindIndex(r => !r.Inverse && r.Bg is not null);
        FillCol = line.Fill is null ? 0 : Math.Min(firstBg >= 0 ? runs[firstBg].Start : text.Count, text.Count);
        Edge = runs.Count > 0 ? (runs[0].Inverse ? null : runs[0].Bg) : line.Fill;
        if (Edge is { } edge)
        {
            foreach (var r in runs)
            {
                if (r.Inverse || r.Bg != edge)
                {
                    break;
                }
                EdgeCols = r.End;
            }
        }
        var col = 0;
        while (col < text.Count && text.Single(col) == ' ')
        {
            col++;
        }
        if (col < text.Count)
        {
            Bar = text.Single(col) switch
            {
                '┃' => (col, HeavyBar),
                '│' => (col, LightBar),
                _ => null,
            };
        }
        var blocks = new List<(int Offset, BlockShape Shape)>();
        for (var i = 0; i < text.Count; i++)
        {
            if (TermText.BlockShapeOf(text.Single(i)) is { } shape)
            {
                blocks.Add((i, shape));
            }
        }
        Blocks = ValueList.From(blocks);
    }

    // The text elements of the line, 1 for each cell.
    public ValueList<string> Cells { get; }

    // The cell offsets of each row. A long line wraps at a blank when it can.
    public ValueList<CellRange> Rows { get; }

    // The column where the wrapped rows start.
    public int Hang { get; }

    public ValueList<Run> Runs { get; }

    // The column where the fill starts, see TermLine.Fill.
    public int FillCol { get; }

    // The background of the first cell, when the fill starts at column 0.
    // It goes under the left padding and the first EdgeCols columns, so the
    // wrapped rows keep the background of a panel under its bar.
    public TermColor? Edge { get; }
    public int EdgeCols { get; }

    // The column of a panel bar at the start of the line, and its width in cells.
    public (int Col, double Width)? Bar { get; }

    // The block elements, as cell offsets and shapes.
    public ValueList<(int Offset, BlockShape Shape)> Blocks { get; }

    // Splits the cells of a text into rows of at most cols cells. See Wrap
    // for the cells of a line.
    public static IReadOnlyList<CellRange> Wrap(string text, int cols, int hang) => Wrap(new CellText(text), cols, hang);

    // Splits a line of cells into rows of at most cols cells. The wrapped
    // rows start at column hang. A row ends after a blank when one comes
    // after the first cell, else it ends at the edge. The blanks at a break
    // that falls between words go.
    internal static List<CellRange> Wrap(CellText text, int cols, int hang)
    {
        if (text.Count == 0)
        {
            return [new CellRange(0, 0)];
        }
        var rows = new List<CellRange>();
        var start = 0;
        while (start < text.Count)
        {
            var width = Math.Max(1, rows.Count == 0 ? cols : cols - hang);
            if (text.Count - start <= width)
            {
                rows.Add(new CellRange(start, text.Count));
                break;
            }
            var end = start + width;
            if (text.Single(end) == ' ')
            {
                rows.Add(new CellRange(start, end));
                start = end;
                while (start < text.Count && text.Single(start) == ' ')
                {
                    start++;
                }
                continue;
            }
            var space = -1;
            for (var i = end - 1; i >= start; i--)
            {
                if (text.Single(i) == ' ')
                {
                    space = i;
                    break;
                }
            }
            if (space >= 0)
            {
                for (var i = start; i < space; i++)
                {
                    if (text.Single(i) != ' ')
                    {
                        end = space + 1;
                        break;
                    }
                }
            }
            rows.Add(new CellRange(start, end));
            start = end;
        }
        return rows;
    }

    // The row and the column on the screen of a cell offset.
    public (int Row, int Col)? Place(int offset)
    {
        for (var r = 0; r < Rows.Count; r++)
        {
            if (Rows[r].Contains(offset))
            {
                return (r, (r == 0 ? 0 : Hang) + offset - Rows[r].Start);
            }
        }
        return null;
    }
}
