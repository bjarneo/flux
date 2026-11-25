using System.Text.RegularExpressions;

namespace FluxKit;

// The screen layout of terminal text: full-screen agents such as opencode
// draw panels across a wide terminal, and a phone screen or a window pane is
// narrower. This is a port of TermPhone.swift of the Mac app and of the
// layout functions of TermText.kt of the Android app, so all apps show the
// same output.

// The tone of the background that the colors of an output suit.
public enum TermTone
{
    Dark,
    Light,
}

// A rectangle in a cell, in fractions of the cell width and height from the
// top left corner.
public readonly record struct CellRect(double Left, double Top, double Right, double Bottom);

// How a block element fills its cell: rectangles in the text color, with
// Alpha for a shade.
public sealed record BlockShape(ValueList<CellRect> Rects, double Alpha = 1)
{
    public BlockShape(IEnumerable<CellRect> rects, double alpha = 1)
        : this(ValueList.From(rects), alpha)
    {
    }
}

public static partial class TermText
{
    // The bars at the left side of a panel, for example of a message in opencode.
    internal static bool IsBar(char c) => c is '┃' or '│' or '║' or '▌' or '▎' or '▏';

    // The right sides of boxes. A line that ends in one is a row of a box.
    static bool IsBoxSide(char c) => c is '│' or '┃' or '║';
    static bool IsBoxTop(char c) => c is '╭' or '┌' or '╔' or '┏';
    static bool IsBoxTopEnd(char c) => c is '╮' or '┐' or '╗' or '┓';
    static bool IsBoxBottom(char c) => c is '╰' or '└' or '╚' or '┗';
    static bool IsBoxBottomEnd(char c) => c is '╯' or '┘' or '╝' or '┛';

    // The joins of a table. A box with one of them in its top edge is a
    // table, and OpenBoxes keeps it.
    const string TableJoins = "┬┴┼├┤╤╧╪╦╩╬┳┻╋";

    // A run of rule characters must be this long to count as a rule.
    internal const int RuleMin = 8;

    // The shortest run that a rule keeps when Fit shortens it.
    const int RuleKeep = 3;

    // The columns at the right edge that an agent can keep free when it
    // wraps a line, for example for the margin of a panel.
    const int WrapSlack = 2;

    // A lone block after this many blanks at the end of a line is the thumb of a scroll bar.
    const int ScrollBarGap = 4;

    // The caps at the ends of a box edge, see IsBoxEdge.
    static bool IsEdgeCap(char c) => c is '╵' or '╷' or '╹' or '╻';

    // A sidebar starts at this column or later, see DropSidebar.
    const int SidebarMinCol = 40;

    // The widest sidebar, in columns.
    const int SidebarMaxWidth = 60;

    // The fewest lines that end in a sidebar.
    const int SidebarMinRows = 4;

    // A block must start at this column or later to move, see Fit. Text in
    // a column near the left keeps its place.
    const int FitMinLead = 8;

    // Text with a luminance of at least this value is light.
    const double LightText = 0.3;

    // Text with a luminance of at most this value is dark.
    const double DarkText = 0.1;

    // Makes terminal lines fit a screen. It removes the blanks at the end
    // of each line, scroll bars, and the edges of boxes. It joins the rows
    // that the agent wrapped at the width of the terminal, see Reflow. It
    // also removes the blank columns that all lines share at the start, and
    // the extra empty rows, because full-screen agents such as opencode fill
    // the terminal with them. Fit then fits the rules, boxes, and drawings
    // to the width of the screen.
    public static IReadOnlyList<TermLine> Tidy(IReadOnlyList<TermLine> lines)
    {
        var rows = DropSidebar(DropSessionTabs(lines));
        var width = TermWidth(rows);
        var output = new List<TermLine>();
        foreach (var line in rows)
        {
            var trimmed = TrimEndKeepingFill(DropScrollBar(line));
            if (!IsBoxEdge(trimmed.Text.Trim()))
            {
                output.Add(trimmed);
            }
        }
        var joined = Reflow(output, width);
        var margin = joined.Where(l => l.Spans.Count > 0).Select(LeadingBlanks).DefaultIfEmpty(0).Min();
        var result = DropEmptyRows(margin == 0 ? joined : joined.Select(l => DropColumns(l, margin)).ToList());
        if (width > 0)
        {
            for (var i = 0; i < result.Count; i++)
            {
                result[i] = result[i] with { Cols = width - margin };
            }
        }
        return result;
    }

