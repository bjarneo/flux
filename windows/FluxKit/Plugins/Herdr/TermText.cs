using System.Globalization;
using System.Text;

namespace FluxKit;

// Terminal text with ANSI SGR styles, for the output of a herdr agent. The
// app turns the lines into styled text. This is a port of TermText.swift of
// the Mac app and TermText.kt of the Android app, so all apps show the same
// output.

public enum TermColorKind
{
    // An entry of the 256-color palette. 0 to 15 are the theme colors.
    Indexed,

    // A 24-bit color as 0xRRGGBB.
    Rgb,
}

// A color of terminal text.
public readonly record struct TermColor(TermColorKind Kind, int Value)
{
    public static TermColor Indexed(int index) => new(TermColorKind.Indexed, index);
    public static TermColor Rgb(int rgb) => new(TermColorKind.Rgb, rgb);
}

// The style of a run of terminal text. A null color is the default color.
public readonly record struct TermStyle(
    TermColor? Fg = null,
    TermColor? Bg = null,
    bool Bold = false,
    bool Dim = false,
    bool Italic = false,
    bool Underline = false,
    bool Inverse = false,
    bool Strike = false);

// A run of text with 1 style.
public readonly record struct TermSpan(string Text, TermStyle Style = default);

// One line of terminal text. Fill is the background of the blank cells
// after the text, for example the background of a panel. A null fill is the
// default background. Cols is the width of the terminal that drew the line,
// when TermText.Tidy finds it, else 0.
public sealed record TermLine
{
    readonly ValueList<TermSpan> spans = ValueList<TermSpan>.Empty;

    public TermLine(IEnumerable<TermSpan> spans, TermColor? fill = null, int cols = 0)
    {
        Spans = spans as ValueList<TermSpan> ?? ValueList.From(spans);
        Fill = fill;
        Cols = cols;
    }

    public ValueList<TermSpan> Spans
    {
        get => spans;
        init
        {
            spans = value;
            Text = string.Concat(value.Select(s => s.Text));
        }
    }

    public TermColor? Fill { get; init; }
    public int Cols { get; init; }

    // The text of all spans.
    public string Text { get; private init; } = "";
}

public static partial class TermText
{
    const int Esc = 0x1B;
    const int Bel = 0x07;
    const int TabWidth = 8;

