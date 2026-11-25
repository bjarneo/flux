using System.Text.RegularExpressions;
using FluxKit;

namespace FluxKit.Tests;

// The fitting of full-screen agent output, for example opencode, to a
// narrow screen. The same cases as TermPhoneTests.swift of the Mac app and
// TermTextTest.kt of the Android app.
public class TermPhoneTests
{
    const string Esc = "\u001B";

    const int White = 0xFFFFFF;
    const int TextColor = 0xC5C8C6;
    const int Gray = 0xA9A9A9;
    const int Accent = 0xF0C674;
    const int Panel = 0x2B2E31;
    const int Added = 0x3E4231;
    const int Sidebar = 0x202033;

    static IReadOnlyList<TermLine> Lines(string s) => TermText.Lines(s);

    static string[] Texts(IEnumerable<TermLine> lines) => lines.Select(l => l.Text).ToArray();

    static string Blanks(int n) => new(' ', Math.Max(0, n));

    static string Repeat(string s, int n) => string.Concat(Enumerable.Repeat(s, n));

    // One cell run with a 24-bit foreground and an optional background, as herdr sends it.
    static string Cell(string s, int fg, int? bg = null)
    {
        var b = bg is { } v ? $";48;2;{v >> 16 & 0xFF};{v >> 8 & 0xFF};{v & 0xFF}" : "";
        return $"{Esc}[0m{Esc}[38;2;{fg >> 16 & 0xFF};{fg >> 8 & 0xFF};{fg & 0xFF}{b}m{s}";
    }

    // A row of an opencode panel: a margin, the bar, the text, the panel background, and a margin.
    static string PanelRow(string body, int? bar = null, int width = 80) =>
        Cell("  ", White) + Cell("┃", bar ?? Panel, Panel) + Cell($"  {body}", TextColor, Panel) +
        Cell(Blanks(width - body.Length), White, Panel) + Cell("  ", White) + $"{Esc}[0m";

    static string PlainRow(string body, int indent = 5, int width = 86) =>
        Cell(Blanks(indent), White) + Cell(body, TextColor) + Cell(Blanks(width - indent - body.Length), White) + $"{Esc}[0m";

    static string BlankRow() => Cell(Blanks(86), White) + $"{Esc}[0m";

    // The shape of an opencode screen: a message, a tool panel, a gap, the prompt box, and the status line.
    static string[] Opencode =>
    [
        BlankRow(),
        PanelRow("", Accent),
        PanelRow("Add a test", Accent),
        PanelRow("", Accent),
        BlankRow(),
        PlainRow("I added the test."),
        BlankRow(),
        PanelRow(""),
        PanelRow("$ make test"),
        PanelRow(""),
        PanelRow("ok  4 tests"),
        PanelRow(""),
        BlankRow(),
        PlainRow("▣  Build · Big Pickle · 12s"),
        .. Enumerable.Repeat(BlankRow(), 20),
        PanelRow("", Accent),
        PanelRow("", Accent),
        PanelRow("", Accent),
        PanelRow("Build · Big Pickle", Accent),
        Cell("  ", White) + Cell("╹", Accent) + Cell(Repeat("▀", 81), Panel) + Cell("  ", White) + $"{Esc}[0m",
        Cell("   ", White) + Cell("~/code/app", Gray) + Cell(Blanks(40), White) + Cell("ctrl+p ", TextColor) + Cell("commands", Gray) + $"{Esc}[0m",
        BlankRow(),
    ];

    [Fact]
    public void FitsAnOpencodeScreen()
    {
        var output = Lines(string.Join("\r\n", Opencode));
        Assert.Equal(
        [
            "┃",
            "┃  Add a test",
            "┃",
            "",
            "   I added the test.",
            "",
            "┃",
            "┃  $ make test",
            "┃",
            "┃  ok  4 tests",
            "┃",
            "",
            "   ▣  Build · Big Pickle · 12s",
            "",
            "┃",
            "┃  Build · Big Pickle",
            " ~/code/app" + Blanks(40) + "ctrl+p commands",
        ], Texts(output));
        // A panel row keeps the panel background.
        Assert.Equal(TermColor.Rgb(Panel), output[1].Fill);
        // An empty panel row too.
        Assert.Equal(TermColor.Rgb(Panel), output[0].Fill);
        // A row of the conversation has no fill.
        Assert.Null(output[4].Fill);
        Assert.Null(output[3].Fill);
    }

