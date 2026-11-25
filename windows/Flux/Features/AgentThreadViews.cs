using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using FluxKit;

namespace Flux;

// The glyphs of Segoe Fluent Icons that the agent views use, in addition to
// Icons. Windows 10 draws the same code points with Segoe MDL2 Assets.
public static class AgentGlyphs
{
    public const string Agent = "";
    public const string Reply = "";
    public const string ArrowUp = "";
    public const string ArrowDown = "";
    public const string ChevronUp = "";
    public const string Stop = "";
    public const string Completed = "";
    public const string Question = "";
    public const string Home = "";
    public const string Drive = "";
}

// The marks, the dialog parts, and the texts of an agent. The cards of the
// chat and the agents window use them. AgentThreadViews.swift of the Mac app
// has the same parts, in the sizes of the Mac app.
public static class AgentParts
{
    // The status as a word.
    public static string Label(this AgentStatus status) => status switch
    {
        AgentStatus.Blocked => "Needs input",
        AgentStatus.Done => "Done",
        AgentStatus.Working => "Working",
        AgentStatus.Idle => "Idle",
        _ => "Unknown",
    };

    // The color of the status word. An idle or unknown status takes the second ink.
    public static Brush Ink(this AgentStatus status) => status switch
    {
        AgentStatus.Blocked => Tn.Current.Red,
        AgentStatus.Working => Tn.Current.Accent,
        AgentStatus.Done => Tn.Current.Green,
        _ => Tn.Current.Sub,
    };

    // The color role of an Inbox tone.
    public static Brush Brush(this InboxTone tone) => tone switch
    {
        InboxTone.Red => Tn.Current.Red,
        InboxTone.Green => Tn.Current.Green,
        InboxTone.Accent => Tn.Current.Accent,
        InboxTone.Cyan => Tn.Current.Cyan,
        _ => Tn.Current.Sub,
    };

    // "Done", with the time of the last turn when it is known.
    public static string DoneText(string worked) => worked.Length == 0 ? "Done" : $"Done in {worked}";