    // Parses text with ANSI SGR sequences into lines of styled spans. It
    // drops other escape sequences, carriage returns, and the other C0 and
    // C1 control characters. It shows U+FFFD in place of each character
    // that IsBidiMark finds. It expands tabs to the next multiple of 8
    // columns.
    public static IReadOnlyList<TermLine> Parse(string text)
    {
        var s = text.EnumerateRunes().ToArray();
        var lines = new List<TermLine>();
        var spans = new List<TermSpan>();
        // The open span collects text until the style changes, so that a
        // long run does not copy its text again for each piece.
        var spanText = new StringBuilder();
        var spanStyle = default(TermStyle);
        var open = false;
        var run = new StringBuilder();
        var style = new TermStyle();
        var column = 0;

        void Close()
        {
            if (!open)
            {
                return;
            }
            spans.Add(new TermSpan(spanText.ToString(), spanStyle));
            spanText.Clear();
            open = false;
        }

        void Flush()
        {
            if (run.Length == 0)
            {
                return;
            }
            if (!open || spanStyle != style)
            {
                Close();
                spanStyle = style;
                open = true;
            }
            spanText.Append(run);
            run.Clear();
        }

        var i = 0;
        while (i < s.Length)
        {
            var c = s[i].Value;
            switch (c)
            {
                case '\n':
                    Flush();
                    Close();
                    lines.Add(new TermLine(spans));
                    spans = [];
                    column = 0;
                    i++;
                    break;
                case '\t':
                    var n = TabWidth - column % TabWidth;
                    run.Append(' ', n);
                    column += n;
                    i++;
                    break;
                case Esc:
                    Flush();
                    int? next = i + 1 < s.Length ? s[i + 1].Value : null;
                    if (next == '[')
                    {
                        // CSI: parameters and intermediates, then 1 final byte from 0x40 to 0x7E.
                        var j = i + 2;
                        while (j < s.Length && s[j].Value is < 0x40 or > 0x7E)
                        {
                            j++;
                        }
                        if (j < s.Length && s[j].Value == 'm')
                        {
                            var parameters = new StringBuilder();
                            for (var k = i + 2; k < j; k++)
                            {
                                AppendRune(parameters, s[k]);
                            }
                            style = ApplySgr(style, parameters.ToString());
                        }
                        i = j + 1;
                    }
                    else if (next == ']')
                    {
                        // OSC: ends with BEL or with ESC and a backslash.
                        var j = i + 2;
                        while (j < s.Length && s[j].Value != Bel && !(s[j].Value == Esc && j + 1 < s.Length && s[j + 1].Value == '\\'))
                        {
                            j++;
                        }
                        i = j < s.Length && s[j].Value == Esc ? j + 2 : j + 1;
                    }
                    else if (next is '(' or ')' or '*' or '+')
                    {
                        // A character set selection, for example ESC ( B.
                        i += 3;
                    }
                    else if (next is >= 0x30 and <= 0x7E)
                    {
                        // A 2-byte sequence, for example ESC 7 to save the cursor.
                        i += 2;
                    }
                    else
                    {
                        i++;
                    }
                    break;
                default:
                    if (c == '\r' || c < 0x20 || c is >= 0x7F and <= 0x9F)
                    {
                        i++;
                        continue;
                    }
                    var output = s[i];
                    if (c == 0xA0)
                    {
                        // A no-break space shows as a space.
                        output = new Rune(' ');
                    }
                    else if (IsBidiMark(c))
                    {
                        output = new Rune(0xFFFD);
                    }
                    else if (Glyphs.TryGetValue(c, out var g))
                    {
                        output = new Rune(g);
                    }
                    AppendRune(run, output);
                    column++;
                    i++;
                    break;
            }
        }
        Flush();
        Close();
        if (spans.Count > 0)
        {
            lines.Add(new TermLine(spans));
        }
        return lines;
    }

    static void AppendRune(StringBuilder b, Rune r)
    {
        if (r.IsBmp)
        {
            b.Append((char)r.Value);
        }
        else
        {
            b.Append(r.ToString());
        }
    }

    // Symbols that agents use and that phone fonts often do not have, with
    // a shape of the same meaning. A missing glyph shows as an empty box,
    // and the record symbol can show as a color emoji. Claude Code marks
    // its modes with ⏵⏵. The Mac and Android apps use the same map.
    static readonly Dictionary<int, char> Glyphs = new()
    {
        ['⏵'] = '▸',
        ['⏴'] = '◂',
        ['⏶'] = '▴',
        ['⏷'] = '▾',
        ['⏺'] = '●',
    };

    // Reports whether c sets the direction of text, or is a line or
    // paragraph separator. The app shows text with the Unicode
    // bidirectional algorithm, and a terminal does not. So such a character
    // can show a command in another order. fluxd changes these characters
    // too, but an older fluxd does not.
    internal static bool IsBidiMark(int c) =>
        c is 0x061C or 0x200E or 0x200F or (>= 0x202A and <= 0x202E) or (>= 0x2066 and <= 0x2069) or 0x2028 or 0x2029;