    // A row of a wide opencode screen: main in 60 columns, a gap of 2, and side in a sidebar of 30 columns.
    static string WideRow(string main, string side, bool trimmed = false)
    {
        static string Pad(string s, int n) => s + Blanks(n - s.Length);
        var bar = trimmed && side.Length == 0 ? "" : Cell("  ", White) + Cell(trimmed ? $"  {side}" : Pad($"  {side}", 30), TextColor, Sidebar);
        return Cell(trimmed && bar.Length == 0 ? main : Pad(main, 60), TextColor) + bar + $"{Esc}[0m";
    }

    static readonly (string Main, string Side)[] WideScreen =
        [("┃  Say hello", "Greeting"), ("", "Context"), ("   Hello.", "1% used"), ("", ""), ("   ▣  Build", "LSP")];

    [Fact]
    public void DropsTheSidebar()
    {
        string[] expected = ["┃  Say hello", "", "   Hello.", "", "   ▣  Build"];
        Assert.Equal(expected, Texts(Lines(string.Join("\n", WideScreen.Select(r => WideRow(r.Main, r.Side))))));
        // An older fluxd removes the blanks at the end of a line, also when they have a background.
        Assert.Equal(expected, Texts(Lines(string.Join("\n", WideScreen.Select(r => WideRow(r.Main, r.Side, true))))));
    }

    [Fact]
    public void KeepsColumnsThatAreNotASidebar()
    {
        var wide = WideScreen.Select(r => WideRow(r.Main, r.Side)).ToArray();
        static string SideText(TermLine? line) => Regex.Replace((line?.Text ?? "").Length > 60 ? line!.Text[60..] : "", @"\s+$", "");
        // A line with other cells in the sidebar column.
        Assert.Equal("    Greeting", SideText(Lines(string.Join("\n", wide.Append(new string('x', 70))))[0]));
        // Rows with a background from a column near the left, for example diff lines.
        var diff = Enumerable.Range(0, 5).Select(i => $"  {i} " + Cell($"+ added line {i}" + Blanks(60), TextColor, Added));
        Assert.Equal("  0 + added line 0", Lines(string.Join("\n", diff))[0].Text);
        // Too few rows.
        Assert.Equal("    Greeting", SideText(Lines(string.Join("\n", wide.Take(3)))[0]));
    }

    [Fact]
    public void FillsWithTheBackgroundAfterTheText()
    {
        // A diff row: the panel, then the added code, then blanks in the color of the added code.
        var row = Cell("┃ ", Panel, Panel) + Cell(" 5 + ", Gray, Added) + Cell("def add(a, b):", TextColor, Added) +
            Cell(Blanks(30), White, Added) + Cell("    ", White, Panel) + Cell("  ", White);
        var output = Lines(row);
        Assert.Equal(["┃  5 + def add(a, b):"], Texts(output));
        Assert.Equal(TermColor.Rgb(Added), output[0].Fill);
        // Blanks with the default background give no fill.
        Assert.Null(Lines($"text   {Esc}[41m  ")[0].Fill);
    }

    [Fact]
    public void DropsAScrollBarButKeepsADrawing()
    {
        var row = Cell("┃  1   def greet(name):", TextColor, Panel) + Cell(Blanks(20), White, Panel) + Cell("█", Gray, Panel) + Cell("   ", White, Panel);
        var output = Lines(row);
        Assert.Equal(["┃  1   def greet(name):"], Texts(output));
        Assert.Equal(TermColor.Rgb(Panel), output[0].Fill);
        // A lone block with no text before it stays.
        Assert.Equal(Blanks(28) + "▄", Lines(Blanks(30) + "▄\n  █▀▀█")[0].Text);
        // A block that follows text directly stays.
        Assert.Equal(["bar ████"], Texts(Lines("bar ████")));
    }