    // The start and the length of the longest run of 1 rule character.
    internal static (int Start, int Count) LongestRule(CellText chars)
    {
        var best = (Start: 0, Count: 0);
        var i = 0;
        while (i < chars.Count)
        {
            var j = i + 1;
            var c = chars.Single(i);
            if (IsRuleChar(c))
            {
                while (j < chars.Count && chars.Single(j) == c)
                {
                    j++;
                }
                if (j - i > best.Count)
                {
                    best = (i, j - i);
                }
            }
            i = j;
        }
        return best;
    }

    // Returns the width of the terminal in columns, or 0 when the lines do
    // not show it. The widest line shows the width when it ends in blanks,
    // which a screen row with a background has, or when it holds a rule. A
    // plain read has no blanks at the end, so its widest line can be
    // narrower than the terminal.
    static int TermWidth(IReadOnlyList<TermLine> lines)
    {
        var texts = lines.Select(l => new CellText(l.Text)).ToArray();
        var width = texts.Select(t => t.Count).DefaultIfEmpty(0).Max();
        if (width <= 0)
        {
            return 0;
        }
        var shown = texts.Any(t => t.Count == width && (t.Single(t.Count - 1) == ' ' || LongestRule(t).Count >= RuleMin));
        return shown ? width : 0;
    }

    // Joins the rows that an agent wrapped at the terminal width into 1
    // line. Claude Code, Codex, and opencode wrap their text at the width of
    // the terminal, so on a narrow screen each row breaks again and leaves a
    // short piece. The screen then wraps the joined line at its own width. A
    // row continues the line above it when the first word of the row did not
    // fit at the end of the line above, and when the row starts at the
    // hanging indent of that line, under the same panel bar and with the
    // same fill. A row with a list marker starts a new line. Rules and the
    // rows of a box stay as they are. Without a known width, the lines stay
    // as they are.
    static List<TermLine> Reflow(List<TermLine> lines, int width)
    {
        if (width <= 0)
        {
            return lines;
        }
        var output = new List<TermLine>(lines.Count);
        // The length of the last row of the last line, or 0 when no row can join it.
        var end = 0;
        var hang = 0;
        // The first row of the last line. Its panel bars must be in the next row too.
        var first = new CellText("");
        foreach (var line in lines)
        {
            var text = new CellText(line.Text);
            if (output.Count > 0 && output[^1] is { Spans.Count: > 0 } prev && end > 0 && 2 * end >= width &&
                line.Fill == prev.Fill && Continues(first, text, hang))
            {
                var space = -1;
                for (var k = hang; k < text.Count; k++)
                {
                    if (text.Single(k) == ' ')
                    {
                        space = k;
                        break;
                    }
                }
                var word = (space >= 0 ? space : text.Count) - hang;
                if (end + 1 + word > width - WrapSlack)
                {
                    var gap = prev.Spans[^1].Style with { Underline = false, Strike = false };
                    var rest = DropColumns(line, hang);
                    TermSpan[] blank = WrapsInWord(prev.Text, rest.Text) ? [] : [new TermSpan(" ", gap)];
                    output[^1] = new TermLine(prev.Spans.Concat(blank).Concat(rest.Spans), prev.Fill);
                    end = CanContinue(text) ? text.Count : 0;
                    continue;
                }
            }
            output.Add(line);
            first = text;
            end = CanContinue(text) ? text.Count : 0;
            hang = HangingIndent(line.Text);
        }
        return output;
    }