    // Applies the SGR parameters, for example "1;38;5;6", to start.
    internal static TermStyle ApplySgr(TermStyle start, string parameters)
    {
        // Private and other non-SGR forms, for example ESC [ > 4 m, change nothing.
        if (parameters.Any(c => !"0123456789;:".Contains(c)))
        {
            return start;
        }
        var s = start;
        var parts = parameters.Length == 0 ? ["0"] : parameters.Split(';');
        var i = 0;
        while (i < parts.Length)
        {
            var p = parts[i];
            if (p.Contains(':'))
            {
                // The colon form keeps the color in 1 parameter, for example 38:2::215:119:87.
                s = ApplyColonForm(s, p.Split(':'));
                i++;
                continue;
            }
            var code = Int(p) ?? 0;
            switch (code)
            {
                case 0:
                    s = new TermStyle();
                    break;
                case 1:
                    s = s with { Bold = true };
                    break;
                case 2:
                    s = s with { Dim = true };
                    break;
                case 3:
                    s = s with { Italic = true };
                    break;
                case 4:
                case 21:
                    s = s with { Underline = true };
                    break;
                case 7:
                    s = s with { Inverse = true };
                    break;
                case 9:
                    s = s with { Strike = true };
                    break;
                case 22:
                    s = s with { Bold = false, Dim = false };
                    break;
                case 23:
                    s = s with { Italic = false };
                    break;
                case 24:
                    s = s with { Underline = false };
                    break;
                case 27:
                    s = s with { Inverse = false };
                    break;
                case 29:
                    s = s with { Strike = false };
                    break;
                case >= 30 and <= 37:
                    s = s with { Fg = TermColor.Indexed(code - 30) };
                    break;
                case 39:
                    s = s with { Fg = null };
                    break;
                case >= 40 and <= 47:
                    s = s with { Bg = TermColor.Indexed(code - 40) };
                    break;
                case 49:
                    s = s with { Bg = null };
                    break;
                case >= 90 and <= 97:
                    s = s with { Fg = TermColor.Indexed(code - 90 + 8) };
                    break;
                case >= 100 and <= 107:
                    s = s with { Bg = TermColor.Indexed(code - 100 + 8) };
                    break;
                case 38:
                case 48:
                    var (color, used) = ExtendedColor(parts, i + 1);
                    // An unknown color form has an unknown length, so the rest of the parameters go.
                    if (used == 0)
                    {
                        return s;
                    }
                    if (color is { } c)
                    {
                        s = code == 38 ? s with { Fg = c } : s with { Bg = c };
                    }
                    i += used;
                    break;
            }
            i++;
        }
        return s;
    }

    static int? Int(string s) =>
        int.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var v) ? v : null;

    // Reads a 5;N or 2;R;G;B color that starts at from. It returns the
    // color and the count of parameters that it used.
    static (TermColor? Color, int Used) ExtendedColor(string[] parts, int from)
    {
        int? At(int i) => i < parts.Length ? Int(parts[i]) : null;
        switch (from < parts.Length ? parts[from] : null)
        {
            case "5":
                return At(from + 1) is { } n && n is >= 0 and <= 255 ? (TermColor.Indexed(n), 2) : (null, 2);
            case "2":
                if (At(from + 1) is { } r && At(from + 2) is { } g && At(from + 3) is { } b &&
                    r is >= 0 and <= 255 && g is >= 0 and <= 255 && b is >= 0 and <= 255)
                {
                    return (RgbOf(r, g, b), 4);
                }
                return (null, 4);
            default:
                return (null, 0);
        }
    }

    static TermStyle ApplyColonForm(TermStyle s, string[] sub)
    {
        if (Int(sub[0]) is not { } code)
        {
            return s;
        }
        if (code == 4)
        {
            return s with { Underline = (sub.Length > 1 ? Int(sub[1]) : null) != 0 };
        }
        if (code is not (38 or 48))
        {
            return s;
        }
        TermColor? color = null;
        switch (sub.Length > 1 ? sub[1] : null)
        {
            case "5":
                if (sub.Length > 2 && Int(sub[2]) is { } n && n is >= 0 and <= 255)
                {
                    color = TermColor.Indexed(n);
                }
                break;
            case "2":
                // 38:2:R:G:B or 38:2:ID:R:G:B. The last 3 values are the color.
                var rgb = sub.Skip(2).TakeLast(3).Select(Int).ToArray();
                if (rgb.Length == 3 && rgb.All(v => v is >= 0 and <= 255))
                {
                    color = RgbOf(rgb[0]!.Value, rgb[1]!.Value, rgb[2]!.Value);
                }
                break;
        }
        if (color is not { } found)
        {
            return s;
        }
        return code == 38 ? s with { Fg = found } : s with { Bg = found };
    }

    static TermColor RgbOf(int r, int g, int b) => TermColor.Rgb(r << 16 | g << 8 | b);

    // Returns the 0xRRGGBB value of a palette entry from 16 to 255: the
    // 6 × 6 × 6 color cube, then the 24 grays. Entries 0 to 15 come from
    // the theme, so the result is null for them.
    public static int? PaletteRgb(int index)
    {
        if (index is < 16 or > 255)
        {
            return null;
        }
        if (index >= 232)
        {
            var v = 8 + 10 * (index - 232);
            return v << 16 | v << 8 | v;
        }
        var n = index - 16;
        int[] levels = [0, 95, 135, 175, 215, 255];
        return levels[n / 36] << 16 | levels[n / 6 % 6] << 8 | levels[n % 6];
    }

    internal static bool IsRuleChar(char c) => c is '─' or '━' or '═' or '-' or '_' or '=';

    // The first n cells of a line.
    internal static TermLine Take(TermLine line, int n)
    {
        var output = new List<TermSpan>();
        var left = n;
        foreach (var s in line.Spans)
        {
            if (left <= 0)
            {
                break;
            }
            var t = TermCells.Prefix(s.Text, left);
            output.Add(new TermSpan(t, s.Style));
            left -= TermCells.Count(t);
        }
        return new TermLine(output, line.Fill);
    }

    // Parses and tidies the output text of an agent, see Tidy.
    public static IReadOnlyList<TermLine> Lines(string text) => Tidy(Parse(text));
}

