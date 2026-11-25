namespace FluxKit;

// A rectangle in pixels. The origin is the top left corner.
public readonly record struct ScanBox(int Left, int Top, int Right, int Bottom)
{
    public int Width => Right - Left;
    public int Height => Bottom - Top;

    internal ScanBox Union(ScanBox o) =>
        new(Math.Min(Left, o.Left), Math.Min(Top, o.Top), Math.Max(Right, o.Right), Math.Max(Bottom, o.Bottom));
}

// One line of recognized text.
public sealed record ScanLine(string Text, ScanBox Box);

// One block of recognized text, such as a paragraph or a label.
public sealed record ScanBlock(ValueList<ScanLine> Lines, ScanBox Box)
{
    public ScanBlock(IEnumerable<ScanLine> lines, ScanBox box)
        : this(ValueList.From(lines), box)
    {
    }
}

// Turns recognized blocks into plain text. The recognizer returns blocks in
// no fixed order, so this puts them in reading order: rows from top to
// bottom, and blocks in a row from left to right. TextAssembly.swift of the
// Mac app has the same rules.
public static class TextAssembly
{
    // The part of the smaller height that 2 blocks must share vertically to
    // be in the same row.
    const double RowOverlap = 0.5;

    // Returns the text of the blocks. An empty line separates the blocks.
    public static string Assemble(IEnumerable<ScanBlock> blocks) => string.Join("\n\n",
        ReadingOrder(blocks)
            .Select(b => JoinLines(b.Lines.OrderBy(l => l.Box.Top).ThenBy(l => l.Box.Left).Select(l => l.Text)))
            .Where(t => t.Length > 0));

    // Returns the blocks in reading order.
    public static IReadOnlyList<ScanBlock> ReadingOrder(IEnumerable<ScanBlock> blocks)
    {
        var rows = new List<List<ScanBlock>>();
        // OrderBy is a stable sort, like sortedBy of Kotlin.
        foreach (var b in blocks.OrderBy(b => b.Box.Top))
        {
            if (rows.Count > 0 && rows[^1].Any(o => SameRow(o.Box, b.Box)))
            {
                rows[^1].Add(b);
            }
            else
            {
                rows.Add([b]);
            }
        }
        return rows.SelectMany(r => r.OrderBy(b => b.Box.Left)).ToArray();
    }

    // Joins the lines of 1 block. Each line keeps its own row, so lists,
    // addresses, and code stay as they are. A word that the line end splits
    // with a hyphen becomes whole again.
    public static string JoinLines(IEnumerable<string> lines)
    {
        var output = "";
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.Length == 0)
            {
                continue;
            }
            if (output.Length == 0)
            {
                output = line;
            }
            else if (EndsWithSplitWord(output) && char.IsLower(line, 0))
            {
                output = output[..^1] + line;
            }
            else
            {
                output += "\n" + line;
            }
        }
        return output;
    }

    static bool EndsWithSplitWord(string text) =>
        text.Length >= 2 && text[^1] == '-' && char.IsLetter(text[^2]);

    static bool SameRow(ScanBox a, ScanBox b)
    {
        var overlap = Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top);
        var smaller = Math.Min(a.Height, b.Height);
        return smaller > 0 && overlap >= smaller * RowOverlap;
    }

    // Lines to blocks

    // Groups recognized lines into blocks. ML Kit on Android returns blocks,
    // but the OCR of Windows returns lines. Lines join a block when they are
    // stacked closely with similar heights and overlap horizontally, like the
    // lines of a paragraph. Pieces of 1 line that sit next to each other join
    // into 1 line first.
    public static IReadOnlyList<ScanBlock> Blocks(IEnumerable<ScanLine> lines)
    {
        var blocks = new List<(List<ScanLine> Lines, ScanBox Box)>();
        foreach (var line in MergePieces(lines))
        {
            // The nearest block above wins.
            var best = -1;
            for (var i = 0; i < blocks.Count; i++)
            {
                if (Continues(blocks[i].Lines[^1], line) &&
                    (best < 0 || line.Box.Top - blocks[i].Box.Bottom < line.Box.Top - blocks[best].Box.Bottom))
                {
                    best = i;
                }
            }
            if (best >= 0)
            {
                blocks[best].Lines.Add(line);
                blocks[best] = (blocks[best].Lines, blocks[best].Box.Union(line.Box));
            }
            else
            {
                blocks.Add(([line], line.Box));
            }
        }
        return blocks.Select(b => new ScanBlock(b.Lines, b.Box)).ToArray();
    }

    // True when the line is the next line of the paragraph whose last line is last.
    static bool Continues(ScanLine last, ScanLine line)
    {
        var a = last.Box;
        var b = line.Box;
        var height = Math.Max(a.Height, b.Height);
        if (height <= 0 || Math.Min(a.Height, b.Height) * 5 < height * 3)
        {
            return false;
        }
        var gap = b.Top - a.Bottom;
        // The same integer division as the Mac, which rounds toward zero.
        if (gap < -height / 2 || gap * 5 > height * 4)
        {
            return false;
        }
        var overlap = Math.Min(a.Right, b.Right) - Math.Max(a.Left, b.Left);
        return overlap > 0 || Math.Abs(a.Left - b.Left) <= height;
    }

    // Joins pieces of 1 line: they share most of their height and the gap
    // between them is at most the line height.
    static List<ScanLine> MergePieces(IEnumerable<ScanLine> lines)
    {
        var output = new List<ScanLine>();
        foreach (var line in lines.OrderBy(l => l.Box.Left).ThenBy(l => l.Box.Top))
        {
            var text = line.Text.Trim(' ', '\t');
            if (text.Length == 0)
            {
                continue;
            }
            var at = output.FindLastIndex(piece =>
            {
                var gap = line.Box.Left - piece.Box.Right;
                return SameRow(piece.Box, line.Box) && gap >= -piece.Box.Height && gap <= Math.Max(piece.Box.Height, line.Box.Height);
            });
            if (at >= 0)
            {
                output[at] = new ScanLine(output[at].Text + " " + text, output[at].Box.Union(line.Box));
            }
            else
            {
                output.Add(new ScanLine(text, line.Box));
            }
        }
        return output.OrderBy(l => l.Box.Top).ThenBy(l => l.Box.Left).ToList();
    }
}