    [Fact]
    public void DropsTheEdgesOfBoxes()
    {
        Assert.Equal(["┃ a", "b"], Texts(Lines("┃ a\n╹" + Repeat("▀", 40) + "\n" + Repeat("▄", 20) + "\nb")));
        // A short run stays.
        Assert.Equal(["▀▀▀"], Texts(Lines("▀▀▀")));
        // A logo row with gaps stays.
        Assert.Equal(["▀▀▀▀ █▀▀▀ ▀▀▀▀"], Texts(Lines("▀▀▀▀ █▀▀▀ ▀▀▀▀")));
    }

    [Fact]
    public void KeepsOneOfEachRunOfEmptyRows()
    {
        Assert.Equal(["a", "", "b"], Texts(Lines("\n\n\na\n\n\n\n\nb\n\n")));
        Assert.Equal(["┃", "┃ x", "┃"], Texts(Lines("┃\n┃\n┃\n┃ x\n┃\n┃")));
        // Different empty rows stay.
        Assert.Equal(["a", "", "┃", "", "b"], Texts(Lines("a\n\n┃\n\nb")));
    }

    [Fact]
    public void RemovesTheSharedMargin()
    {
        Assert.Equal(["a", "", "  b"], Texts(Lines("   a\n\n     b")));
        // A line at the first column keeps the margin.
        Assert.Equal(["  a", "b"], Texts(Lines("  a\nb")));
        // Blanks with a background are not margin.
        Assert.Equal("  a", Lines($"{Esc}[44m  a{Esc}[0m\n   b")[0].Text);
    }

    [Fact]
    public void MovesACenteredBlockThatFits()
    {
        string[] logo = ["█▀▀█ █▀▀█", "█  █ █▀▀▀", "▀▀▀▀ ▀▀▀▀"];
        var screen = Lines(string.Join("\n", logo.Select(l => Blanks(30) + l).Concat(["", new string('x', 70)])));
        var fitted = TermText.Fit(screen, 30);
        // The logo is 9 wide in 70 columns, with 30 blanks before it. On 30 columns, it keeps 30 / 61 of the 21 free columns.
        Assert.Equal(logo.Select(l => Blanks(10) + l), Texts(fitted.Take(3)));
        // A line that cannot fit stays.
        Assert.Equal(new string('x', 70), fitted[^1].Text);
        // Lines that fit stay.
        Assert.Equal(screen, TermText.Fit(screen, 80));
    }

    [Fact]
    public void KeepsABlockThatCannotFit()
    {
        var screen = Lines("   " + Repeat("word ", 12) + "\n   short\n\n" + new string('y', 70));
        Assert.Equal(screen, TermText.Fit(screen, 40));
    }

    [Fact]
    public void KeepsTextNearTheLeft()
    {
        // An answer of opencode starts at column 3. A line that is a little too wide wraps, and it keeps its column.
        var screen = Lines("   " + new string('z', 40) + "\n\n" + new string('y', 70));
        Assert.Equal(screen, TermText.Fit(screen, 40));
    }

    // Wraps text at width columns as an agent does: first before the first row and rest before the others.
    static List<string> AgentWrap(string text, int width, string first, string? rest = null)
    {
        rest ??= Blanks(first.Length);
        var rows = new List<string>();
        var row = first;
        var empty = true;
        foreach (var word in text.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (!empty && row.Length + 1 + word.Length > width)
            {
                rows.Add(row);
                row = rest;
                empty = true;
            }
            if (!empty)
            {
                row += " ";
            }
            row += word;
            empty = false;
        }
        rows.Add(row);
        return rows;
    }

    const string Answer = "The release is out. It contains the fix for the login page and the new export, and the deploy runs now.";
    const string Item = "Server: production runs the new build with the fix for the login page and the new export.";

    [Fact]
    public void JoinsTheRowsThatTheAgentWrapped()
    {
        var rule = new string('─', 60);
        var wrapped = AgentWrap(Answer, 60, "● ");
        Assert.True(wrapped.Count > 1);
        var screen = wrapped.Concat([""]).Concat(AgentWrap(Item, 60, "  - "))
            .Concat(["  - CLI: the new version is out.", "", "  A short line.", "  The next line stays.", rule, "❯ fix it", rule]);
        var output = Lines(string.Join("\n", screen));
        Assert.Equal(
        [
            $"● {Answer}", "", $"  - {Item}", "  - CLI: the new version is out.", "",
            "  A short line.", "  The next line stays.", rule, "❯ fix it", rule,
        ], Texts(output));
        // The lines keep the width of the terminal.
        Assert.Equal(60, output[0].Cols);
        // Without a rule or a padded row, the width is not known.
        Assert.Equal(wrapped, Texts(Lines(string.Join("\n", wrapped))));
    }