    // A status dot. With pulse, it fades to 30% and back in 1.6 s, for what
    // waits for the user. When Windows turns animations off, it does not pulse.
    public static FrameworkElement PulseDot(Brush color, double size = 8, bool pulse = true)
    {
        var dot = Ui.Dot(color, size);
        if (pulse && !Motion.Reduced)
        {
            dot.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(1, 0.3, new Duration(TimeSpan.FromSeconds(0.8)))
            {
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
                EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
            });
        }
        return dot;
    }

    // The mark of an agent status: a ring that turns while it works, a dot
    // that pulses while it waits, else a dot.
    public static FrameworkElement StatusMark(AgentStatus status, double dot = 8, double ring = 11)
    {
        var tn = Tn.Current;
        return status switch
        {
            AgentStatus.Working => Parts.Spinner(ring, tn.Accent),
            AgentStatus.Blocked => PulseDot(tn.Red, dot),
            AgentStatus.Done => PulseDot(tn.Green, dot, false),
            _ => PulseDot(tn.Dim, dot, false),
        };
    }

    // The line of 2 px under a header. While work runs, a bar of 40% of the
    // width slides over it in the accent.
    public static FrameworkElement ProgressLine(bool working) => Parts.ProgressLine(slide: working);

    // A numbered choice of a dialog. The primary choice has the accent fill,
    // and the others have the tonal fill. A click sends its keys. The
    // description of a choice shows under its label.
    public static PlainButton AskChoiceButton(AgentChoice choice, bool primary, bool enabled, Action action, double minHeight = Metrics.RowHeight)
    {
        var tn = Tn.Current;
        var ink = primary ? tn.OnAccent : tn.Text;
        var key = Ui.Text(choice.Key, 13, FontWeights.Bold, ink, mono: true).Top();
        key.Opacity = 0.65;
        key.Margin = new Thickness(0, 1, 0, 0);
        TextBlock? detail = null;
        if (choice.Detail.Length > 0)
        {
            detail = Ui.Text(choice.Detail, 11.5, color: ink, wrap: true);
            detail.Opacity = 0.72;
        }
        var row = Ui.H(12, key, Ui.V(2, Ui.Text(choice.Label, 13, FontWeights.Medium, ink, wrap: true), detail).Fill());
        var tile = new Border
        {
            Child = row,
            Background = primary ? tn.Accent : tn.Line,
            CornerRadius = new CornerRadius(Metrics.TileCorner),
            Padding = new Thickness(14, 8, 14, 8),
            MinHeight = minHeight,
        };
        var button = new PlainButton(tile, action) { IsEnabled = enabled };
        var name = choice.Detail.Length == 0 ? $"{choice.Key}. {choice.Label}" : $"{choice.Key}. {choice.Label}. {choice.Detail}";
        return button.Named(name).Help($"Answer {choice.Key}");
    }

    // Lines of a command or a question in mono on the page color: the first
    // line in the body ink, the others in the second ink. The lines are
    // never cut, because they hold the command that a choice approves.
    public static UIElement CodeLines(IReadOnlyList<string> lines)
    {
        var tn = Tn.Current;
        var rows = lines.Select((line, i) => (UIElement)Ui.Text(line, 12, color: i == 0 ? tn.Text : tn.Sub, mono: true, wrap: true));
        return new Border
        {
            Child = Ui.V(3, rows),
            Background = tn.Bg,
            CornerRadius = new CornerRadius(Metrics.SmallCorner),
            Padding = new Thickness(10, 8, 10, 8),
        };
    }

    // The question of a blocked agent: the question line, then the lines above the choices.
    public static FrameworkElement AskText(AgentAsk ask, double questionSize = 13, bool bold = false, double spacing = 8) =>
        Ui.V(spacing,
            ask.Question.Length > 0 ? Ui.Text(ask.Question, questionSize, bold ? FontWeights.SemiBold : FontWeights.Normal, wrap: true) : null,
            ask.Lines.Count > 0 ? CodeLines(ask.Lines) : null);

    // Gray bars in the place of text that loads, with a name for a screen reader.
    public static FrameworkElement Skeleton(double[] widths, string label)
    {
        var tn = Tn.Current;
        var bars = Ui.V(8, widths.Select(w => (UIElement)new SkeletonBar(w)
        {
            Background = tn.Line,
            CornerRadius = new CornerRadius(3),
            HorizontalAlignment = HorizontalAlignment.Left,
        }));
        return bars.Named(label);
    }

    // A bar of a part of the width that it gets, 10 px high.
    sealed class SkeletonBar(double part) : Border
    {
        protected override Size MeasureOverride(Size constraint) =>
            new(double.IsInfinity(constraint.Width) ? 200 * part : constraint.Width * part, 10);
    }

    // A text field of the agent views: 1 to 5 lines, with a hint while it
    // is empty. Enter runs submit, and Shift+Enter adds a line.
    public static TextBox ReplyField(Action submit)
    {
        var field = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 34,
            MaxHeight = 104,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalContentAlignment = VerticalAlignment.Center,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Padding = new Thickness(4, 7, 4, 7),
            FontSize = 13,
            FontFamily = Faces.Body,
        };
        field.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.None)
            {
                e.Handled = true;
                submit();
            }
        };
        return field;
    }

    // The field with its hint in a frame, for the hint shows over the empty field.
    public static Grid WithHint(TextBox field, TextBlock hint)
    {
        var grid = new Grid();
        Ui.Detach(field);
        hint.IsHitTestVisible = false;
        hint.Margin = new Thickness(field.Padding.Left + 2, 0, 0, 0);
        hint.VerticalAlignment = VerticalAlignment.Center;
        hint.Visibility = field.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        field.TextChanged += (_, _) => hint.Visibility = field.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        grid.Children.Add(field);
        grid.Children.Add(hint);
        return grid;
    }
}

// The blocks of the thread of an agent: messages, tool calls, changes,
// prompts, and terminal lines. The agents window shows them, the newest at
// the bottom. They follow the "Agent screen" section of DESIGN.md.
public static partial class ThreadViews
{
    // A token that looks like a file path or a file name, or code in backticks.
    [GeneratedRegex(@"`[^`\n]+`|(?<![A-Za-z0-9_/.-])(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]*[A-Za-z0-9_]|(?<![A-Za-z0-9_/.-])[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\.(?:sql|rb|ts|tsx|js|jsx|mjs|py|go|rs|kt|kts|swift|java|c|h|cpp|md|json|toml|yaml|yml|sh|css|scss|html|txt|lock|xml|qml)(?![A-Za-z0-9_])")]
    private static partial Regex CodeToken();