// A choice of a question or an approval dialog. Key is the number that the
// app shows. Keys are the herdr key names that select the choice: the digit
// of a numbered dialog, or the arrows and Enter of a menu, see FindMenu.
// Detail is the line that describes the choice, or empty.
public sealed record AgentChoice
{
    public AgentChoice(string key, string label, bool selected = false, IEnumerable<string>? keys = null, string detail = "")
    {
        Key = key;
        Label = label;
        Selected = selected;
        Keys = keys is null ? ValueList.From([key]) : ValueList.From(keys);
        Detail = detail;
    }

    public string Key { get; init; }
    public string Label { get; init; }
    public bool Selected { get; init; }
    public ValueList<string> Keys { get; init; }
    public string Detail { get; init; }

    public string Id => Key;

    // The line under the bubble of an answer: the digit that went to the
    // agent, or the menu for the arrows and Enter of a menu.
    public string SentMeta => Keys.Count == 1 && Keys[0] == Key ? $"Sent key {Key}" : "Selected in the menu";

    // How far from the end of the output the dialog can start, in lines.
    const int ScanLines = 40;

    // The last choice must be this close to the end of the output, in lines.
    const int TailLines = 15;

    // The hints under the choices of a dialog, which are not the
    // description of a choice.
    static readonly string[] ChoiceHints = ["↑↓", "enter submit", "Enter to select", "esc dismiss", "Esc to cancel", "to navigate"];

    // A line without the panel bar of opencode.
    static string Barless(string line)
    {
        var t = line.TrimStart();
        return t.StartsWith('┃') ? t[1..] : line;
    }