    // True when a wrapped line broke inside a word, so that the rows join
    // without a blank. opencode can break a path or a link after a slash, a
    // word after a hyphen, and a path after a dot, for example "src/" and
    // "pages/a.ts", "--" and "workers=2", or "share.test." and "ts". A colon
    // before 2 slashes is a link, for example "https:" and "//github.com".
    public static bool WrapsInWord(string prev, string next)
    {
        var space = prev.LastIndexOf(' ');
        var token = space >= 0 ? prev[(space + 1)..] : prev;
        if (next.Length == 0 || TermCells.Count(token) < 2 || next[0] == ' ')
        {
            return false;
        }
        var alnum = TermCells.StartsWithLetterOrNumber(next);
        var stem = token[..^1];
        if (token.EndsWith('/'))
        {
            return true;
        }
        if (token.EndsWith(':') && next.StartsWith("//", StringComparison.Ordinal))
        {
            return true;
        }
        if (token.EndsWith('-') || token.EndsWith('_'))
        {
            return alnum;
        }
        if (token.EndsWith('.') && (stem.Contains('/') || stem.Contains('.')))
        {
            return alnum;
        }
        return false;
    }

    // Joins 2 rows of a wrapped line, with a blank between them unless the
    // line broke inside a word, see WrapsInWord.
    public static string JoinWrapped(string prev, string next) => WrapsInWord(prev, next) ? prev + next : prev + " " + next;

    // True when the next row can continue a line that ends with row: the
    // row has text, and it is not a rule or a row of a box.
    static bool CanContinue(CellText row)
    {
        if (row.Count == 0)
        {
            return false;
        }
        var text = false;
        for (var i = 0; i < row.Count; i++)
        {
            if (row.Single(i) != ' ')
            {
                text = true;
                break;
            }
        }
        return text && !IsBoxSide(row.Single(row.Count - 1)) && LongestRule(row).Count < RuleMin;
    }

    // True when row can continue the line with the first row prev, which
    // wraps at column hang. Before that column, the row has only blanks and
    // the panel bars of the line. At that column, its text starts, without
    // a list marker.
    static bool Continues(CellText prev, CellText row, int hang)
    {
        if (hang >= row.Count || row.Single(hang) == ' ' || !CanContinue(row))
        {
            return false;
        }
        for (var i = 0; i < hang; i++)
        {
            var c = row.Single(i);
            if (c == ' ')
            {
                continue;
            }
            if (!IsBar(c) || i >= prev.Count || prev.Single(i) != c)
            {
                return false;
            }
        }
        return !ListMarker.IsMatch(row.Slice(hang, row.Count));
    }

    static readonly Regex SessionMarker = new(@"^\s*\+ New session\s*$", RegexOptions.CultureInvariant);
    static readonly Regex SessionTitle = new(@"^\s*(?:\d+|[!?●•·⠁-⣿])?\s+\S", RegexOptions.CultureInvariant);

    static int CellCount(TermSpan s) => TermCells.Count(s.Text);

    // Drops the expanded session tabs of OpenCode V2 at the left, without
    // moving the plain history above them. The tabs are a column of cells
    // with a background, from 8 to 60 columns wide, with the New session row
    // and at least 1 session title.
    static IReadOnlyList<TermLine> DropSessionTabs(IReadOnlyList<TermLine> lines)
    {
        for (var index = 0; index < lines.Count; index++)
        {
            var line = lines[index];
            var col = 0;
            foreach (var span in line.Spans)
            {
                if (span.Style.Bg is null || span.Style.Inverse)
                {
                    break;
                }
                col += CellCount(span);
            }
            if (col is < 8 or > 60 || !SessionMarker.IsMatch(TermCells.Prefix(line.Text, col)))
            {
                continue;
            }
            bool InRail(TermLine row)
            {
                var at = 0;
                foreach (var span in row.Spans)
                {
                    if (at >= col)
                    {
                        return true;
                    }
                    if (span.Style.Bg is null || span.Style.Inverse)
                    {
                        return false;
                    }
                    at += CellCount(span);
                }
                return at >= col;
            }
            var start = index;
            var end = index + 1;
            while (start > 0 && InRail(lines[start - 1]))
            {
                start--;
            }
            while (end < lines.Count && InRail(lines[end]))
            {
                end++;
            }
            if (end - start < SidebarMinRows)
            {
                continue;
            }
            var hasTitle = false;
            for (var k = start; k < end; k++)
            {
                var prefix = TermCells.Prefix(lines[k].Text, col);
                if (!SessionMarker.IsMatch(prefix) && SessionTitle.IsMatch(prefix))
                {
                    hasTitle = true;
                    break;
                }
            }
            if (!hasTitle)
            {
                continue;
            }
            return lines.Select((row, i) => i >= start && i < end ? DropColumns(row, col) : row).ToArray();
        }
        return lines;
    }

