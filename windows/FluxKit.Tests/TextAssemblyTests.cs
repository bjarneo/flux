using FluxKit;

namespace FluxKit.Tests;

// TextAssemblyTests.swift of the Mac app.
public class TextAssemblyTests
{
    static ScanBlock Block(int left, int top, int right, int bottom, params string[] lines)
    {
        var h = lines.Length == 0 ? 0 : (bottom - top) / lines.Length;
        return new ScanBlock(lines.Select((t, i) => new ScanLine(t, new ScanBox(left, top + i * h, right, top + (i + 1) * h))),
            new ScanBox(left, top, right, bottom));
    }

    [Fact]
    public void StackedBlocksReadTopToBottom()
    {
        var title = Block(10, 10, 300, 40, "Invoice 0925");
        var body = Block(10, 80, 300, 140, "Total 12.40", "Due 30 Sep");
        Assert.Equal("Invoice 0925\n\nTotal 12.40\nDue 30 Sep", TextAssembly.Assemble([body, title]));
    }

    [Fact]
    public void BlocksInOneRowReadLeftToRight()
    {
        var right = Block(200, 12, 300, 38, "B14");
        var left = Block(10, 10, 120, 40, "Gate");
        var below = Block(10, 60, 300, 90, "Boarding 15:40");
        Assert.Equal(["Gate", "B14", "Boarding 15:40"], TextAssembly.ReadingOrder([below, right, left]).Select(b => b.Lines[0].Text));
    }

    [Fact]
    public void SmallOverlapStartsANewRow()
    {
        var a = Block(200, 0, 300, 40, "first");
        var b = Block(10, 30, 120, 70, "second");
        Assert.Equal(["first", "second"], TextAssembly.ReadingOrder([b, a]).Select(x => x.Lines[0].Text));
    }

    [Fact]
    public void LinesInABlockFollowTheirPosition()
    {
        var b = new ScanBlock([new ScanLine("second", new ScanBox(0, 30, 100, 50)), new ScanLine("first", new ScanBox(0, 0, 100, 20))], new ScanBox(0, 0, 100, 50));
        Assert.Equal("first\nsecond", TextAssembly.Assemble([b]));
    }

    [Fact]
    public void SplitWordsJoin() => Assert.Equal("the configuration file", TextAssembly.JoinLines(["the configu-", "ration file"]));

    [Fact]
    public void HyphenBeforeCapitalStays() => Assert.Equal("Omarchy-\nFlux", TextAssembly.JoinLines(["Omarchy-", "Flux"]));

    [Fact]
    public void DashAloneStays() => Assert.Equal("price -\nsee below", TextAssembly.JoinLines(["price -", "see below"]));

    [Fact]
    public void BlankLinesAndBlocksDrop()
    {
        var empty = Block(0, 0, 10, 10);
        var spaces = Block(0, 20, 100, 40, "   ");
        var text = Block(0, 50, 100, 70, "  ssh deploy@10.0.4.12  ");
        Assert.Equal("ssh deploy@10.0.4.12", TextAssembly.Assemble([empty, spaces, text]));
    }

    [Fact]
    public void NothingGivesEmptyText() => Assert.Equal("", TextAssembly.Assemble([]));

    // OCR lines to blocks

    [Fact]
    public void ParagraphLinesFormOneBlock()
    {
        ScanLine[] lines =
        [
            new("Due 30 Sep", new ScanBox(10, 130, 180, 150)),
            new("Total 12.40", new ScanBox(10, 100, 200, 120)),
            new("Invoice 0925", new ScanBox(10, 10, 400, 50)),
        ];
        Assert.Equal("Invoice 0925\n\nTotal 12.40\nDue 30 Sep", TextAssembly.Assemble(TextAssembly.Blocks(lines)));
    }

    [Fact]
    public void ColumnsFormSeparateBlocks()
    {
        ScanLine[] lines =
        [
            new("left one", new ScanBox(10, 10, 200, 30)),
            new("right one", new ScanBox(400, 10, 600, 30)),
            new("left two", new ScanBox(10, 36, 190, 56)),
            new("right two", new ScanBox(400, 36, 590, 56)),
        ];
        Assert.Equal("left one\nleft two\n\nright one\nright two", TextAssembly.Assemble(TextAssembly.Blocks(lines)));
    }

    [Fact]
    public void PiecesOfALineJoin()
    {
        ScanLine[] lines = [new("12.40", new ScanBox(130, 12, 190, 32)), new("Total", new ScanBox(10, 10, 110, 30))];
        Assert.Equal("Total 12.40", TextAssembly.Assemble(TextAssembly.Blocks(lines)));
    }
}