    // Finds the numbered choices of the dialog at the end of the output,
    // for example the approval dialog of Claude Code or the question of
    // opencode in its panel. It takes the last run of numbered lines that
    // starts at 1 and counts up by 1. Other lines can come between the
    // choices, for example descriptions or a rule. The first line under a
    // choice that is indented more than the choice is its description. It
    // returns an empty list when it finds fewer than 2 choices, or when the
    // choices are not near the end. A dialog takes the place of the input,
    // so it also returns an empty list when an input prompt comes after the
    // choices. Then the lines are a numbered list in a message of the agent.
    public static IReadOnlyList<AgentChoice> Find(IReadOnlyList<string> lines)
    {
        var from = Math.Max(0, lines.Count - ScanLines);
        var hits = new List<(int Index, int Number, AgentChoice Choice)>();
        for (var i = from; i < lines.Count; i++)
        {
            if (Parse(lines[i]) is { } hit)
            {
                hits.Add((i, hit.Number, hit.Choice));
            }
        }
        var start = hits.FindLastIndex(h => h.Number == 1);
        if (start < 0)
        {
            return [];
        }
        var run = new List<(int Index, int Number, AgentChoice Choice)>();
        foreach (var h in hits.Skip(start))
        {
            if (h.Number != run.Count + 1)
            {
                break;
            }
            run.Add(h);
        }
        if (run.Count < 2 || run[^1].Index < lines.Count - TailLines)
        {
            return [];
        }
        for (var j = run[^1].Index + 1; j < lines.Count; j++)
        {
            if (IsInputPrompt(lines[j]))
            {
                return [];
            }
        }
        var described = new List<AgentChoice>();
        for (var k = 0; k < run.Count; k++)
        {
            var h = run[k];
            var next = k + 1 < run.Count ? run[k + 1].Index : Math.Min(lines.Count, h.Index + 3);
            var col = TermCells.Lead(Barless(lines[h.Index]));
            var choice = h.Choice;
            if (h.Index + 1 < next)
            {
                string? d = null;
                for (var j = h.Index + 1; j < next; j++)
                {
                    var b = Barless(lines[j]);
                    if (b.Any(c => !char.IsWhiteSpace(c)))
                    {
                        d = b;
                        break;
                    }
                }
                if (d is not null && TermCells.Lead(d) > col && !ChoiceHints.Any(hint => d.Contains(hint, StringComparison.Ordinal)))
                {
                    choice = choice with { Detail = d.Trim() };
                }
            }
            described.Add(choice);
        }
        // A single key selects a choice, so only 1 to 9 work.
        return described.Where(c => TermCells.Count(c.Key) == 1).ToArray();
    }

    static bool Blank(char c) => c is ' ' or '\t' or '\v' or '\f' or '\r' or '\n';

    static int SkipBlanks(string s, int i)
    {
        while (i < s.Length && Blank(s[i]))
        {
            i++;
        }
        return i;
    }

    // True when line is the input prompt of an agent, also inside a box,
    // and not a choice. Examples are "❯" of Claude Code and "› Ask Codex to
    // do anything" of Codex.
    static bool IsInputPrompt(string line)
    {
        if (Parse(line) is not null)
        {
            return false;
        }
        var t = line.Trim();
        if (t.StartsWith('│'))
        {
            t = t[1..];
        }
        if (t.EndsWith('│'))
        {
            t = t[..^1];
        }
        t = t.Trim();
        return t.Length > 0 && (t[0] is '❯' or '›' or '>') && (t.Length == 1 || char.IsWhiteSpace(t[1]));
    }

    // Reads 1 line in the form [❯›>] N. label or N) label, with blanks
    // before and after the marker, as the Android app does. The panel bar
    // of opencode can come first.
    static (int Number, AgentChoice Choice)? Parse(string line)
    {
        var i = SkipBlanks(line, 0);
        if (i < line.Length && line[i] == '┃')
        {
            i = SkipBlanks(line, i + 1);
        }
        var selected = false;
        if (i < line.Length && line[i] is '❯' or '›' or '>')
        {
            selected = true;
            i = SkipBlanks(line, i + 1);
        }
        var digits = 0;
        while (i + digits < line.Length && char.IsAsciiDigit(line[i + digits]))
        {
            digits++;
        }
        if (digits is < 1 or > 2)
        {
            return null;
        }
        var number = int.Parse(line.AsSpan(i, digits), CultureInfo.InvariantCulture);
        i += digits;
        if (i >= line.Length || line[i] is not ('.' or ')'))
        {
            return null;
        }
        var rest = line[(i + 1)..];
        // At least 1 blank, then at least 1 more character.
        if (TermCells.Count(rest) < 2 || !Blank(rest[0]))
        {
            return null;
        }
        return (number, new AgentChoice(number.ToString(CultureInfo.InvariantCulture), rest.Trim(), selected));
    }