    [Fact]
    public void JoinsTheRowsOfAPanel()
    {
        const string text = "The agent read the two files and found the bug in the parser. It added a test, and it fixed the wrap of long rows.";
        var rows = AgentWrap(text, 80, "");
        Assert.True(rows.Count > 1);
        var output = Lines(string.Join("\n", rows.Select(r => PanelRow(r, Accent)).Append(PlainRow("Done."))));
        Assert.Equal([$"┃  {text}", "   Done."], Texts(output));
        // The joined line keeps the panel background.
        Assert.Equal(TermColor.Rgb(Panel), output[0].Fill);
        // A row outside the panel does not join it.
        Assert.Null(output[1].Fill);
    }

    [Fact]
    public void FitsRulesAndHintsToTheScreen()
    {
        var screen = Lines(string.Join("\n",
            "● Done.", Blanks(32) + "new task? /clear to save 12k", new string('─', 50) + " session ─", "❯ fix it", new string('─', 60)));
        Assert.Equal(
        [
            "● Done.", Blanks(12) + "new task? /clear to save 12k", new string('─', 30) + " session ─", "❯ fix it", new string('─', 40),
        ], Texts(TermText.Fit(screen, 40)));
        // Lines that fit stay.
        Assert.Equal(screen, TermText.Fit(screen, 60));
    }

    // A row of a box that is inner columns wide inside.
    static string BoxRow(string text, int inner = 58) => "│ " + text + Blanks(inner - 1 - text.Length) + "│";

    [Fact]
    public void OpensABoxThatIsTooWide()
    {
        var rule58 = new string('─', 58);
        var box = new[] { $"╭{rule58}╮" }
            .Concat(new[] { "Bash command", "", "  rm -rf build", "Do you want to proceed?", "❯ 1. Yes", "  2. No" }.Select(r => BoxRow(r)))
            .Append($"╰{rule58}╯").ToArray();
        var output = Lines(string.Join("\n", box));
        // A box keeps its rows.
        Assert.Equal(box, Texts(output));
        var rule39 = new string('─', 39);
        Assert.Equal(
        [
            $"╭{rule39}", "│ Bash command", "│", "│   rm -rf build", "│ Do you want to proceed?", "│ ❯ 1. Yes", "│   2. No", $"╰{rule39}",
        ], Texts(TermText.Fit(output, 40)));
        // A box that fits stays.
        Assert.Equal(output, TermText.Fit(output, 60));
        var row = "│ a" + Blanks(26) + "│ b" + Blanks(27) + "│";
        string[] table =
        [
            "┌" + new string('─', 28) + "┬" + new string('─', 29) + "┐", row,
            "└" + new string('─', 28) + "┴" + new string('─', 29) + "┘",
        ];
        // A table keeps its sides.
        Assert.Equal(row, TermText.Fit(Lines(string.Join("\n", table)), 40)[1].Text);
    }

    [Fact]
    public void ShowsSymbolsThatPhoneFontsLack()
    {
        Assert.Equal(["▸▸ auto mode on"], Texts(TermText.Parse("⏵⏵ auto mode on")));
        Assert.Equal(["● Done"], Texts(TermText.Parse("⏺ Done")));
    }

    // Expanded V2 tabs at the left, with the background of the selected tab on its first 3 cells.
    static string TabsRow(string tab, string main, int width = 42)
    {
        static string Pad(string s, int n) => s + Blanks(n - s.Length);
        return Cell(Pad(tab.Length > 3 ? tab[..3] : tab, 3), TextColor, Sidebar + 1) + Cell(Pad(tab.Length > 3 ? tab[3..] : "", width - 3), TextColor, Sidebar) + main;
    }

