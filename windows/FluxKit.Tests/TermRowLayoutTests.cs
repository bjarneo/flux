using FluxKit;

namespace FluxKit.Tests;

// The screen layout of output lines: wrapping, fills, panel bars, and block
// elements. Ported from TermRowLayoutTests.swift.
public class TermRowLayoutTests
{
    static string[] Wrap(string s, int cols, int hang = 0) =>
        TermRowLayout.Wrap(s, cols, hang).Select(r => s[r.Start..r.End]).ToArray();

    [Fact]
    public void WrapsAtBlanks()
    {
        Assert.Equal(["short"], Wrap("short", 10));
        // An empty line keeps 1 row.
        Assert.Equal([""], Wrap("", 10));
        Assert.Equal(["one two ", "three four", "five"], Wrap("one two three four five", 10));
        // A long word breaks at the edge.
        Assert.Equal(["abcde", "fghij", "klmn"], Wrap("abcdefghijklmn", 5));
        // The blanks at a break between words go.
        Assert.Equal(["abcde", "fgh"], Wrap("abcde   fgh", 5));
    }

    [Fact]
    public void WrappedRowsStartAtTheHang()
    {
        // The wrapped rows are cols - hang wide.
        Assert.Equal(["┃  aaaa ", "bbbb ", "cccc"], Wrap("┃  aaaa bbbb cccc", 10, 3));
        var layout = new TermRowLayout(new TermLine([new TermSpan("┃  aaaa bbbb cccc")]), 10);
        Assert.Equal(3, layout.Hang);
        Assert.Equal(1, layout.Place(8)?.Row);
        // A wrapped row starts under the text, after the bar.
        Assert.Equal(3, layout.Place(8)?.Col);
        Assert.Null(layout.Place(99));
    }

    [Fact]
    public void AHangOverHalfTheWidthIsNotUsed()
    {
        var layout = new TermRowLayout(new TermLine([new TermSpan("            - a long item that wraps")]), 20);
        Assert.Equal(0, layout.Hang);
    }

    [Fact]
    public void FindsThePanelBarAndTheFill()
    {
        var panel = TermColor.Rgb(0x2B2E31);
        var line = new TermLine([new TermSpan("┃", new TermStyle(TermColor.Rgb(0xF0C674), panel)), new TermSpan("  Add a test", new TermStyle(Bg: panel))], panel);
        var layout = new TermRowLayout(line, 40);
        Assert.Equal(0, layout.Bar?.Col);
        Assert.Equal(TermRowLayout.HeavyBar, layout.Bar?.Width);
        // The fill starts at the first cell with a background.
        Assert.Equal(0, layout.FillCol);
        // The left padding gets the panel background.
        Assert.Equal(panel, layout.Edge);
        Assert.Equal(13, layout.EdgeCols);
    }

    [Fact]
    public void TheFillStartsAfterPlainText()
    {
        var added = TermColor.Rgb(0x3E4231);
        var line = new TermLine([new TermSpan("  5 "), new TermSpan("+ code", new TermStyle(Bg: added))], added);
        var layout = new TermRowLayout(line, 40);
        Assert.Equal(4, layout.FillCol);
        Assert.Null(layout.Edge);
        Assert.Null(layout.Bar);
        Assert.Equal(TermRowLayout.LightBar, new TermRowLayout(new TermLine([new TermSpan("│ x")]), 40).Bar?.Width);
    }

    [Fact]
    public void AnEmptyPanelRowGetsTheFillAsItsEdge()
    {
        var panel = TermColor.Rgb(0x2B2E31);
        var layout = new TermRowLayout(new TermLine([], panel), 40);
        Assert.Equal(panel, layout.Edge);
        Assert.Equal([new CellRange(0, 0)], layout.Rows);
    }

    [Fact]
    public void FindsTheBlockElements()
    {
        var layout = new TermRowLayout(new TermLine([new TermSpan("█▀▀█ x ▄")]), 40);
        Assert.Equal([0, 1, 2, 3, 7], layout.Blocks.Select(b => b.Offset));
        Assert.Equal(TermText.BlockShapeOf("█"), layout.Blocks[0].Shape);
    }

    [Fact]
    public void EqualLinesGiveEqualLayouts()
    {
        var a = new TermRowLayout(new TermLine([new TermSpan("┃  █ a")]), 20);
        var b = new TermRowLayout(new TermLine([new TermSpan("┃  █ a")]), 20);
        Assert.Equal(a, b);
        Assert.NotEqual(a, new TermRowLayout(new TermLine([new TermSpan("┃  █ b")]), 20));
    }
}