    // How far from the end of the output a menu row can be, in lines.
    const int MenuScanLines = 10;

    // The words of the hints after the choices of a menu row, for example "⇆ select" and "enter confirm" of opencode.
    static readonly string[] MenuHints = ["⇆", "ctrl+", "enter confirm", "esc "];

    // The most choices of a menu row. herdr takes 8 keys at most, so the last choice is 6 arrows and Enter away.
    const int MenuMax = 7;

    // Splits text at each run of 2 or more blanks, as Kotlin splits at \s{2,}.
    static List<string> SplitAtGaps(string text)
    {
        var parts = new List<string>();
        var current = new StringBuilder();
        var gap = new StringBuilder();
        foreach (var c in text)
        {
            if (Blank(c))
            {
                gap.Append(c);
                continue;
            }
            if (gap.Length >= 2)
            {
                parts.Add(current.ToString());
                current.Clear();
            }
            else
            {
                current.Append(gap);
            }
            gap.Clear();
            current.Append(c);
        }
        if (gap.Length >= 2)
        {
            parts.Add(current.ToString());
            current.Clear();
        }
        else
        {
            current.Append(gap);
        }
        parts.Add(current.ToString());
        return parts;
    }

    // Finds the choices of a menu row near the end of the output, for
    // example the permission dialog of opencode: "Allow once   Allow
    // always   Reject". The row has a hint with "⇆" or "enter confirm".
    // Each choice is a run of text with a background, before the hint.
    // The selected choice has another background than the others. Right
    // moves the selection to the next choice and wraps at the end, and
    // Enter confirms it. So the keys of a choice are the arrows from the
    // selected choice and Enter. It returns an empty list when it finds no
    // such row or fewer than 2 choices.
    public static IReadOnlyList<AgentChoice> FindMenu(IReadOnlyList<TermLine> lines)
    {
        for (var i = lines.Count - 1; i >= 0 && i >= lines.Count - MenuScanLines; i--)
        {
            var line = lines[i];
            var text = line.Text;
            if (!text.Contains('⇆') && !text.Contains("enter confirm", StringComparison.Ordinal))
            {
                continue;
            }
            var runs = new List<(string Text, TermColor? Bg)>();
            foreach (var span in line.Spans)
            {
                var stop = false;
                // Choices in the same style share a span. 2 spaces or more separate them.
                foreach (var part in SplitAtGaps(span.Text))
                {
                    var t = part.Trim();
                    if (MenuHints.Any(h => part.Contains(h, StringComparison.Ordinal)) || t == "enter" || t == "esc")
                    {
                        stop = true;
                        break;
                    }
                    if (t.Length == 0 || !TermCells.HasLetter(t))
                    {
                        continue;
                    }
                    runs.Add((t, span.Style.Inverse ? span.Style.Fg : span.Style.Bg));
                }
                if (stop)
                {
                    break;
                }
            }
            if (runs.Count is < 2 or > MenuMax || runs.Any(r => r.Bg is null))
            {
                return [];
            }
            // The selected choice has the background that no other choice has.
            var selected = 0;
            for (var k = 0; k < runs.Count; k++)
            {
                var bg = runs[k].Bg;
                if (runs.Count(r => r.Bg == bg) == 1)
                {
                    selected = k;
                    break;
                }
            }
            var n = runs.Count;
            return runs.Select((r, k) =>
            {
                var steps = (k - selected + n) % n;
                return new AgentChoice((k + 1).ToString(CultureInfo.InvariantCulture), r.Text, k == selected,
                    Enumerable.Repeat("right", steps).Append("enter"));
            }).ToArray();
        }
        return [];
    }
}