    // The names of the tools that change a file, for the colors of their result.
    static readonly HashSet<string> EditNames = ["Edit", "Update", "Write", "MultiEdit", "Delete", "Edited", "Added", "Deleted"];

    // The most lines of a first raw block that show without a fold, see Earlier.
    public const int EarlierFoldLines = 6;

    // The narrowest and the widest column of a table of a message. A longer cell wraps.
    const double TableMin = 36;
    const double TableMax = 240;
    const double TablePad = 10;

    // A message of the agent: body text, with paths and code in mono on a
    // tile. A table that the agent drew with box characters shows as a grid.
    public static UIElement Message(string text)
    {
        var parts = AgentThread.MessageParts(text);
        if (parts.Count <= 1 && parts.FirstOrDefault()?.Table != true)
        {
            return MessageText(parts.FirstOrDefault()?.Text ?? text);
        }
        return Ui.V(8, parts.Select(p => p.Table ? Table(p.Text) : MessageText(p.Text)));
    }

    static UIElement MessageText(string text)
    {
        var tn = Tn.Current;
        var block = new TextBlock
        {
            FontSize = 13,
            FontFamily = Faces.Body,
            Foreground = tn.Text,
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 20,
            Margin = new Thickness(2, 0, 2, 0),
        };
        var at = 0;
        foreach (Match m in CodeToken().Matches(text))
        {
            block.Inlines.Add(new Run(text[at..m.Index]));
            var code = m.Value;
            if (code.Length >= 2 && code[0] == '`' && code[^1] == '`')
            {
                code = code[1..^1];
            }
            block.Inlines.Add(new Run(" " + code + " ") { FontFamily = Faces.Mono, FontSize = 12, Background = tn.Tile });
            at = m.Index + m.Length;
        }
        block.Inlines.Add(new Run(text[at..]));
        return block;
    }