    // True for the top or bottom edge of a box that half blocks draw, for
    // example the prompt box of opencode: at least 8 upper or 8 lower half
    // blocks, with an optional cap at each end.
    static bool IsBoxEdge(string text)
    {
        var c = new CellText(text);
        var from = 0;
        var to = c.Count;
        if (to > from && IsEdgeCap(c.Single(from)))
        {
            from++;
        }
        if (to > from && IsEdgeCap(c.Single(to - 1)))
        {
            to--;
        }
        if (to - from < 8)
        {
            return false;
        }
        var first = c.Single(from);
        if (first is not ('▀' or '▄'))
        {
            return false;
        }
        for (var i = from; i < to; i++)
        {
            if (c.Single(i) != first)
            {
                return false;
            }
        }
        return true;
    }

    readonly record struct RunEnd(int Col, TermColor Bg);

    // Removes the sidebar at the right of a full-screen agent, for example
    // the sidebar that opencode shows in a wide terminal. Each line holds a
    // row of the conversation and a row of the sidebar, so on a narrow
    // screen the two mix. A sidebar is a column of cells with 1 background,
    // from the same column to the end of the lines. At least SidebarMinRows
    // lines must end in it, and no line can have other cells there.
    static IReadOnlyList<TermLine> DropSidebar(IReadOnlyList<TermLine> lines)
    {
        var ends = new Dictionary<RunEnd, int>();
        foreach (var line in lines)
        {
            if (EndRun(line) is { } end)
            {
                ends[end] = ends.GetValueOrDefault(end) + 1;
            }
        }
        if (ends.Count == 0)
        {
            return lines;
        }
        // The most lines win. Between equal counts the leftmost column wins,
        // so that the result does not depend on the order of the dictionary.
        var (start, count) = ends.OrderByDescending(e => e.Value).ThenBy(e => e.Key.Col).Select(e => (e.Key, e.Value)).First();
        if (count < SidebarMinRows || start.Col < SidebarMinCol)
        {
            return lines;
        }
        if (lines.Select(l => TermCells.Count(l.Text)).DefaultIfEmpty(0).Max() - start.Col > SidebarMaxWidth)
        {
            return lines;
        }
        foreach (var line in lines)
        {
            var at = 0;
            foreach (var s in line.Spans)
            {
                var n = CellCount(s);
                if (at + n > start.Col && (s.Style.Inverse || s.Style.Bg != start.Bg))
                {
                    return lines;
                }
                at += n;
            }
        }
        return lines.Select(l => Take(l, start.Col)).ToArray();
    }

    // Returns the start column and the background of the run of cells with
    // 1 background at the end of a line, or null when the last cell has no
    // background.
    static RunEnd? EndRun(TermLine line)
    {
        if (line.Spans.Count == 0 || line.Spans[^1].Style is not { Inverse: false, Bg: { } bg })
        {
            return null;
        }
        var start = TermCells.Count(line.Text);
        for (var i = line.Spans.Count - 1; i >= 0; i--)
        {
            var s = line.Spans[i];
            if (s.Style.Inverse || s.Style.Bg != bg)
            {
                break;
            }
            start -= CellCount(s);
        }
        return new RunEnd(start, bg);
    }