    [Fact]
    public void DropsVerticalSessionTabsBeforeFittingPanels()
    {
        string[] rows =
        [
            TabsRow("", BlankRow()),
            TabsRow(" 1 Fix alignment", PlainRow("Questions")),
            TabsRow("   flux", PanelRow("Accept the license?", Accent)),
            TabsRow("", PanelRow("1. Continue", Accent)),
            TabsRow(" + New session", PanelRow("Build · Model", Accent)),
            TabsRow("", PlainRow("esc interrupt")),
        ];
        var expected = Lines(string.Join("\n",
            BlankRow(), PlainRow("Questions"), PanelRow("Accept the license?", Accent),
            PanelRow("1. Continue", Accent), PanelRow("Build · Model", Accent), PlainRow("esc interrupt")));
        Assert.Equal(expected, Lines(string.Join("\n", rows)));
        Assert.Equal("Older plain history", Lines("Older plain history\n" + string.Join("\n", rows))[0].Text);
        foreach (var indicator in new[] { "?", "!", "⠋", " " })
        {
            var status = rows.ToArray();
            status[1] = TabsRow($" {indicator} Fix alignment", PlainRow("Questions"));
            Assert.Equal(expected, Lines(string.Join("\n", status)));
        }
    }

    [Fact]
    public void KeepsPanelsThatMentionNewSession()
    {
        var rows = string.Join("\n", PanelRow("1 Example"), PanelRow("+ New session"), PanelRow("Other text"), PanelRow("Build"));
        Assert.Equal(["┃  1 Example", "┃  + New session", "┃  Other text", "┃  Build"], Texts(Lines(rows)));
        string[] few = [TabsRow(" 1 Title", PlainRow("Hello")), TabsRow(" + New session", PlainRow("Build"))];
        Assert.Contains("1 Title", Lines(string.Join("\n", few))[0].Text);
    }

    [Fact]
    public void FindsTheHangingIndent()
    {
        Assert.Equal(3, TermText.HangingIndent("   Plain text of the answer"));
        Assert.Equal(3, TermText.HangingIndent("┃  make test"));
        // A shell prompt is a mark.
        Assert.Equal(5, TermText.HangingIndent("┃  $ make test"));
        // The prompt mark of Claude Code.
        Assert.Equal(2, TermText.HangingIndent("❯ Fix the test"));
        // The recap mark of Claude Code.
        Assert.Equal(2, TermText.HangingIndent("※ recap: the tests pass"));
        // The prompt mark of Codex.
        Assert.Equal(2, TermText.HangingIndent("› Fix the test"));
        // The cursor and the number of a choice.
        Assert.Equal(6, TermText.HangingIndent(" ❯ 1. Yes, and keep going"));
        Assert.Equal(5, TermText.HangingIndent("   - A bullet"));
        Assert.Equal(7, TermText.HangingIndent("┃  [✓] Build the APK"));
        Assert.Equal(2, TermText.HangingIndent("⏺ Claude Code text"));
        Assert.Equal(5, TermText.HangingIndent("  ⎿  Tool output"));
        Assert.Equal(4, TermText.HangingIndent("12. A numbered item"));
        // A dash without a blank is text.
        Assert.Equal(0, TermText.HangingIndent("->x"));
        Assert.Equal(0, TermText.HangingIndent(""));
    }

    [Fact]
    public void FindsTheToneOfTheColors()
    {
        // Light text is for a dark background.
        Assert.Equal(TermTone.Dark, TermText.Tone(Lines(string.Join("\n", Opencode))));
        var darkText = Cell("dark text on a light background", 0x202020) + Cell(" more", 0x303030);
        Assert.Equal(TermTone.Light, TermText.Tone(Lines(darkText)));
        // Claude Code uses theme colors for most text, and its orange is neither light nor dark.
        var claude = $"{Esc}[38;2;215;119;87m●{Esc}[0m I added the migration in the database folder.";
        Assert.Null(TermText.Tone(Lines(claude)));
        // Palette colors come from the theme.
        Assert.Null(TermText.Tone(Lines($"{Esc}[37mwhite from the theme{Esc}[0m")));
        // fluxd puts the plain history of an agent above its screen. The history has theme colors, so it does not count.
        var history = Enumerable.Repeat("an older line of plain text", 150);
        Assert.Equal(TermTone.Dark, TermText.Tone(Lines(string.Join("\n", history.Concat(Opencode)))));
        // Light and dark text close in number.
        Assert.Null(TermText.Tone(Lines(Cell("light", White) + Cell("dark", 0x101010))));
    }

