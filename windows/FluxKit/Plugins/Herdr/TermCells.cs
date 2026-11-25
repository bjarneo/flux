using System.Globalization;
using System.Text;

namespace FluxKit;

// The cells of a terminal text. A cell is 1 text element, a character as the
// user sees it, as a Character of the Mac app. Most agent output is ASCII,
// box drawing, and symbols, so a text with only such characters takes a
// fast path where each UTF-16 unit is 1 cell.
internal readonly struct CellText
{
    // The start of each cell in Text, and the length of Text at the end.
    // It is null when each UTF-16 unit is 1 cell.
    readonly int[]? starts;

    public CellText(string text)
    {
        Text = text;
        starts = Simple(text) ? null : Starts(text);
    }

    public string Text { get; }

    public int Count => starts is null ? Text.Length : starts.Length - 1;

    // The index in Text where cell i starts. Start(Count) is the length of Text.
    public int Start(int i) => starts is null ? i : starts[i];

    // The text of cell i.
    public string this[int i] => starts is null ? Text[i].ToString() : Text[starts[i]..starts[i + 1]];

    // The character of cell i when the cell is 1 UTF-16 unit, else U+FFFF.
    // The callers compare it with known characters, which are all 1 unit.
    public char Single(int i)
    {
        if (starts is null)
        {
            return Text[i];
        }
        return starts[i + 1] - starts[i] == 1 ? Text[starts[i]] : '\uFFFF';
    }

    // The text of the cells from from until to.
    public string Slice(int from, int to) => Text[Start(from)..Start(to)];

    // The cell that holds the UTF-16 unit at index.
    public int CellAt(int index)
    {
        if (starts is null)
        {
            return index;
        }
        var i = Array.BinarySearch(starts, index);
        return i >= 0 ? i : ~i - 1;
    }

    // True when each UTF-16 unit of the text is 1 cell: ASCII, Latin
    // letters, punctuation, arrows, box drawing, blocks, shapes, and other
    // symbols without combining marks. Other text takes the slow path.
    static bool Simple(string s)
    {
        foreach (var c in s)
        {
            var ok = c switch
            {
                '\r' => false,
                < '\u0300' => true,
                >= '\u2010' and <= '\u2027' => true,
                >= '\u2030' and <= '\u205E' => true,
                >= '\u2070' and <= '\u20CF' => true,
                >= '\u2100' and <= '\u2BFF' => true,
                _ => false,
            };
            if (!ok)
            {
                return false;
            }
        }
        return true;
    }

    static int[] Starts(string s)
    {
        var list = new List<int>(s.Length + 1);
        var i = 0;
        while (i < s.Length)
        {
            list.Add(i);
            i += Math.Max(1, StringInfo.GetNextTextElementLength(s, i));
        }
        list.Add(s.Length);
        return list.ToArray();
    }
}

internal static class TermCells
{
    // The count of cells in the text.
    public static int Count(string s) => new CellText(s).Count;

    // The first n cells of the text.
    public static string Prefix(string s, int n)
    {
        var c = new CellText(s);
        return c.Slice(0, Math.Clamp(n, 0, c.Count));
    }

    // The text without its first n cells.
    public static string Drop(string s, int n)
    {
        var c = new CellText(s);
        return c.Slice(Math.Clamp(n, 0, c.Count), c.Count);
    }

    // The count of blanks at the start of the text.
    public static int Lead(string s)
    {
        var n = 0;
        while (n < s.Length && s[n] == ' ')
        {
            n++;
        }
        return n;
    }

    // True when the first character of the text is a letter.
    public static bool StartsWithLetter(string s) =>
        s.Length > 0 && Rune.DecodeFromUtf16(s, out var r, out _) == System.Buffers.OperationStatus.Done && Rune.IsLetter(r);

    // True when the first character of the text is a letter or a number.
    public static bool StartsWithLetterOrNumber(string s) =>
        s.Length > 0 && Rune.DecodeFromUtf16(s, out var r, out _) == System.Buffers.OperationStatus.Done && (Rune.IsLetter(r) || Rune.IsNumber(r));

    // True when the text has a letter.
    public static bool HasLetter(string s)
    {
        foreach (var r in s.EnumerateRunes())
        {
            if (Rune.IsLetter(r))
            {
                return true;
            }
        }
        return false;
    }
}