    // True when a blank cell with this style shows no color.
    static bool Plain(TermStyle s) => s.Bg is null && !s.Inverse;

    // Removes the blanks at the end of a line. The background of the first
    // blank after the text becomes the fill of the line. A line with no text
    // gets the first background of its blanks.
    static TermLine TrimEndKeepingFill(TermLine line)
    {
        var spans = line.Spans.ToList();
        TermColor? fill = null;
        TermColor? blankFill = null;
        while (spans.Count > 0)
        {
            var last = spans[^1];
            var t = last.Text.TrimEnd();
            if (t.Length < last.Text.Length)
            {
                fill = Plain(last.Style) ? null : last.Style.Bg;
                if (fill is not null)
                {
                    blankFill = fill;
                }
            }
            if (t.Length > 0)
            {
                spans[^1] = last with { Text = t };
                return new TermLine(spans, fill);
            }
            spans.RemoveAt(spans.Count - 1);
        }
        return new TermLine(spans, blankFill);
    }

    // Removes the thumb of a scroll bar: a lone block at the end of a line,
    // after text and a gap of blanks. The cell becomes a blank with the same
    // style, so the line keeps its fill. A block with no text before it
    // stays, because it is part of a drawing, for example the logo of opencode.
    static TermLine DropScrollBar(TermLine line)
    {
        var text = new CellText(line.Text);
        var end = text.Count - 1;
        while (end >= 0 && text.Single(end) == ' ')
        {
            end--;
        }
        if (end <= ScrollBarGap || text.Single(end) is < '\u2580' or > '\u259F')
        {
            return line;
        }
        for (var i = end - ScrollBarGap; i < end; i++)
        {
            if (text.Single(i) != ' ')
            {
                return line;
            }
        }
        if (string.IsNullOrWhiteSpace(text.Slice(0, end)))
        {
            return line;
        }
        var offset = 0;
        var spans = line.Spans.Select(s =>
        {
            var chars = new CellText(s.Text);
            var i = end - offset;
            offset += chars.Count;
            if (i < 0 || i >= chars.Count)
            {
                return s;
            }
            return s with { Text = chars.Slice(0, i) + " " + chars.Slice(i + 1, chars.Count) };
        }).ToArray();
        return new TermLine(spans, line.Fill);
    }

    // The number of blank cells with no color at the start of a line.
    static int LeadingBlanks(TermLine line)
    {
        var n = 0;
        foreach (var s in line.Spans)
        {
            if (!Plain(s.Style))
            {
                return n;
            }
            var c = new CellText(s.Text);
            for (var i = 0; i < c.Count; i++)
            {
                if (c.Single(i) != ' ')
                {
                    return n;
                }
                n++;
            }
        }
        return n;
    }

    // Removes the first n cells of a line.
    static TermLine DropColumns(TermLine line, int n)
    {
        var output = new List<TermSpan>();
        var left = n;
        foreach (var s in line.Spans)
        {
            var count = CellCount(s);
            if (left >= count)
            {
                left -= count;
                continue;
            }
            output.Add(new TermSpan(TermCells.Drop(s.Text, left), s.Style));
            left = 0;
        }
        return new TermLine(output, line.Fill);
    }

    // True when a row shows no text. The bar of an empty panel row is not text.
    static bool IsEmptyRow(TermLine line)
    {
        var t = line.Text.Trim();
        return t.Length == 0 || t.Length == 1 && IsBar(t[0]);
    }

    // Removes the blank rows at the start and at the end, and keeps 1 row of
    // each run of equal empty rows.
    static List<TermLine> DropEmptyRows(IReadOnlyList<TermLine> lines)
    {
        var output = new List<TermLine>();
        foreach (var line in lines)
        {
            var blank = line.Spans.Count == 0 && line.Fill is null;
            if (blank && output.Count == 0 || IsEmptyRow(line) && output.Count > 0 && output[^1] == line)
            {
                continue;
            }
            output.Add(line);
        }
        while (output.Count > 0 && output[^1] is { Spans.Count: 0, Fill: null })
        {
            output.RemoveAt(output.Count - 1);
        }
        return output;
    }

