using System.Globalization;
using System.Windows;
using System.Windows.Media;
using FluxKit;

namespace Flux;

// The colors of the agent output: Tokyo Night in the dark mode and Tokyo
// Night Day in the light mode, the colors of Omarchy and of the Android app.
// Each color follows the light or dark mode of the palette. TermColors.swift
// of the Mac app has the same values.
public static class TermColors
{
    public static Brush Background => Pick(0xD8DBE5, 0x1A1B26);
    public static Brush Text => Pick(0x3760BF, 0xC0CAF5);
    static Brush Dim => Pick(0x848CB5, 0x565F89);
    static Brush Red => Pick(0xF52A65, 0xF7768E);
    static Brush Green => Pick(0x587539, 0x9ECE6A);
    static Brush Yellow => Pick(0x8C6C3E, 0xE0AF68);
    static Brush Blue => Pick(0x2E7DE9, 0x7AA2F7);
    static Brush Magenta => Pick(0x9854F1, 0xBB9AF7);
    static Brush Cyan => Pick(0x007197, 0x7DCFFF);
    static Brush Black => Pick(0xD0D5E3, 0x16161E);
    static Brush White => Pick(0x6172B0, 0xA9B1D6);

    // The alpha of dim text.
    public const double DimAlpha = 0.6;

    static readonly Dictionary<int, SolidColorBrush> Brushes = [];

    // The 16 theme colors of the terminal. The bright colors use the same
    // hues. Black is the background and white is the second ink, so both
    // work in the light mode too.
    static Brush? Palette(int i) => i switch
    {
        0 => Black,
        1 or 9 => Red,
        2 or 10 => Green,
        3 or 11 => Yellow,
        4 or 12 => Blue,
        5 or 13 => Magenta,
        6 or 14 => Cyan,
        7 => White,
        8 => Dim,
        15 => Text,
        _ => null,
    };

    // The color of a terminal color. With invert, the colors that do not
    // come from the theme get the opposite lightness, see TermText.InvertLightness.
    public static Brush Color(TermColor c, bool invert = false)
    {
        if (c.Kind == TermColorKind.Indexed && Palette(c.Value) is { } p)
        {
            return p;
        }
        var v = TermText.FixedRgb(c) ?? 0xC0CAF5;
        return Rgb(invert ? TermText.InvertLightness(v) : v);
    }

    static Brush Pick(int light, int dark) => Rgb(Tn.Current.Dark ? dark : light);

    public static SolidColorBrush Rgb(int v)
    {
        if (!Brushes.TryGetValue(v, out var b))
        {
            b = new SolidColorBrush(ThemeColors.ColorOf(v));
            b.Freeze();
            Brushes[v] = b;
        }
        return b;
    }
}

// Terminal lines in the colors of the app. A long line wraps, and its
// wrapped rows line up with its text. A line with a fill shows the fill up
// to the right edge, so that the panels of an agent look like panels. When
// the text colors suit the other mode than the app, the view inverts their
// lightness. Every cell has the same width, as in a terminal: the view draws
// each run of text at its cell, and draws the panel bars and the block
// elements as shapes. TermRows.swift of the Mac app has the same drawing.
public sealed class TermLinesView : FrameworkElement
{
    // The side padding of each output line. The fill of a line goes under it.
    public const double Pad = 12;

    // The height of 1 row of output.
    public const double RowHeight = 16;

    // The size of the output font.
    public const double FontSize = 12;

    // The fewest columns that the view assumes, for a very narrow window.
    const int MinCols = 20;

    static double? cell;

    readonly IReadOnlyList<TermLine> lines;
    readonly bool invert;
    List<(TermLine Line, TermRowLayout Layout)> rows = [];
    int cols = -1;
    int rowCount;

    public TermLinesView(IReadOnlyList<TermLine> lines)
    {
        this.lines = lines;
        invert = TermText.Tone(lines) is { } tone && (tone == TermTone.Dark) != Tn.Current.Dark;
        SnapsToDevicePixels = true;
        HorizontalAlignment = HorizontalAlignment.Stretch;
    }