    // A table of a message as a grid of cells, with the header row in bold
    // on a tile. Each column is as wide as its widest cell, from 36 to 240
    // px, and a table wider than the thread scrolls to the side. A table
    // that does not parse shows its rows in mono.
    public static UIElement Table(string text)
    {
        var tn = Tn.Current;
        UIElement content;
        if (AgentThread.ParseTable(text) is { Count: > 0 } rows && rows[0].Count > 0)
        {
            var grid = new Grid();
            var count = rows[0].Count;
            for (var c = 0; c < count; c++)
            {
                var widest = rows.Select((row, r) => c < row.Count ? TextWidth(row[c], r == 0) : 0).Max();
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Clamp(Math.Ceiling(widest) + 2 * TablePad + 1, TableMin, TableMax)) });
            }
            for (var r = 0; r < rows.Count; r++)
            {
                grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                for (var c = 0; c < count; c++)
                {
                    var cell = new Border
                    {
                        Child = Ui.Text(rows[r][c], 12, r == 0 ? FontWeights.SemiBold : FontWeights.Normal, wrap: true).Top(),
                        BorderBrush = tn.Line,
                        BorderThickness = new Thickness(c > 0 ? 1 : 0, r > 0 ? 1 : 0, 0, 0),
                        Background = r == 0 ? tn.Tile : Brushes.Transparent,
                        Padding = new Thickness(TablePad, 7, TablePad, 7),
                    };
                    Grid.SetRow(cell, r);
                    Grid.SetColumn(cell, c);
                    grid.Children.Add(cell);
                }
            }
            grid.HorizontalAlignment = HorizontalAlignment.Left;
            content = grid;
        }
        else
        {
            content = Ui.Text(text, 11, mono: true).Margin(12, 10, 12, 10);
        }
        var scroll = new ScrollViewer
        {
            Content = content,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Focusable = false,
        };
        return new Border
        {
            Child = scroll,
            Background = tn.OffTile,
            BorderBrush = tn.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Metrics.TileCorner),
            ClipToBounds = true,
        };
    }

    // The width of a cell text in the font of a table.
    static double TextWidth(string text, bool head) =>
        new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
            new Typeface(Faces.Body, FontStyles.Normal, head ? FontWeights.SemiBold : FontWeights.Normal, FontStretches.Normal),
            12, Brushes.Black, 1.0).WidthIncludingTrailingWhitespace;

    // A tool call: a mark, the name of the tool, and its arguments in 1 row,
    // and the result under it while open. A click opens and closes the
    // result. A tool that runs shows a turning ring.
    public static UIElement Tool(ThreadTool tool, bool running, bool open, Action toggle)
    {
        var tn = Tn.Current;
        var args = tool.Args.Length == 0 ? tool.Result.FirstOrDefault() ?? "" : tool.Args;
        UIElement mark = running ? Parts.Spinner(13, tn.Accent)
            : Ui.Icon(tool.Failed ? Icons.Close : Icons.Check, 12, tool.Failed ? tn.Red : tn.Green);
        var head = Ui.H(10,
            mark,
            Ui.Text(tool.Name, 12, FontWeights.Bold, mono: true),
            Ui.Text(args, 12, color: tn.Sub, mono: true).Fill(),
            tool.Result.Count > 0 ? Ui.Icon(open ? AgentGlyphs.ChevronUp : Icons.ChevronDown, 11, tn.Sub) : null).MinHeight(36);
        UIElement? result = null;
        if (open && tool.Result.Count > 0)
        {
            var edit = tool.Change is not null || EditNames.Contains(tool.Name);
            var text = new TextBlock { FontSize = 12, FontFamily = Faces.Mono, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(26, 0, 0, 12) };
            for (var i = 0; i < tool.Result.Count; i++)
            {
                var line = tool.Result[i];
                var ink = (edit ? AgentThread.ChangeMark(line) : null) switch
                {
                    '+' => tn.Green,
                    '-' => tn.Red,
                    _ => tn.Sub,
                };
                text.Inlines.Add(new Run((i > 0 ? "\n" : "") + line) { Foreground = ink });
            }
            result = text;
        }
        var tile = Ui.Tile(Ui.V(0, head, result), tn.OffTile, tn.Line, 0);
        tile.Padding = new Thickness(12, 0, 12, 0);
        var name = $"{tool.Name} {tool.Args}".Trim();
        var state = running ? "Runs" : tool.Failed ? "Failed" : "Done";
        if (tool.Result.Count == 0)
        {
            return tile.Named($"{name}, {state}");
        }
        return new PlainButton(tile, toggle).Named($"{name}, {state}").Help(open ? "Hide the result" : "Show the result");
    }

    // The summary of a run of file edits: the files with their counts. A
    // click opens the changes when review is set.
    public static UIElement Changes(ThreadChanges changes, Action? review)
    {
        var tn = Tn.Current;
        var rows = new List<UIElement?>
        {
            Ui.H(8,
                Ui.Text("±", 13, FontWeights.SemiBold, tn.Magenta),
                Ui.Text(changes.Files.Count == 1 ? "Changed 1 file" : $"Changed {changes.Files.Count} files", 12, FontWeights.SemiBold).Fill(),
                Ui.Text($"+{changes.Added}", 12, color: tn.Green, mono: true),
                Ui.Text($"−{changes.Removed}", 12, color: tn.Red, mono: true)),
        };
        foreach (var f in changes.Files)
        {
            rows.Add(Ui.H(8,
                Ui.Text(f.Path, 11, color: tn.Sub, mono: true).Fill(),
                Ui.Text($"+{f.Added}", 11, color: tn.Green, mono: true),
                f.Removed > 0 ? Ui.Text($"−{f.Removed}", 11, color: tn.Red, mono: true) : null));
        }
        if (review is not null)
        {
            rows.Add(Ui.Text("Review changes", 12, FontWeights.SemiBold, tn.Accent));
        }
        var tile = Ui.Tile(Ui.V(8, rows), tn.Tile, tn.Line, 12);
        if (review is null)
        {
            return tile;
        }
        return new PlainButton(tile, review).Named(changes.Files.Count == 1 ? "Changed 1 file" : $"Changed {changes.Files.Count} files")
            .Help("Open the changes (Ctrl+D)");
    }

    // A prompt or an answer of the user: a bubble at the right edge, and
    // meta under it when it is set.
    public static UIElement You(string text, string? meta = null)
    {
        var tn = Tn.Current;
        var bubble = new Border
        {
            Child = Ui.Text(text, 13, wrap: true),
            Background = tn.AccentTile,
            BorderBrush = tn.LineHi,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(16, 16, 4, 16),
            Padding = new Thickness(14, 8, 14, 8),
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        var column = Ui.V(4, bubble, meta is null ? null : Ui.Text(meta, 11, color: tn.Sub, mono: true).Align(HorizontalAlignment.Right));
        column.Margin = new Thickness(48, 0, 0, 0);
        column.HorizontalAlignment = HorizontalAlignment.Right;
        return column;
    }

    // The line at the end of the thread of an agent that waits for the user.
    public static UIElement Waiting()
    {
        var tn = Tn.Current;
        return Ui.H(8, AgentParts.PulseDot(tn.Red), Ui.Text("Waiting for you", 12, color: tn.Red), Ui.Icon(AgentGlyphs.ArrowDown, 11, tn.Red))
            .Align(HorizontalAlignment.Center).Margin(0, 4, 0, 0);
    }

    // The line at the end of the thread of an agent that finished.
    public static UIElement Done(string worked)
    {
        var tn = Tn.Current;
        return Ui.H(8, Ui.Icon(AgentGlyphs.Completed, 12, tn.Green), Ui.Text(AgentParts.DoneText(worked), 12, color: tn.Green))
            .Align(HorizontalAlignment.Center).Margin(0, 4, 0, 0);
    }

    // Output lines that the thread does not know, as a small terminal.
    public static UIElement Raw(IReadOnlyList<TermLine> lines)
    {
        var tn = Tn.Current;
        var tile = Ui.Tile(new TermLinesView(lines), tn.OffTile, tn.Line, 0);
        tile.Padding = new Thickness(0, 10, 0, 10);
        tile.MinHeight = TermLinesView.RowHeight + 20;
        return tile;
    }

    // The output at the start of the thread whose block started before the
    // oldest line of the read, as a card that opens and closes with a click.
    public static UIElement Earlier(IReadOnlyList<TermLine> lines, bool open, Action toggle)
    {
        var tn = Tn.Current;
        var head = Ui.H(10,
            Ui.Text("Earlier output", 12, FontWeights.Bold, mono: true),
            Ui.Text(lines.Count == 1 ? "1 line" : $"{lines.Count} lines", 12, color: tn.Sub, mono: true).Fill(),
            Ui.Icon(open ? AgentGlyphs.ChevronUp : Icons.ChevronDown, 11, tn.Sub)).MinHeight(36);
        var button = new PlainButton(Ui.Box(head, 12, 0, 12, 0), toggle)
            .Named($"Earlier output, {lines.Count} lines").Help(open ? "Hide the earlier output" : "Show the earlier output");
        var tile = Ui.Tile(Ui.V(0, button, open ? new TermLinesView(lines).Margin(0, 0, 0, 10) : null), tn.OffTile, tn.Line, 0);
        return tile;
    }

    // A file of the changes: its path and counts, then its diff lines in
    // color. Hunks are cyan, added lines green, and removed lines red.
    public static UIElement DiffCard(DiffFile file)
    {
        var tn = Tn.Current;
        var head = Ui.H(8,
            Ui.Text(file.Path, 11, FontWeights.Medium, mono: true).Fill(),
            Ui.Text($"+{file.Added}", 11, FontWeights.Medium, tn.Green, mono: true),
            file.Removed > 0 ? Ui.Text($"−{file.Removed}", 11, FontWeights.Medium, tn.Red, mono: true) : null).Margin(12, 9, 12, 9);
        var text = new TextBlock { FontSize = 11, FontFamily = Faces.Mono, TextWrapping = TextWrapping.Wrap, LineHeight = 17, Margin = new Thickness(12, 8, 12, 8) };
        for (var i = 0; i < file.Lines.Count; i++)
        {
            var l = file.Lines[i];
            var ink = l.Kind switch
            {
                DiffLineKind.Hunk => tn.Cyan,
                DiffLineKind.Added => tn.Green,
                DiffLineKind.Removed => tn.Red,
                _ => tn.Sub,
            };
            text.Inlines.Add(new Run((i > 0 ? "\n" : "") + l.Text) { Foreground = ink });
        }
        return new Border
        {
            Child = Ui.V(0, head, new Border { Height = 1, Background = tn.Line }, text),
            Background = tn.Bg,
            BorderBrush = tn.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Metrics.TileCorner),
            ClipToBounds = true,
        };
    }
}