    // Fits the lines that are wider than cols columns to the screen:
    //
    // - A box that is too wide loses its right side, see OpenBoxes.
    // - A rule gets shorter, so that its line fills the width of the screen.
    //   A line can hold a title next to the rule, for example the session
    //   name that Claude Code shows above its prompt.
    // - A centered block of lines moves to the left when it fits without
    //   some of the blanks before it. An example is the logo of opencode. A
    //   block is a run of lines between blank rows. It is centered when it
    //   starts at column FitMinLead or later, and when it has at least half
    //   as many blank columns at the left as at the right. The block keeps
    //   its place relative to the width of the output, so it stays centered.
    // - A single line at the right edge of the terminal moves in the same
    //   way, for example a hint of Claude Code. It then ends at the right
    //   edge of the screen.
    public static IReadOnlyList<TermLine> Fit(IReadOnlyList<TermLine> lines, int cols)
    {
        var widest = lines.Select(l => TermCells.Count(l.Text)).DefaultIfEmpty(0).Max();
        if (widest <= cols)
        {
            return lines;
        }
        // A joined line is wider than the terminal, so the width comes from Tidy when it can.
        var known = lines.Select(l => l.Cols).DefaultIfEmpty(0).Max();
        var width = known > 0 ? known : widest;
        var output = OpenBoxes(lines, cols).Select(l => FitRule(l, cols)).ToList();
        void Move(int start, int end, bool single)
        {
            var block = output.Skip(start).Take(end - start).ToArray();
            var lead = block.Select(LeadingBlanks).DefaultIfEmpty(0).Min();
            var right = block.Select(l => TermCells.Count(l.Text)).DefaultIfEmpty(0).Max();
            var size = right - lead;
            // A single line moves only when it ends at the right edge, so that the rows of a drawing keep their places.
            if (right <= cols || right > width || size > cols || lead < FitMinLead || 2 * lead < width - right ||
                single && right < width - WrapSlack)
            {
                return;
            }
            // The share of the free columns at the left stays the same.
            var shift = lead - lead * (cols - size) / (width - size);
            for (var i = start; i < end; i++)
            {
                output[i] = DropColumns(output[i], shift);
            }
        }
        var from = 0;
        while (from < output.Count)
        {
            var end = from;
            while (end < output.Count && output[end].Spans.Count > 0)
            {
                end++;
            }
            if (end > from)
            {
                Move(from, end, false);
            }
            from = end + 1;
        }
        for (var i = 0; i < output.Count; i++)
        {
            if (TermCells.Count(output[i].Text) > cols)
            {
                Move(i, i + 1, true);
            }
        }
        return output;
    }

    // Shortens the longest rule of a line that is wider than cols, so that the line fits.
    static TermLine FitRule(TermLine line, int cols)
    {
        var text = new CellText(line.Text);
        if (text.Count <= cols)
        {
            return line;
        }
        var rule = LongestRule(text);
        if (rule.Count < RuleMin)
        {
            return line;
        }
        var cut = Math.Min(text.Count - cols, rule.Count - RuleKeep);
        return new TermLine(Take(line, rule.Start).Spans.Concat(DropColumns(line, rule.Start + cut).Spans), line.Fill);
    }