    // The width of 1 cell of the output font.
    public static double Cell => cell ??= Formatted("0000000000", null, new TermStyle(), 1).WidthIncludingTrailingWhitespace / 10;

    static FormattedText Formatted(string text, Brush? ink, TermStyle style, double pixelsPerDip)
    {
        var face = new Typeface(Faces.Mono, style.Italic ? FontStyles.Italic : FontStyles.Normal,
            style.Bold ? FontWeights.Bold : FontWeights.Normal, FontStretches.Normal);
        var f = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, face, FontSize,
            ink ?? System.Windows.Media.Brushes.Black, pixelsPerDip);
        var decorations = new TextDecorationCollection();
        if (style.Underline)
        {
            decorations.Add(TextDecorations.Underline);
        }
        if (style.Strike)
        {
            decorations.Add(TextDecorations.Strikethrough);
        }
        if (decorations.Count > 0)
        {
            f.SetTextDecorations(decorations);
        }
        return f;
    }

    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsInfinity(available.Width) ? 640 : available.Width;
        var next = Math.Max(MinCols, (int)((width - Pad * 2) / Cell));
        if (next != cols)
        {
            cols = next;
            rows = TermText.Fit(lines, cols).Select(l => (l, new TermRowLayout(l, cols))).ToList();
            rowCount = rows.Sum(r => Math.Max(1, r.Item2.Rows.Count));
            InvalidateVisual();
        }
        return new Size(double.IsInfinity(available.Width) ? width : available.Width, rowCount * RowHeight);
    }

    Brush Color(TermColor c) => TermColors.Color(c, invert);

    // The color of a background, or null for the background of the view.
    // With invert, a black background is the background of the view and
    // not white, because the agent drew it for a dark terminal. An example
    // is the logo of Claude Code.
    Brush? Background(TermColor c)
    {
        if (invert && TermText.FixedRgb(c) is { } v && (v >> 16 & 0xFF) <= 0x10 && (v >> 8 & 0xFF) <= 0x10 && (v & 0xFF) <= 0x10)
        {
            return null;
        }
        return Color(c);
    }

    Brush Fg(TermRowLayout.Run run)
    {
        if (run.Inverse)
        {
            return run.Bg is { } b ? Color(b) : TermColors.Background;
        }
        var c = run.Fg is { } f ? Color(f) : TermColors.Text;
        if (!run.Style.Dim)
        {
            return c;
        }
        var dim = c.Clone();
        dim.Opacity = TermColors.DimAlpha;
        dim.Freeze();
        return dim;
    }

    Brush? Bg(TermRowLayout.Run run)
    {
        if (run.Inverse)
        {
            return run.Fg is { } f ? Color(f) : TermColors.Text;
        }
        return run.Bg is { } b ? Background(b) : null;
    }

    protected override void OnRender(DrawingContext dc)
    {
        var width = ActualWidth;
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var cellWidth = Cell;
        double y = 0;
        foreach (var (line, layout) in rows)
        {
            var height = Math.Max(1, layout.Rows.Count) * RowHeight;
            DrawBackground(dc, line, layout, y, width, height, cellWidth);
            DrawText(dc, layout, y, cellWidth, dpi);
            DrawShapes(dc, layout, y, height, cellWidth);
            y += height;
        }
    }

    // Draws the fill of the line and the backgrounds of its cells over the
    // full height of each row.
    void DrawBackground(DrawingContext dc, TermLine line, TermRowLayout layout, double y, double width, double height, double cellWidth)
    {
        if (line.Fill is { } fillColor && Background(fillColor) is { } fill)
        {
            var x = Math.Min(width, Pad + (layout.FillCol == 0 ? layout.EdgeCols : layout.FillCol) * cellWidth);
            if (layout.FillCol == 0)
            {
                dc.DrawRectangle(layout.Edge is { } edge ? Background(edge) ?? fill : fill, null, new Rect(0, y, x, height));
            }
            dc.DrawRectangle(fill, null, new Rect(x, y, Math.Max(0, width - x), height));
        }
        foreach (var run in layout.Runs)
        {
            if (Bg(run) is not { } bg)
            {
                continue;
            }
            for (var r = 0; r < layout.Rows.Count; r++)
            {
                var range = layout.Rows[r];
                var lo = Math.Max(run.Start, range.Start);
                var hi = Math.Min(run.End, range.End);
                if (lo >= hi || layout.Place(lo) is not { } start)
                {
                    continue;
                }
                var rect = new Rect(Math.Round(Pad + start.Col * cellWidth), y + r * RowHeight, Math.Round((hi - lo) * cellWidth), RowHeight);
                dc.DrawRectangle(bg, null, rect);
            }
        }
    }

    // Draws the text of each run at its cells. The glyphs of the bar and of
    // block elements do not show, because the font draws them shorter than
    // the row. DrawShapes draws them, as a terminal does.
    void DrawText(DrawingContext dc, TermRowLayout layout, double y, double cellWidth, double dpi)
    {
        var hidden = new HashSet<int>(layout.Blocks.Select(b => b.Offset));
        if (layout.Bar is { } bar)
        {
            hidden.Add(bar.Col);
        }
        foreach (var run in layout.Runs)
        {
            Brush? ink = null;
            for (var r = 0; r < layout.Rows.Count; r++)
            {
                var range = layout.Rows[r];
                var lo = Math.Max(run.Start, range.Start);
                var hi = Math.Min(run.End, range.End);
                var i = lo;
                while (i < hi)
                {
                    var clear = hidden.Contains(i);
                    var j = i + 1;
                    while (j < hi && hidden.Contains(j) == clear)
                    {
                        j++;
                    }
                    if (!clear && layout.Place(i) is { } at)
                    {
                        var text = string.Concat(layout.Cells.Skip(i).Take(j - i));
                        if (text.Trim().Length > 0 || run.Style.Underline || run.Style.Strike)
                        {
                            ink ??= Fg(run);
                            var f = Formatted(text, ink, run.Style, dpi);
                            dc.DrawText(f, new Point(Pad + at.Col * cellWidth, y + at.Row * RowHeight + (RowHeight - f.Height) / 2));
                        }
                    }
                    i = j;
                }
            }
        }
    }

    // Draws the panel bar over the full height of the line, and the block
    // elements in their cells. The edges snap to whole pixels, so that the
    // blocks of a drawing join with no seams.
    void DrawShapes(DrawingContext dc, TermRowLayout layout, double y, double height, double cellWidth)
    {
        TermRowLayout.Run? RunAt(int offset) => layout.Runs.FirstOrDefault(r => r.Start <= offset && offset < r.End);
        if (layout.Bar is { } bar && RunAt(bar.Col) is { } barRun)
        {
            var w = Math.Max(1, cellWidth * bar.Width);
            dc.DrawRectangle(Fg(barRun), null, new Rect(Pad + bar.Col * cellWidth + (cellWidth - w) / 2, y, w, height));
        }
        foreach (var (offset, shape) in layout.Blocks)
        {
            if (RunAt(offset) is not { } run || layout.Place(offset) is not { } p)
            {
                continue;
            }
            var brush = Fg(run).Clone();
            brush.Opacity *= shape.Alpha;
            brush.Freeze();
            var cellX = Pad + p.Col * cellWidth;
            var cellY = y + p.Row * RowHeight;
            foreach (var rect in shape.Rects)
            {
                var left = Math.Round(cellX + rect.Left * cellWidth);
                var right = Math.Round(cellX + rect.Right * cellWidth);
                var top = Math.Round(cellY + rect.Top * RowHeight);
                var bottom = Math.Round(cellY + rect.Bottom * RowHeight);
                dc.DrawRectangle(brush, null, new Rect(left, top, Math.Max(0, right - left), Math.Max(0, bottom - top)));
            }
        }
    }
}