    [Fact]
    public void FindsTheShapesOfBlocks()
    {
        Assert.Equal([new CellRect(0, 0, 1, 1)], TermText.BlockShapeOf("█")?.Rects);
        Assert.Equal([new CellRect(0, 0, 1, 0.5)], TermText.BlockShapeOf("▀")?.Rects);
        Assert.Equal([new CellRect(0, 0.5, 1, 1)], TermText.BlockShapeOf("▄")?.Rects);
        Assert.Equal([new CellRect(0, 7.0 / 8, 1, 1)], TermText.BlockShapeOf("▁")?.Rects);
        Assert.Equal([new CellRect(0, 0, 0.5, 1)], TermText.BlockShapeOf("▌")?.Rects);
        Assert.Equal([new CellRect(0, 0, 1.0 / 8, 1)], TermText.BlockShapeOf("▏")?.Rects);
        Assert.Equal([new CellRect(0.5, 0, 1, 1)], TermText.BlockShapeOf("▐")?.Rects);
        Assert.Equal(0.5, TermText.BlockShapeOf("▒")?.Alpha);
        Assert.Equal([new CellRect(0, 0.5, 0.5, 1)], TermText.BlockShapeOf("▖")?.Rects);
        Assert.Equal([new CellRect(0.5, 0, 1, 0.5), new CellRect(0, 0.5, 0.5, 1), new CellRect(0.5, 0.5, 1, 1)], TermText.BlockShapeOf("▟")?.Rects);
        Assert.Null(TermText.BlockShapeOf("┃"));
        Assert.Null(TermText.BlockShapeOf("a"));
    }

    [Fact]
    public void InvertsTheLightness()
    {
        Assert.Equal(0x000000, TermText.InvertLightness(0xFFFFFF));
        Assert.Equal(0xFFFFFF, TermText.InvertLightness(0x000000));
        // A color at half lightness stays.
        Assert.Equal(0xFF0000, TermText.InvertLightness(0xFF0000));
        Assert.Equal(0x5C5C5C, TermText.InvertLightness(0xA3A3A3));
        // A light orange becomes a dark orange.
        Assert.Equal(0x522100, TermText.InvertLightness(0xFFCEAD));
    }

    [Fact]
    public void ARowThatBrokeInAWordJoinsWithoutABlank()
    {
        Assert.True(TermText.WrapsInWord("run src/", "pages/a.ts"));
        Assert.True(TermText.WrapsInWord("CI (https:", "//github.com/a"));
        Assert.True(TermText.WrapsInWord("--workers=2 --", "retries=0"));
        Assert.True(TermText.WrapsInWord("src/lib/share.test.", "ts"));
        // A sentence ends with a dot.
        Assert.False(TermText.WrapsInWord("the same view.", "pushed"));
        // A dash between words.
        Assert.False(TermText.WrapsInWord("the fix -", "and"));
        // A slash alone.
        Assert.False(TermText.WrapsInWord("a /", "b"));
        Assert.Equal("src/pages/a.ts --workers=2", TermText.JoinWrapped(TermText.JoinWrapped("src/", "pages/a.ts --"), "workers=2"));
        Assert.Equal("the end. Next", TermText.JoinWrapped("the end.", "Next"));
    }

    [Fact]
    public void CountsAnEmojiAsOneCell()
    {
        // An emoji takes 2 UTF-16 units and 1 cell, as a Character of the Mac app.
        var layout = new TermRowLayout(new TermLine([new TermSpan("🚀 ab"), new TermSpan("c")]), 3);
        Assert.Equal(["🚀", " ", "a", "b", "c"], layout.Cells);
        Assert.Equal(4, layout.Runs[0].End);
        Assert.Equal([new CellRange(0, 2), new CellRange(2, 5)], layout.Rows);
        // An emoji before a blank is a list marker, as in the regular expressions of the Mac app.
        Assert.Equal(2, TermText.HangingIndent("🚀 launch"));
    }
}