    // Removes the right side of each box that is wider than cols columns,
    // for example a dialog that fills the width of the terminal. The rows of
    // the box then wrap on the screen, and the left side stays as a panel
    // bar. A box starts with a top edge, for example ╭──╮, has rows with a
    // side at both ends, and ends with a bottom edge. FitRule then shortens
    // the edges.
    static List<TermLine> OpenBoxes(IReadOnlyList<TermLine> lines, int cols)
    {
        var texts = lines.Select(l => new CellText(l.Text)).ToArray();
        var output = lines.ToList();
        var i = 0;
        while (i < lines.Count)
        {
            var top = texts[i];
            var right = top.Count - 1;
            var left = 0;
            while (left < top.Count && top.Single(left) == ' ')
            {
                left++;
            }
            if (right < cols || left >= top.Count || !IsBoxTop(top.Single(left)) || !IsBoxTopEnd(top.Single(right)) ||
                top.Text.Any(c => TableJoins.Contains(c)) || LongestRule(top).Count < RuleMin)
            {
                i++;
                continue;
            }
            var end = i + 1;
            while (end < lines.Count)
            {
                var row = texts[end];
                if (row.Count != right + 1)
                {
                    break;
                }
                if (IsBoxBottom(row.Single(left)) && IsBoxBottomEnd(row.Single(right)))
                {
                    break;
                }
                if (!IsBoxSide(row.Single(left)) || !IsBoxSide(row.Single(right)))
                {
                    break;
                }
                end++;
            }
            if (end >= lines.Count || texts[end].Count != right + 1 || !IsBoxBottom(texts[end].Single(left)))
            {
                i++;
                continue;
            }
            for (var k = i; k <= end; k++)
            {
                output[k] = TrimEndKeepingFill(Take(lines[k], right));
            }
            i = end + 1;
        }
        return output;
    }

    // A list marker: a symbol before a blank, for example the bullet of
    // Claude Code or the prompt mark of Codex, a check box, or a number.
    // .NET reads UTF-16 units, so a symbol outside the BMP, such as an
    // emoji, has its own alternative. The Mac app reads code points.
    static readonly Regex ListMarker = new(@"^(?:[\uD800-\uDBFF][\uDC00-\uDFFF]|[^\p{L}\p{N}\s]|\[[ x✓•]\]|\d{1,3}[.)])\s+", RegexOptions.CultureInvariant);

    // Returns the column where the wrapped rows of a line start, so that
    // they line up with its text. The column is after the blanks at the
    // start, the bar of a panel, and up to 2 list markers, for example the
    // cursor and the number of a choice.
    public static int HangingIndent(string text)
    {
        var chars = new CellText(text);
        var i = 0;
        while (i < chars.Count && chars.Single(i) == ' ')
        {
            i++;
        }
        if (i == chars.Count)
        {
            return 0;
        }
        if (IsBar(chars.Single(i)))
        {
            i++;
            while (i < chars.Count && chars.Single(i) == ' ')
            {
                i++;
            }
        }
        for (var k = 0; k < 2; k++)
        {
            var m = ListMarker.Match(chars.Slice(i, chars.Count));
            if (!m.Success)
            {
                break;
            }
            i += TermCells.Count(m.Value);
        }
        return i;
    }

    static readonly CellRect FullCell = new(0, 0, 1, 1);

    // The quadrants of the elements from ▖ to ▟. Bit 1 is the top left, 2
    // the top right, 4 the bottom left, and 8 the bottom right.
    static readonly int[] Quadrants = [4, 8, 1, 13, 9, 7, 11, 2, 6, 14];

    // Returns the shape of a block element from ▀ to ▟, or null for another
    // cell. A terminal fills the cell with these elements, but a font draws
    // them shorter than a row of the output view, so the view draws the
    // shapes. The cell is 1 text element.
    public static BlockShape? BlockShapeOf(string cell) => cell.Length == 1 ? BlockShapeOf(cell[0]) : null;

    internal static BlockShape? BlockShapeOf(char c)
    {
        int v = c;
        switch (v)
        {
            case 0x2580:
                return new BlockShape([new CellRect(0, 0, 1, 0.5)]);
            case >= 0x2581 and <= 0x2588:
                return new BlockShape([new CellRect(0, 1 - (v - 0x2580) / 8.0, 1, 1)]);
            case >= 0x2589 and <= 0x258F:
                return new BlockShape([new CellRect(0, 0, (0x2590 - v) / 8.0, 1)]);
            case 0x2590:
                return new BlockShape([new CellRect(0.5, 0, 1, 1)]);
            case 0x2591:
                return new BlockShape([FullCell], 0.25);
            case 0x2592:
                return new BlockShape([FullCell], 0.5);
            case 0x2593:
                return new BlockShape([FullCell], 0.75);
            case 0x2594:
                return new BlockShape([new CellRect(0, 0, 1, 1.0 / 8)]);
            case 0x2595:
                return new BlockShape([new CellRect(7.0 / 8, 0, 1, 1)]);
            case >= 0x2596 and <= 0x259F:
                var bits = Quadrants[v - 0x2596];
                (int Bit, CellRect Rect)[] parts =
                [
                    (1, new CellRect(0, 0, 0.5, 0.5)), (2, new CellRect(0.5, 0, 1, 0.5)),
                    (4, new CellRect(0, 0.5, 0.5, 1)), (8, new CellRect(0.5, 0.5, 1, 1)),
                ];
                return new BlockShape(parts.Where(p => (bits & p.Bit) != 0).Select(p => p.Rect));
            default:
                return null;
        }
    }

    // Finds the tone of the background that the fixed text colors suit.
    // Full-screen agents such as opencode give all text a color from the
    // desktop theme, so light text means a dark background. Text in a theme
    // color does not count, because the view shows it in the colors of the
    // app. An example is the plain history that fluxd puts above the screen.
    // The result is null when there are no fixed colors, or when light and
    // dark text colors are close in number.
    public static TermTone? Tone(IReadOnlyList<TermLine> lines)
    {
        var light = 0;
        var dark = 0;
        foreach (var line in lines)
        {
            foreach (var s in line.Spans)
            {
                if (s.Style.Fg is not { } fg || FixedRgb(fg) is not { } rgb || s.Style.Inverse)
                {
                    continue;
                }
                var c = new CellText(s.Text);
                var n = 0;
                for (var i = 0; i < c.Count; i++)
                {
                    if (c.Single(i) != ' ')
                    {
                        n++;
                    }
                }
                var l = Luminance(rgb);
                if (l >= LightText)
                {
                    light += n;
                }
                else if (l <= DarkText)
                {
                    dark += n;
                }
            }
        }
        if (light > 2 * dark)
        {
            return TermTone.Dark;
        }
        if (dark > 2 * light)
        {
            return TermTone.Light;
        }
        return null;
    }

    // Returns the 0xRRGGBB value of a color that does not come from the
    // theme, or null for a theme color.
    public static int? FixedRgb(TermColor c) => c.Kind == TermColorKind.Rgb ? c.Value : PaletteRgb(c.Value);

    // The relative luminance of a 0xRRGGBB color, from 0 for black to 1 for white.
    static double Luminance(int rgb)
    {
        static double Channel(int v)
        {
            var c = v / 255.0;
            return c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * Channel(rgb >> 16 & 0xFF) + 0.7152 * Channel(rgb >> 8 & 0xFF) + 0.0722 * Channel(rgb & 0xFF);
    }

    // Inverts the lightness of a 0xRRGGBB color and keeps its hue and
    // saturation. White becomes black, and a light orange becomes a dark orange.
    public static int InvertLightness(int rgb)
    {
        var r = (rgb >> 16 & 0xFF) / 255.0;
        var g = (rgb >> 8 & 0xFF) / 255.0;
        var b = (rgb & 0xFF) / 255.0;
        // In HSL, 1 - L with the same hue and saturation moves each channel to 1 - max - min + channel.
        var shift = 1 - Math.Max(r, Math.Max(g, b)) - Math.Min(r, Math.Min(g, b));
        int Byte(double v) => (int)Math.Round(Math.Clamp(v + shift, 0, 1) * 255, MidpointRounding.AwayFromZero);
        return Byte(r) << 16 | Byte(g) << 8 | Byte(b);
    }
}
