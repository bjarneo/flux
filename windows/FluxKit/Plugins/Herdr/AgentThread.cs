using System.Globalization;
using System.Text.RegularExpressions;

namespace FluxKit;

// The thread view of an agent: its output as messages, tool calls, file
// changes, and prompts, as in a chat. The parser reads the text lines of the
// output, as TermText.Tidy gives them. It knows the transcripts of Claude
// Code, Codex, and opencode. Lines that it does not know stay as raw
// terminal lines, so that the view never loses output. This is a port of
// AgentThread.swift of the Mac app and AgentThread.kt of the Android app, so
// all apps show the same thread.

// A file that an agent changed, with the counts of added and removed lines.
public sealed record FileChange(string Path, int Added, int Removed);

// A tool call, for example Bash(npm test): the Name of the tool, its Args,
// and the Result lines under it. Failed is true when the result starts with
// an error. Change is set for a file edit.
public sealed record ThreadTool(string Name, string Args, ValueList<string> Result, bool Failed = false, FileChange? Change = null)
{
    public ThreadTool(string name, string args, IEnumerable<string> result, bool failed = false, FileChange? change = null)
        : this(name, args, ValueList.From(result), failed, change)
    {
    }
}

// A run of 2 or more file edits, as 1 summary.
public sealed record ThreadChanges(ValueList<FileChange> Files)
{
    public ThreadChanges(IEnumerable<FileChange> files)
        : this(ValueList.From(files))
    {
    }

    public int Added => Files.Sum(f => f.Added);
    public int Removed => Files.Sum(f => f.Removed);
}

// One block of the thread of an agent.
public abstract record ThreadBlock
{
    // Text of the agent. Its lines keep their breaks.
    public sealed record Message(string Text) : ThreadBlock;

    public sealed record Tool(ThreadTool Call) : ThreadBlock;

    public sealed record Changes(ThreadChanges Files) : ThreadBlock;

    // A prompt that the user sent to the agent.
    public sealed record Prompt(string Text) : ThreadBlock;

    // Output lines that the parser does not know: the lines from From until To of the output.
    public sealed record Raw(int From, int To) : ThreadBlock;
}

// The thread of an agent. Step is what a working agent does now, for
// example "Running tests", and Elapsed is its time as the agent shows it,
// for example "2:14". Worked is the time of the last turn of the agent after
// it finished, for example "6m 12s". Each of these 3 is empty when the
// output does not show it.
public sealed partial record AgentThread(ValueList<ThreadBlock> Blocks, string Step = "", string Elapsed = "", string Worked = "")
{
    public AgentThread(IEnumerable<ThreadBlock> blocks, string step = "", string elapsed = "", string worked = "")
        : this(ValueList.From(blocks), step, elapsed, worked)
    {
    }
}

// The question of a blocked agent, for the dialog of the agent screen and
// the Inbox. Question is the line that asks, for example "Do you want to
// proceed?", or empty. Lines are the lines above the choices, for example
// the command that a choice approves. Command is true when the lines are a
// shell command.
public sealed partial record AgentAsk(string Question, ValueList<string> Lines, bool Command = false)
{
    public AgentAsk(string question, IEnumerable<string> lines, bool command = false)
        : this(question, ValueList.From(lines), command)
    {
    }
}

// The kind of a line of a diff, for its color.
public enum DiffLineKind
{
    Hunk,
    Added,
    Removed,
    Context,
}

// A line of a diff.
public sealed record DiffLine(string Text, DiffLineKind Kind);

// A file in a diff, with its counts and lines.
public sealed partial record DiffFile(string Path, int Added, int Removed, ValueList<DiffLine> Lines)
{
    public DiffFile(string path, int added, int removed, IEnumerable<DiffLine> lines)
        : this(path, added, removed, ValueList.From(lines))
    {
    }
}

// A part of a message: text, or a table that the agent drew with box characters.
public sealed record MessagePart(string Text, bool Table);

// A regular expression with the ASCII classes of Kotlin. .NET gives \s, \w,
// \d, and \b a Unicode meaning, so the patterns spell the classes out.
internal sealed class ThreadPattern(string pattern)
{
    readonly Regex re = new(pattern, RegexOptions.CultureInvariant);

    // The groups of a match of the whole text, or null. Group 0 is the
    // whole text. A group that takes no part in the match is empty.
    public string[]? Whole(string s)
    {
        var m = re.Match(s);
        if (!m.Success || m.Index != 0 || m.Length != s.Length)
        {
            return null;
        }
        return Groups(m);
    }

    public bool Matches(string s)
    {
        var m = re.Match(s);
        return m.Success && m.Index == 0 && m.Length == s.Length;
    }

    // The first match in the text: its index, its length, and its groups.
    public (int Index, int Length, string[] Groups)? First(string s)
    {
        var m = re.Match(s);
        return m.Success ? (m.Index, m.Length, Groups(m)) : null;
    }

    public bool Contains(string s) => re.IsMatch(s);

    // The index and the length of group 1 of each match in the text.
    public IEnumerable<(int Index, int Length)> All(string s)
    {
        foreach (Match m in re.Matches(s))
        {
            if (m.Groups[1].Success)
            {
                yield return (m.Groups[1].Index, m.Groups[1].Length);
            }
        }
    }

    // The text with each match replaced by with.
    public string Replace(string s, string with) => re.Replace(s, _ => with);

    static string[] Groups(Match m)
    {
        var groups = new string[m.Groups.Count];
        for (var i = 0; i < groups.Length; i++)
        {
            groups[i] = m.Groups[i].Success ? m.Groups[i].Value : "";
        }
        return groups;
    }
}

// The patterns and the text helpers that the parsers share.
internal static class ThreadText
{
    // The whitespace of Kotlin's \s, and its complement.
    public const string Sp = @"[ \t\n\x0B\f\r]";
    public const string Nsp = @"[^ \t\n\x0B\f\r]";

    // The word boundaries before and after a word of Kotlin's \w.
    public const string WordStart = "(?<![A-Za-z0-9_])";
    public const string WordEnd = "(?![A-Za-z0-9_])";

    // A time: 12s, 2m 5s, 1h 2m, or 2:14.
    public const string Time = "[0-9]+h(?: [0-9]+m)?(?: [0-9]+s)?|[0-9]+m(?: [0-9]+s)?|[0-9]+s";

    // The bullet of a message or a tool call: ● and ⏺ of Claude Code, • of Codex. ※ marks a recap of Claude Code.
    public static readonly ThreadPattern BulletLine = new($"^([●⏺•※]){Sp}+(.*)$");

    // A prompt of the user: > and ❯ in Claude Code, › in Codex.
    public static readonly ThreadPattern PromptLine = new($"^[>›❯](?:{Sp}+(.*))?$");

    // A tool call of Claude Code, for example Bash(npm test) or an MCP tool.
    public static readonly ThreadPattern ToolCall = new(@"^([A-Za-z][A-Za-z0-9_.-]*|[A-Za-z0-9_.-]+ - [A-Za-z0-9_.-]+ \(MCP\))\((.*)\)" + $"{Sp}*$");

    // The first line of a tool call of Claude Code whose arguments take more than 1 line.
    public static readonly ThreadPattern ToolStart = new(@"^([A-Za-z][A-Za-z0-9_.-]*|[A-Za-z0-9_.-]+ - [A-Za-z0-9_.-]+ \(MCP\))\((.*)$");

    // The tools of Claude Code. A first line with one of these names starts a tool call also before its result shows.
    public static readonly HashSet<string> ClaudeTools =
    [
        "Agent", "Bash", "Edit", "Fetch", "Glob", "Grep", "LS", "MultiEdit", "NotebookEdit", "Read", "Search", "Skill", "Task",
        "TodoWrite", "Update", "WebFetch", "WebSearch", "Workflow", "Write",
    ];

    // A line of Claude Code that sums up the tool calls of a step, for
    // example "Read 2 files, listed 1 directory, ran 3 shell commands". Its
    // first part names a count, and it does not end like a sentence.
    public static readonly ThreadPattern SummaryLine = new(
        "^(Read|Reading|Searched|Searching|Listed|Listing|Ran|Running|Wrote|Writing|Made|Making|Edited|Editing|Updated|Updating|Created|Creating|" +
        "Fetched|Fetching|Recalled|Recalling|Called|Calling|Loaded|Loading|Found|Finding|Viewed|Viewing|Used|Using)( for)? [0-9]+ " +
        @"[^\n]*[^.!?:… \t\n\x0B\f\r]$");

    // The hint at the end of a line that the desktop can open, for example "(ctrl+o to expand)".
    public static readonly ThreadPattern ExpandHint = new($"{Sp}*" + @"\((?:ctrl|shift)\+[A-Za-z0-9_]+ to [a-z ]+\)" + $"{Sp}*$");

    // The time at the end of a tool call that runs, for example " · 11s".
    public static readonly ThreadPattern RunTime = new($"{Sp}+·{Sp}+[0-9][0-9hms :.]*$");

    // A tool call of Codex, for example "Ran npm test" or "Edited src/a.ts (+3 -1)".
    public static readonly ThreadPattern CodexTool = new(
        $"^(Ran|Running|Edited|Added|Deleted|Explored|Exploring|Read|Searched|Listed|Called|Calling|Waited|Updated Plan){WordEnd}{Sp}*(.*)$");

    // The counts at the end of a Codex edit, for example (+3 -1).
    public static readonly ThreadPattern CodexCounts = new($"{Sp}*" + @"\(\+([0-9]+)" + $"{Sp}+" + @"-([0-9]+)\)" + $"{Sp}*$");

    // The marks at the start of a result line: ⎿ of Claude Code, └ and │ of Codex.
    public static readonly ThreadPattern ResultMark = new($"^({Sp}*)([⎿└│]){Sp}*");

    // The tools of Claude Code and Codex that edit a file.
    public static readonly HashSet<string> EditTools = ["Update", "Write", "Edit", "MultiEdit", "Create", "NotebookEdit", "Edited", "Added", "Deleted"];

    public static readonly ThreadPattern Additions = new("([0-9]+) additions?");
    public static readonly ThreadPattern Removals = new("([0-9]+) removals?");
    public static readonly ThreadPattern AddedLines = new("(?:Added|Wrote) ([0-9]+) lines?");
    public static readonly ThreadPattern RemovedLines = new("[Rr]emoved ([0-9]+) lines?");

    // The working line of an agent, for example "✻ Running tests… (2:14 ·
    // esc to interrupt)" of Claude Code or "• Working (12s • esc to
    // interrupt)" of Codex.
    public static readonly ThreadPattern WorkLine = new(
        $"^{Sp}*{Nsp}{{1,2}}{Sp}+(.+?){Sp}*" + @"\(([^()]*" + $"{WordStart}to interrupt{WordEnd}" + @"[^()]*)\)" + $"{Sp}*$");

    // A time in a working line or a finished line, for example 12s, 2m 5s, or 2:14.
    public static readonly ThreadPattern TimeText = new($"{WordStart}({Time}|[0-9]+:[0-9]{{2}}(?::[0-9]{{2}})?){WordEnd}");

    // The working line of Claude Code 2.1, for example "✶ Orbiting… (1m 17s
    // · ↓ 5.7k tokens)". The hint to interrupt is in the footer now, so the
    // spinner mark and the ellipsis tell the line.
    public static readonly ThreadPattern SpinnerLine = new($"^[·✢✳✶✻✽*]{Sp}+({Nsp}[^()]*?)…{Sp}*" + @"(?:\(([^()]*)\))?" + $"{Sp}*$");

    // The line after a finished turn, for example "✻ Worked for 6m 12s", "─
    // Worked for 1m 03s ───", or "✻ Crunched for 1m 12s · done Thursday 4:15 PM".
    public static readonly ThreadPattern DoneLine = new(
        @"^[^\p{L}\p{N}_]*\p{Lu}\p{Ll}+ for (" + Time + $"){WordEnd}(?:{Sp}+·{Sp}+[^·]+)?" + @"[ \t\n\x0B\f\r─━]*$");

    // A line with only rule characters.
    public static readonly ThreadPattern RuleOnly = new(@"^[ \t\n\x0B\f\r─━═╌┄╍┈┉\-_]+$");

    // A rule with a title, for example the rule above the input of Claude Code with the name of the session.
    public static readonly ThreadPattern TitledRule = new("^[─━═]{8,}.*$");

    // A row of the logo of Claude Code at the start of a session, for example " ▐▛███▜▌   Claude Code v2.1.293".
    public static readonly ThreadPattern LogoLine = new($"^{Sp}*[▐▛▜▌▝▘▗▖▙▟█▀▄]");

    // The most rows of the logo of Claude Code.
    public const int LogoRows = 4;

    // A hint at the right edge above the input, for example "new task? /clear to save 671.7k tokens".
    public const int HintIndent = 30;

    // The choices of a notice of Claude Code above the input, for example "1: Learn more   2: Knew this already   0: Dismiss".
    public static readonly ThreadPattern NoticeChoices = new($"^(?:[0-9]: {Nsp}.*?{Sp}{{2,}})+[0-9]: {Nsp}.*$");

    // The first numbered choice of a dialog.
    public static readonly ThreadPattern FirstChoiceLine = new($"^{Sp}*([❯›>]{Sp}*)?1[.)]{Sp}+.+$");

    // The hints under the input of an agent.
    public static readonly string[] FooterWords =
    [
        "for shortcuts", "shift+tab", "context left", "accept edits", "bypass permissions", "plan mode", "auto-accept",
        "% context", "esc to cancel", "to cycle", "ctrl+", "press enter", "auto mode", "for agents", "to manage", "esc to interrupt",
    ];

    // How far from the end the working line can be, in lines that are not empty.
    public const int WorkScanLines = 12;

    // How far above the first choice the dialog can start, in lines.
    public const int DialogScanLines = 16;

    public static bool IsBox(string t) => t.Starts("╭") || t.Starts("╰") || t.Starts("│") && t.Ends("│") && TermCells.Count(t) > 1;

    // A hint line under the input. It is indented by 2 spaces at most, so
    // that a result line does not count. A working line is not a hint, also
    // when it tells how to interrupt.
    public static bool IsFooter(string line)
    {
        var lower = line.ToLowerInvariant();
        return line.Indent() <= 2 && FooterWords.Any(lower.Has) && !WorkLine.Matches(line) && !SpinnerLine.Matches(line);
    }

    // The text of a summary line without its hint and the ellipsis of a step that runs.
    public static string SummaryText(string line)
    {
        var t = ExpandHint.Replace(line.Trimmed(), "");
        if (t.Ends("…"))
        {
            t = t[..^1];
        }
        return t.TrimmedEnd();
    }

    // True when line is a summary of tool calls of Claude Code, see SummaryLine.
    public static bool IsSummary(string line) => line.Indent() == 2 && SummaryLine.Matches(SummaryText(line));

    // True when line, at the left edge right under the first line of a
    // block, continues that line. A bullet, a prompt, a rule, a box, and the
    // lines of the status of the agent start something else.
    public static bool ContinuesHead(string line)
    {
        var t = line.Trimmed();
        return !PromptLine.Matches(t) && !RuleOnly.Matches(t) && !TitledRule.Matches(t) && !IsBox(t) &&
            !DoneLine.Matches(t) && !WorkLine.Matches(t) && !SpinnerLine.Matches(t);
    }

    public static int? Int(string s) => int.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : null;
}

public sealed partial record AgentAsk
{
    // Finds the line where the dialog at the end of lines starts, or null
    // when the output ends with no dialog. The dialog starts at the rule or
    // the box above its first choice, as in Claude Code. Without one, it
    // starts at the question above the choices, as in Codex. Without a
    // question, it takes the lines directly above the choices.
    public static int? DialogStart(IReadOnlyList<string> lines)
    {
        if (AgentChoice.Find(lines).Count == 0)
        {
            return null;
        }
        var first = -1;
        for (var i = lines.Count - 1; i >= 0; i--)
        {
            if (ThreadText.FirstChoiceLine.Matches(lines[i]))
            {
                first = i;
                break;
            }
        }
        if (first < 0)
        {
            return null;
        }
        var stop = Math.Max(0, first - ThreadText.DialogScanLines);
        // The thread above the dialog ends at a message, a tool call, or a prompt.
        var thread = -1;
        for (var i = first - 1; i >= stop; i--)
        {
            if (ThreadText.BulletLine.Matches(lines[i]) || ThreadText.PromptLine.Matches(lines[i]))
            {
                thread = i;
                break;
            }
        }
        for (var i = first - 1; i >= stop; i--)
        {
            var t = lines[i].Trimmed();
            if (i > thread && t.Length > 0 && (ThreadText.RuleOnly.Matches(t) || t.Starts("╭")))
            {
                return i;
            }
        }
        for (var i = first - 1; i >= stop; i--)
        {
            if (i > thread && lines[i].Trimmed().Ends("?"))
            {
                return i;
            }
        }
        var s = first;
        while (s > Math.Max(stop, thread + 1) && !lines[s - 1].IsBlank())
        {
            s--;
        }
        return s;
    }

    // Returns the question of the dialog at the end of lines, or null when
    // the output ends with no choices. It keeps the maxLines lines nearest
    // the choices, because they hold the command that a choice approves.
    // The title of the dialog, for example "Bash command", does not show.
    // After a command title, the command gets a "$ " in front.
    public static AgentAsk? Find(IReadOnlyList<string> lines, int maxLines = 4)
    {
        if (AgentThread.IsOpencode(lines))
        {
            return AgentThread.OpencodeAsk(lines, maxLines);
        }
        if (DialogStart(lines) is not { } start)
        {
            return null;
        }
        var first = -1;
        for (var i = lines.Count - 1; i >= start; i--)
        {
            if (ThreadText.FirstChoiceLine.Matches(lines[i]))
            {
                first = i;
                break;
            }
        }
        if (first < 0)
        {
            return null;
        }
        // The lines of the dialog without rules, box edges, and empty lines.
        // Each keeps its indent and whether a blank line follows it.
        var rows = new List<(string Text, int Indent, bool GapAfter)>();
        for (var i = start; i < first; i++)
        {
            var t = lines[i].TrimmedEnd();
            var s = t.Trimmed();
            if (s.Length == 0)
            {
                if (rows.Count > 0)
                {
                    rows[^1] = rows[^1] with { GapAfter = true };
                }
                continue;
            }
            if (ThreadText.RuleOnly.Matches(s) || s.Starts("╭") || s.Starts("╰"))
            {
                continue;
            }
            // The header chips of a question of Claude Code, for example "☐ Tax rate".
            if (s.Starts("☐") || s.Starts("☒") || s.Starts("✔") || s.Starts("←  ☐"))
            {
                continue;
            }
            if (s.Starts("│"))
            {
                var inner = s[1..];
                if (inner.Ends("│"))
                {
                    inner = inner[..^1];
                }
                t = inner.TrimmedEnd();
            }
            if (t.IsBlank())
            {
                continue;
            }
            rows.Add((t.Trimmed(), t.Indent(), false));
        }
        if (rows.Count == 0)
        {
            return new AgentAsk("", ValueList<string>.Empty);
        }
        var question = "";
        var body = rows;
        if (body[^1].Text.Ends("?"))
        {
            question = body[^1].Text;
            body.RemoveAt(body.Count - 1);
        }
        else if (body[0].Text.Ends("?"))
        {
            question = body[0].Text;
            body.RemoveAt(0);
        }
        // A title: the first line, with a blank line under it, and more indented lines after it.
        var command = false;
        if (body.Count >= 2 && body[0].GapAfter && body[1].Indent > body[0].Indent)
        {
            command = body[0].Text.ToLowerInvariant().Ends("command");
            body.RemoveAt(0);
        }
        var text = body.Select(r => r.Text).TakeLast(Math.Max(0, maxLines)).ToList();
        if (command && text.Count > 0 && !text[0].Starts("$ "))
        {
            text[0] = "$ " + text[0];
        }
        if (!command)
        {
            command = text.Count > 0 && text[0].Starts("$ ");
        }
        return new AgentAsk(question, text, command);
    }
}

public sealed partial record AgentThread
{
    // Parses the output lines of an agent into its thread. The input is the
    // plain text of each line: the Text of each line of HerdrOutput.Lines.
    public static AgentThread Parse(IReadOnlyList<string> lines)
    {
        if (IsOpencode(lines))
        {
            return Opencode(lines);
        }
        var dialog = AgentAsk.DialogStart(lines);
        var end = dialog ?? StripInput(lines, lines.Count);
        // The dialog takes the place of the input, so only the empty lines and the rules above it go.
        while (dialog is not null && end > 0 && (lines[end - 1].Trimmed() is var t && (t.Length == 0 || ThreadText.RuleOnly.Matches(t))))
        {
            end--;
        }
        var step = "";
        var elapsed = "";
        var worked = "";
        // The working line sits above the input, and a list of tasks can follow it.
        var seen = 0;
        var w = end - 1;
        while (w >= 0 && seen < ThreadText.WorkScanLines)
        {
            var line = lines[w];
            if (!line.IsBlank())
            {
                if ((ThreadText.WorkLine.Whole(line) ?? ThreadText.SpinnerLine.Whole(line)) is { } m)
                {
                    var s = m[1].Trimmed();
                    if (s.Ends("…"))
                    {
                        s = s[..^1];
                    }
                    if (s.Ends("..."))
                    {
                        s = s[..^3];
                    }
                    step = s.Trimmed();
                    elapsed = ThreadText.TimeText.First(m[2])?.Groups[0] ?? "";
                    end = w;
                    while (end > 0 && lines[end - 1].IsBlank())
                    {
                        end--;
                    }
                    break;
                }
                seen++;
            }
            w--;
        }
        if (step.Length == 0 && end > 0 && ThreadText.DoneLine.Whole(lines[end - 1].TrimmedEnd()) is { } done)
        {
            worked = done[1];
            end--;
            while (end > 0 && lines[end - 1].IsBlank())
            {
                end--;
            }
        }
        return new AgentThread(MergeEdits(ParseBlocks(lines, end)), step, elapsed, worked);
    }

    // Removes the input box of the agent and the hints under it from the
    // end of lines, until end. It returns the new end. Claude Code puts the
    // name of the session in the rule above the input, and hints at the
    // right edge above that rule.
    internal static int StripInput(IReadOnlyList<string> lines, int end)
    {
        var i = end;
        var input = false;
        while (i > 0)
        {
            var t = lines[i - 1].Trimmed();
            if (t.Length == 0 || ThreadText.RuleOnly.Matches(t) || input && ThreadText.TitledRule.Matches(t))
            {
                i--;
            }
            else if (ThreadText.IsBox(t))
            {
                i--;
                input = true;
            }
            else if (!input && ThreadText.PromptLine.Matches(t))
            {
                i--;
                input = true;
            }
            else if (!input && ThreadText.IsFooter(lines[i - 1]))
            {
                i--;
            }
            else if (input && lines[i - 1].Indent() >= ThreadText.HintIndent)
            {
                i--;
            }
            else if (input && (lines[i - 1].Starts("✦ ") || ThreadText.NoticeChoices.Matches(t)))
            {
                // A notice of Claude Code above the input, for example "✦ Heads up · …", and its choices.
                i--;
            }
            else
            {
                return i;
            }
        }
        return i;
    }

    // Parses the lines until end into blocks.
    internal static List<ThreadBlock> ParseBlocks(IReadOnlyList<string> lines, int end)
    {
        var blocks = new List<ThreadBlock>();
        var rawFrom = -1;
        var rawTo = -1;
        void FlushRaw()
        {
            if (rawFrom >= 0)
            {
                blocks.Add(new ThreadBlock.Raw(rawFrom, rawTo));
            }
            rawFrom = -1;
        }
        // Claude Code blinks the bullet of a tool call that runs, so the
        // first line of the call can have 2 blanks in place of its bullet.
        // The result mark under it tells it.
        bool BlinkHead(int j) =>
            j > 0 && j + 1 < end && lines[j - 1].IsBlank() && lines[j].Indent() == 2 && !lines[j].IsBlank() &&
            lines[j + 1].Indent() == 2 && lines[j + 1].TrimStartText().Starts("⎿");
        // The end of a block that starts at from: the lines under it that
        // are indented. A blank line belongs to the block only when an
        // indented line follows it. A summary of tool calls after a blank
        // line starts its own block. A line at the left edge right under the
        // first line of the block continues it, when it is not a line of its
        // own kind.
        int BlockEnd(int from)
        {
            var j = from + 1;
            var last = from + 1;
            while (j < end)
            {
                var l = lines[j];
                if (l.IsBlank())
                {
                    j++;
                    continue;
                }
                if (j > last && (ThreadText.IsSummary(l) || BlinkHead(j)))
                {
                    break;
                }
                if (ThreadText.BulletLine.Matches(l))
                {
                    break;
                }
                if (l.Indent() < 2 && (j != from + 1 || !ThreadText.ContinuesHead(l)))
                {
                    break;
                }
                j++;
                last = j;
            }
            return last;
        }
        var i = 0;
        while (i < end)
        {
            var line = lines[i];
            if (line.IsBlank())
            {
                i++;
                continue;
            }
            // The logo of Claude Code and the line after an earlier turn do not show.
            if (ThreadText.LogoLine.Contains(line))
            {
                var k = i;
                while (k < end && k - i < ThreadText.LogoRows && ThreadText.LogoLine.Contains(lines[k]))
                {
                    k++;
                }
                var logo = false;
                for (var x = i; x < k; x++)
                {
                    if (lines[x].Has("Claude Code"))
                    {
                        logo = true;
                        break;
                    }
                }
                if (logo)
                {
                    FlushRaw();
                    i = k;
                    continue;
                }
            }
            if (ThreadText.DoneLine.Matches(line.TrimmedEnd()))
            {
                FlushRaw();
                i++;
                continue;
            }
            if (ThreadText.IsSummary(line))
            {
                FlushRaw();
                // A result can follow the summary, for example the note of a message that went to another session.
                var k = i + 1;
                while (k < end && !lines[k].IsBlank() && lines[k].Indent() >= 2 && !ThreadText.IsSummary(lines[k]))
                {
                    k++;
                }
                var text = ThreadText.SummaryText(line);
                blocks.Add(new ThreadBlock.Tool(new ThreadTool(text.Before(" "), text.After(" ", ""), ResultLines(Range(lines, i + 1, k)))));
                i = k;
                continue;
            }
            var bullet = ThreadText.BulletLine.Whole(line) ?? (BlinkHead(i) ? ThreadText.BulletLine.Whole("●" + line[1..]) : null);
            var prompt = bullet is null ? ThreadText.PromptLine.Whole(line) : null;
            if (bullet is null && prompt is null)
            {
                if (rawFrom < 0)
                {
                    rawFrom = i;
                }
                rawTo = i + 1;
                i++;
                continue;
            }
            FlushRaw();
            var to = BlockEnd(i);
            var body = Range(lines, i + 1, to);
            if (prompt is not null)
            {
                // The notes of Claude Code under a prompt, for example "⎿  1 skill available", are not part of it.
                var own = body.TakeWhile(l => !l.TrimStartText().Starts("⎿")).ToList();
                var text = ThreadText.ExpandHint.Replace(string.Join("\n", new[] { prompt[1] }.Concat(Dedent(own))).Trimmed(), "");
                if (text.Length > 0)
                {
                    blocks.Add(new ThreadBlock.Prompt(text));
                }
            }
            else if (bullet is not null)
            {
                blocks.Add(BulletBlock(bullet[1], bullet[2].TrimmedEnd(), body));
            }
            i = to;
        }
        FlushRaw();
        return blocks;
    }

    static List<string> Range(IReadOnlyList<string> lines, int from, int to)
    {
        var list = new List<string>(Math.Max(0, to - from));
        for (var i = from; i < to; i++)
        {
            list.Add(lines[i]);
        }
        return list;
    }

    // Removes the indent that the lines share, and keeps the blank lines between them as 1 blank line.
    internal static List<string> Dedent(IReadOnlyList<string> lines)
    {
        var pad = lines.Where(l => !l.IsBlank()).Select(l => l.Indent()).DefaultIfEmpty(0).Min();
        var output = new List<string>();
        foreach (var l in lines)
        {
            if (l.IsBlank())
            {
                if (output.Count > 0 && output[^1].Length > 0)
                {
                    output.Add("");
                }
            }
            else
            {
                output.Add(l[pad..].TrimmedEnd());
            }
        }
        while (output.Count > 0 && output[^1].Length == 0)
        {
            output.RemoveAt(output.Count - 1);
        }
        return output;
    }

    // The result lines under a tool call, without their marks. Each line keeps its indent under the first line.
    internal static List<string> ResultLines(IReadOnlyList<string> body)
    {
        var first = body.FirstOrDefault(l => !l.IsBlank());
        if (first is null)
        {
            return [];
        }
        var col = ThreadText.ResultMark.First(first) is { } m ? m.Index + m.Length : first.Indent();
        return Dedent(body, col);
    }

    // Removes up to col spaces from each line, and the blank lines at the ends.
    internal static List<string> Dedent(IReadOnlyList<string> lines, int col)
    {
        var output = lines.Select(l =>
        {
            if (ThreadText.ResultMark.First(l) is { } m)
            {
                return l[(m.Index + m.Length)..].TrimmedEnd();
            }
            return l[Math.Min(col, l.Indent())..].TrimmedEnd();
        }).ToList();
        while (output.Count > 0 && output[0].IsBlank())
        {
            output.RemoveAt(0);
        }
        while (output.Count > 0 && output[^1].IsBlank())
        {
            output.RemoveAt(output.Count - 1);
        }
        return output;
    }

    // The counts of added and removed lines in the result of an edit tool.
    internal static (int Added, int Removed) EditCounts(IReadOnlyList<string> result)
    {
        var text = string.Join("\n", result);
        var added = (ThreadText.Additions.First(text) ?? ThreadText.AddedLines.First(text)) is { } a ? ThreadText.Int(a.Groups[1]) ?? 0 : 0;
        var removed = (ThreadText.Removals.First(text) ?? ThreadText.RemovedLines.First(text)) is { } r ? ThreadText.Int(r.Groups[1]) ?? 0 : 0;
        return (added, removed);
    }

    // A block that starts with a bullet: a tool call or a message.
    internal static ThreadBlock BulletBlock(string bullet, string head, IReadOnlyList<string> body)
    {
        if (bullet != "•" && ClaudeTool(head, body) is { } tool)
        {
            return new ThreadBlock.Tool(tool);
        }
        if (bullet != "•" && ThreadText.ToolCall.Whole(head) is { } call)
        {
            var name = call[1];
            var args = call[2];
            var result = ResultLines(body);
            var failed = result.Count > 0 && result[0].TrimStartText().Starts("Error");
            FileChange? change = null;
            if (ThreadText.EditTools.Contains(name) && !args.IsBlank())
            {
                var (a, r) = EditCounts(result);
                change = new FileChange(args.Before(", ").Trimmed(), a, r);
            }
            return new ThreadBlock.Tool(new ThreadTool(name, args, result, failed, change));
        }
        var codex = bullet == "•" ? ThreadText.CodexTool.Whole(head) : null;
        var firstBody = body.FirstOrDefault(l => !l.IsBlank());
        var marked = firstBody is not null && ThreadText.ResultMark.Contains(firstBody);
        if (codex is not null && (marked || ThreadText.CodexCounts.Contains(head)))
        {
            var name = codex[1];
            var args = codex[2];
            FileChange? change = null;
            var counts = ThreadText.CodexCounts.First(args);
            if (ThreadText.EditTools.Contains(name))
            {
                var path = ThreadText.CodexCounts.Replace(args, "").Trimmed();
                change = new FileChange(path, counts is { } c ? ThreadText.Int(c.Groups[1]) ?? 0 : 0, counts is { } d ? ThreadText.Int(d.Groups[2]) ?? 0 : 0);
                args = path;
            }
            return new ThreadBlock.Tool(new ThreadTool(name, args, ResultLines(body), false, change));
        }
        return new ThreadBlock.Message(string.Join("\n", new[] { head }.Concat(Dedent(body))).Trimmed());
    }

    // A tool call of Claude Code 2.1 that the plain ToolCall does not
    // match, or null:
    // - A shell command that runs shows its description and then the
    //   command as the result, for example "Run the tests · 11s" and
    //   "⎿  $ npm test".
    // - The arguments of a long call take more than 1 line, and the closing
    //   parenthesis is on the last of them or cut.
    internal static ThreadTool? ClaudeTool(string head, IReadOnlyList<string> body)
    {
        var first = -1;
        for (var i = 0; i < body.Count; i++)
        {
            if (!body[i].IsBlank())
            {
                first = i;
                break;
            }
        }
        if (first < 0)
        {
            return null;
        }
        if (ThreadText.ResultMark.First(body[first]) is { } mark && mark.Groups[2] == "⎿" &&
            body[first][(mark.Index + mark.Length)..].Starts("$ "))
        {
            var result = ResultLines(body).Where(l => !ThreadText.ExpandHint.Matches(l) && l.Trimmed() != "(ctrl+b to run in background)");
            return new ThreadTool("Bash", ThreadText.RunTime.Replace(head, "").Trimmed(), result);
        }
        if (ThreadText.ToolCall.Matches(head))
        {
            return null;
        }
        if (ThreadText.ToolStart.Whole(head) is not { } start)
        {
            return null;
        }
        var name = start[1];
        var resultAt = -1;
        for (var i = 0; i < body.Count; i++)
        {
            if (ThreadText.ResultMark.First(body[i])?.Groups[2] == "⎿")
            {
                resultAt = i;
                break;
            }
        }
        if (resultAt < 0 && !ThreadText.ClaudeTools.Contains(name))
        {
            return null;
        }
        var argLines = body.Take(resultAt >= 0 ? resultAt : body.Count).Select(l => l.Trimmed()).Where(l => l.Length > 0);
        var args = string.Join(" ", new[] { start[2].Trimmed() }.Concat(argLines));
        if (args.Ends(")"))
        {
            args = args[..^1];
        }
        args = args.Trimmed();
        var lines = resultAt >= 0 ? ResultLines(Range(body, resultAt, body.Count)) : [];
        var failed = lines.Count > 0 && lines[0].TrimStartText().Starts("Error");
        FileChange? change = null;
        if (ThreadText.EditTools.Contains(name) && !args.IsBlank())
        {
            var (a, r) = EditCounts(lines);
            change = new FileChange(args.Before(", ").Trimmed(), a, r);
        }
        return new ThreadTool(name, args, lines, failed, change);
    }

    // Turns each run of 2 or more file edits into 1 ThreadBlock.Changes. The same file shows once, with the sum of its counts.
    internal static List<ThreadBlock> MergeEdits(IReadOnlyList<ThreadBlock> blocks)
    {
        var output = new List<ThreadBlock>();
        var run = new List<ThreadTool>();
        void Flush()
        {
            if (run.Count >= 2)
            {
                var files = new List<FileChange>();
                foreach (var t in run)
                {
                    if (t.Change is not { } c)
                    {
                        continue;
                    }
                    var i = files.FindIndex(f => f.Path == c.Path);
                    if (i >= 0)
                    {
                        files[i] = files[i] with { Added = files[i].Added + c.Added, Removed = files[i].Removed + c.Removed };
                    }
                    else
                    {
                        files.Add(c);
                    }
                }
                output.Add(new ThreadBlock.Changes(new ThreadChanges(files)));
            }
            else
            {
                output.AddRange(run.Select(t => new ThreadBlock.Tool(t)));
            }
            run.Clear();
        }
        foreach (var b in blocks)
        {
            if (b is ThreadBlock.Tool { Call: { Change: not null, Failed: false } t })
            {
                run.Add(t);
            }
            else
            {
                Flush();
                output.Add(b);
            }
        }
        Flush();
        return output;
    }
}

// The patterns of opencode.
internal static class OpencodeText
{
    const string Sp = ThreadText.Sp;
    const string Nsp = ThreadText.Nsp;

    // The line after a turn of opencode: the mode, the model, and the time, for example "▣  Build · Big Pickle · 21.2s".
    public static readonly ThreadPattern Footer = new($"^{Sp}*▣{Sp}+{Nsp}.*$");

    // The time at the end of a footer of opencode.
    public static readonly ThreadPattern FooterTime = new($@"·{Sp}*([0-9]+(?:\.[0-9]+)?s|[0-9]+m(?: [0-9]+(?:\.[0-9]+)?s)?|[0-9]+h(?: [0-9]+m)?){Sp}*$");

    // A tool line of opencode, for example "→ Read invoice.js", "← Edit invoice.js", or "✱ Grep total".
    public static readonly ThreadPattern Tool = new($"^([→←✱⚙◇]){Sp}+([A-Za-z][A-Za-z0-9_-]*){Sp}*(.*)$");

    // A shell command of opencode: "$ node invoice.test.js".
    public static readonly ThreadPattern Shell = new($@"^\${Sp}+(.+)$");

    // A changed line of a diff of opencode: the line number, then + or -.
    public static readonly ThreadPattern DiffLine = new($"^{Sp}*[0-9]+{Sp}+([+-]){Sp}");

    // A numbered line of a diff of opencode.
    public static readonly ThreadPattern Numbered = new($"^{Sp}*[0-9]+{Sp}");

    // The options of a tool call of opencode, for example " [replaceAll=false]".
    public static readonly ThreadPattern Options = new($@"{Sp}+\[[^\]]*\]{Sp}*$");

    // The scroll bar at the right edge of a dialog of opencode.
    public static readonly ThreadPattern ScrollBar = new($"{Sp}+[█▀▄▌▐░▒▓]{Sp}*$");

    // The line of opencode that tells how long the model thought, for example "+ Thought: 8.3s" or "+ Thought: Planning the commit · 1.8s".
    public static readonly ThreadPattern Thought = new($@"^\+{Sp}+Thought:{Sp}.*$");

    // The first choice of a question of opencode.
    public static readonly ThreadPattern ChoiceStart = new($"^1[.)]{Sp}+.+$");

    // The first line of a permission dialog of opencode.
    public const string Ask = "△ Permission required";

    // The hint under the choices of a question of opencode.
    public static readonly string[] QuestionHint = ["↑↓ select", "enter submit"];

    // The first line of a question of opencode that the user answered.
    public const string Questions = "# Questions";

    // The hints of opencode at the end of the output of a tool, for example "Click to expand".
    public static readonly HashSet<string> Hints = ["Click to expand", "Click to collapse"];

    // The count of the lines of a deleted file, for example "-93 lines".
    public static readonly ThreadPattern LineCount = new("-([0-9]+) lines?");

    // A number of a line in a split diff of opencode and its mark: a blank, + or -. Group 1 is the number.
    public static readonly ThreadPattern SplitMark = new("(?<=^| )([0-9]+) [ +-](?= |$)");

    // A side of a row of a split diff: the number of the line, its mark, and its text.
    public static readonly ThreadPattern SplitSide = new($"^{Sp}*([0-9]+)(?: ([ +-])(?: (.*))?)?{Sp}*$");

    // The least column of the numbers of the right side of a split diff.
    public const int SplitMinCol = 16;

    // The text of the panel line of opencode without its bar, or null when it is not a panel line.
    public static string? Panel(string line)
    {
        var t = line.TrimStart();
        if (!t.StartsWith('┃'))
        {
            return null;
        }
        var c = t[1..];
        return c.StartsWith("  ", StringComparison.Ordinal) ? c[2..] : c.TrimStart();
    }

    // True when a line of a panel starts a tool call.
    public static bool IsMarker(string c) => c.Length > 0 && !c.StartsWith(' ') && (Shell.Matches(c) || Tool.Matches(c));
}

public sealed partial record AgentThread
{
    // True when lines come from opencode: they have the line after a turn,
    // the status line at the bottom, a permission dialog, or a question.
    public static bool IsOpencode(IReadOnlyList<string> lines)
    {
        for (var i = Math.Max(0, lines.Count - 6); i < lines.Count; i++)
        {
            if (lines[i].Has("ctrl+p commands"))
            {
                return true;
            }
        }
        return lines.Any(l =>
        {
            if (OpencodeText.Footer.Matches(l))
            {
                return true;
            }
            if (OpencodeText.Panel(l) is not { } c)
            {
                return false;
            }
            return c.Starts(OpencodeText.Ask) || OpencodeText.QuestionHint.All(c.Has);
        });
    }

    // Finds the end of the thread of opencode: the status line, the input
    // box, and the permission dialog or the question at the bottom do not
    // belong to it. It gives the end, the start of the dialog or null,
    // whether the agent works now, and whether the dialog is a question of
    // the agent, not a permission.
    internal static (int End, int? Dialog, bool Working, bool Question) OpencodeEnd(IReadOnlyList<string> lines)
    {
        var end = lines.Count;
        var working = false;
        while (end > 0 && lines[end - 1].IsBlank())
        {
            end--;
        }
        if (end > 0 && (lines[end - 1].Has("ctrl+p commands") || lines[end - 1].Has("esc interrupt")))
        {
            working = lines[end - 1].Has("esc interrupt");
            end--;
        }
        while (end > 0 && (lines[end - 1].IsBlank() || lines[end - 1].TrimStartText().Starts("╹")))
        {
            end--;
        }
        // A permission dialog or a question takes the place of the input box.
        var i = end;
        while (i > 0 && OpencodeText.Panel(lines[i - 1]) is not null)
        {
            i--;
        }
        int? ask = null;
        for (var k = i; k < end; k++)
        {
            if (OpencodeText.Panel(lines[k])?.Starts(OpencodeText.Ask) == true)
            {
                ask = k;
                break;
            }
        }
        var question = false;
        if (ask is null)
        {
            for (var k = i; k < end; k++)
            {
                if (OpencodeText.Panel(lines[k]) is { } c && OpencodeText.QuestionHint.Any(c.Has))
                {
                    question = true;
                    break;
                }
            }
        }
        if (ask is not null || question)
        {
            var e = ask ?? i;
            // The tool call that waits for the answer and the line of the turn are in the dialog too.
            while (e > 0)
            {
                var l = lines[e - 1];
                var t = l.Trimmed();
                var panel = OpencodeText.Panel(l);
                var pending = panel is null && (t.Starts("$ ") || t.Starts("← ") || t.Starts("→ Asked") || OpencodeText.Footer.Matches(l));
                if (t.Length == 0 || panel?.IsBlank() == true || pending)
                {
                    e--;
                }
                else
                {
                    break;
                }
            }
            return (e, ask ?? i, working, question);
        }
        // The input box: empty lines and the line with the mode and the model.
        while (end > 0)
        {
            if (OpencodeText.Panel(lines[end - 1]) is not { } c)
            {
                break;
            }
            if (c.IsBlank() || c.Has(" · "))
            {
                end--;
            }
            else
            {
                break;
            }
        }
        return (end, null, working, false);
    }

    // Parses the output lines of opencode into its thread.
    internal static AgentThread Opencode(IReadOnlyList<string> lines)
    {
        var found = OpencodeEnd(lines);
        var end = found.End;
        var working = found.Working;
        var worked = "";
        while (end > 0 && lines[end - 1].IsBlank())
        {
            end--;
        }
        if (end > 0 && OpencodeText.Footer.Matches(lines[end - 1]))
        {
            if (!working)
            {
                worked = OpencodeText.FooterTime.First(lines[end - 1])?.Groups[1] ?? "";
            }
            end--;
        }
        var blocks = new List<ThreadBlock>();
        var message = new List<string>();
        void FlushMessage()
        {
            while (message.Count > 0 && message[^1].Length == 0)
            {
                message.RemoveAt(message.Count - 1);
            }
            // The lines keep their indent under the first line, for example the lines of code in a message.
            // A line with 1 more blank than the first line is a new line of the text, not an indent.
            var text = Dedent(message).Select(l => l.Starts(" ") && !l.Starts("  ") ? l[1..] : l).ToList();
            if (text.Count > 0)
            {
                blocks.Add(new ThreadBlock.Message(string.Join("\n", text)));
            }
            message.Clear();
        }
        var i = 0;
        while (i < end)
        {
            var line = lines[i];
            if (OpencodeText.Panel(line) is { } panel)
            {
                FlushMessage();
                var j = i;
                while (j < end && OpencodeText.Panel(lines[j]) is not null)
                {
                    j++;
                }
                // A panel starts with a blank row. A panel at the start of the output without one lost
                // its first rows to the limit of the read, so it shows as terminal lines.
                if (i == 0 && !panel.IsBlank())
                {
                    blocks.Add(new ThreadBlock.Raw(i, j));
                }
                else
                {
                    var content = new List<string>();
                    for (var k = i; k < j; k++)
                    {
                        content.Add(OpencodeText.Panel(lines[k])!);
                    }
                    blocks.AddRange(OpencodePanel(content));
                }
                i = j;
                continue;
            }
            var t = line.Trimmed();
            if (t.Length == 0)
            {
                if (message.Count > 0)
                {
                    message.Add("");
                }
            }
            else if (OpencodeText.Footer.Matches(line))
            {
                FlushMessage();
            }
            else if (OpencodeText.Shell.Matches(t) || OpencodeText.Tool.Matches(t))
            {
                FlushMessage();
                blocks.Add(new ThreadBlock.Tool(OpencodeTool(t, [])));
            }
            else if (OpencodeText.Thought.Matches(t))
            {
                // The time that the model thought, for example "+ Thought: 37.7s", is not a message.
            }
            else if (ThreadText.TitledRule.Matches(t) || ThreadText.RuleOnly.Matches(t))
            {
                // The rule where opencode compacted the session, for example "─── Compaction ───".
                FlushMessage();
            }
            else if (t.Starts("···"))
            {
                FlushMessage();
                blocks.Add(new ThreadBlock.Raw(i, i + 1));
            }
            else
            {
                message.Add(line);
            }
            i++;
        }
        FlushMessage();
        return new AgentThread(MergeEdits(blocks), working ? "Working" : "", "", worked);
    }

    // The blocks of a panel of opencode: a prompt of the user, then tool
    // calls with their output. A question that the user answered shows as
    // the question of the agent and the answer of the user.
    internal static List<ThreadBlock> OpencodePanel(IReadOnlyList<string> content)
    {
        var output = new List<ThreadBlock>();
        var rows = content.Select(c => c.Trimmed()).Where(r => r.Length > 0).ToList();
        if (rows.Count > 0 && rows[0] == OpencodeText.Questions)
        {
            // Each line that ends with a question mark starts a question. The lines after it are the answer.
            string? q = null;
            var answer = new List<string>();
            void Flush()
            {
                if (q is not null)
                {
                    output.Add(new ThreadBlock.Message(q));
                }
                if (answer.Count > 0)
                {
                    output.Add(new ThreadBlock.Prompt(string.Join("\n", answer)));
                }
                answer.Clear();
            }
            foreach (var r in rows.Skip(1))
            {
                if (r.Ends("?"))
                {
                    Flush();
                    q = r;
                }
                else
                {
                    answer.Add(r);
                }
            }
            Flush();
            return output;
        }
        // A tool shows its output in a panel with a title, for example "# Todos" or "# Created a.ts".
        if (rows.Count > 0 && rows[0].Starts("# "))
        {
            var title = rows[0];
            var at = 0;
            for (var k = 0; k < content.Count; k++)
            {
                if (content[k].Trimmed() == title)
                {
                    at = k;
                    break;
                }
            }
            var rest = Range(content, at + 1, content.Count);
            // "# Running in /tmp/x" names the folder of the shell command under it.
            if (rest.Any(OpencodeText.IsMarker))
            {
                return OpencodePanel(rest);
            }
            return [new ThreadBlock.Tool(OpencodeTitled(title[2..].Trimmed(), rest))];
        }
        var i = 0;
        var prompt = new List<string>();
        while (i < content.Count && !OpencodeText.IsMarker(content[i]))
        {
            prompt.Add(content[i]);
            i++;
        }
        var trimmedPrompt = prompt.Select(p => p.Trimmed()).SkipWhile(p => p.Length == 0).ToList();
        while (trimmedPrompt.Count > 0 && trimmedPrompt[^1].Length == 0)
        {
            trimmedPrompt.RemoveAt(trimmedPrompt.Count - 1);
        }
        var text = string.Join("\n", trimmedPrompt);
        if (text.Length > 0)
        {
            output.Add(new ThreadBlock.Prompt(text));
        }
        while (i < content.Count)
        {
            var head = content[i].Trimmed();
            i++;
            // A long command wraps to more rows, until the first blank row.
            if (OpencodeText.Shell.Matches(head))
            {
                while (i < content.Count && !content[i].IsBlank() && !OpencodeText.IsMarker(content[i]))
                {
                    head = TermText.JoinWrapped(head, content[i].Trimmed());
                    i++;
                }
            }
            var body = new List<string>();
            while (i < content.Count && !OpencodeText.IsMarker(content[i]))
            {
                body.Add(content[i]);
                i++;
            }
            output.Add(new ThreadBlock.Tool(OpencodeTool(head, body)));
        }
        return output;
    }

    // A tool call of opencode from the title of its panel and the body
    // lines under it:
    // - "Created a.ts" and "Wrote a.ts" write a file, "Deleted a.ts"
    //   deletes one, and "Edited a.ts" edits one. They count the changed lines.
    // - "Todos" lists the tasks of the agent. Its arguments tell how many are done.
    // - Another title is the name of the tool.
    internal static ThreadTool OpencodeTitled(string title, IReadOnlyList<string> body)
    {
        var verb = title.Before(" ");
        var path = title.After(" ", "");
        var lines = Dedent(body.Where(l => !OpencodeText.Hints.Contains(l.Trimmed())).ToList());
        if (verb == "Todos")
        {
            var tasks = lines.Where(l => !l.IsBlank()).ToList();
            var done = tasks.Count(t => t.Starts("[✓]") || t.Starts("[x]"));
            return new ThreadTool("Todos", tasks.Count == 0 ? "" : $"{done} of {tasks.Count} done", tasks);
        }
        string name;
        switch (verb)
        {
            case "Created":
            case "Wrote":
            case "Written":
                name = "Write";
                break;
            case "Deleted":
            case "Removed":
                name = "Delete";
                break;
            case "Edited":
            case "Modified":
            case "Patched":
            case "Updated":
                name = "Edit";
                break;
            default:
                return new ThreadTool(title, "", lines);
        }
        if (path.Length == 0)
        {
            return new ThreadTool(title, "", lines);
        }
        var result = UnifySplitDiff(lines) ?? lines;
        var (added, minus) = DiffCounts(result);
        var removed = minus;
        if (name == "Delete" && removed == 0)
        {
            removed = OpencodeText.LineCount.First(string.Join("\n", lines)) is { } m ? ThreadText.Int(m.Groups[1]) ?? 0 : 0;
        }
        return new ThreadTool(name, path, result, false, new FileChange(path, added, removed));
    }

    // The counts of added and removed lines in the lines of a diff of opencode.
    internal static (int Added, int Removed) DiffCounts(IReadOnlyList<string> lines)
    {
        var added = lines.Count(l => OpencodeText.DiffLine.First(l)?.Groups[1] == "+" || l.Starts("+ ") || l == "+");
        var removed = lines.Count(l => OpencodeText.DiffLine.First(l)?.Groups[1] == "-" || l.Starts("- ") || l == "-");
        return (added, removed);
    }

    // Turns a split diff of opencode into a unified diff, or returns null
    // when lines are not a split diff. opencode shows the old lines at the
    // left and the new lines at the right in a wide terminal, and each side
    // wraps its long lines. On a phone, 1 column reads better: context lines
    // start with 2 blanks, removed lines with "- ", and added lines with
    // "+ ". The removed lines of a change come before its added lines.
    public static IReadOnlyList<string>? UnifySplitDiff(IReadOnlyList<string> lines)
    {
        // The numbers are aligned at their right end, so the column after the numbers of the right side is the same in each row.
        var ends = new Dictionary<int, int>();
        var leftRows = 0;
        foreach (var l in lines)
        {
            var cells = new CellText(l);
            foreach (var (index, length) in OpencodeText.SplitMark.All(l))
            {
                var start = cells.CellAt(index);
                if (start < OpencodeText.SplitMinCol)
                {
                    leftRows++;
                }
                else
                {
                    var end = start + TermCells.Count(l.Substring(index, length));
                    ends[end] = ends.GetValueOrDefault(end) + 1;
                }
            }
        }
        if (ends.Count == 0)
        {
            return null;
        }
        var best = ends.OrderByDescending(e => e.Value).ThenBy(e => e.Key).First();
        var right = best.Key;
        if (best.Value < 2 || best.Value * 2 < leftRows)
        {
            return null;
        }
        var digits = lines.Select(l =>
        {
            var c = new CellText(l);
            if (c.Count <= right)
            {
                return 0;
            }
            var n = 0;
            for (var k = right - 1; k >= 0 && char.IsAsciiDigit(c.Single(k)); k--)
            {
                n++;
            }
            return n;
        }).DefaultIfEmpty(0).Max();
        var split = right - digits;
        var output = new List<string>();
        var removed = new List<string>();
        var added = new List<string>();
        // The line that a wrapped row continues on each side.
        (List<string> List, int Index)? lastLeft = null;
        (List<string> List, int Index)? lastRight = null;
        void Flush()
        {
            output.AddRange(removed.Select(r => "- " + r));
            output.AddRange(added.Select(a => "+ " + a));
            removed.Clear();
            added.Clear();
        }
        static void Extend((List<string> List, int Index)? target, string text)
        {
            if (target is not { } t || text.IsBlank())
            {
                return;
            }
            t.List[t.Index] = TermText.JoinWrapped(t.List[t.Index], text.Trimmed());
        }
        foreach (var l in lines)
        {
            var c = new CellText(l);
            var leftText = c.Slice(0, Math.Min(split, c.Count));
            var rightText = c.Count > split ? c.Slice(split, c.Count) : "";
            var left = OpencodeText.SplitSide.Whole(leftText);
            var rightSide = OpencodeText.SplitSide.Whole(rightText);
            if (left is null && rightSide is null)
            {
                // A wrapped row: each side continues its last line.
                Extend(lastLeft, leftText);
                Extend(lastRight, rightText);
                continue;
            }
            var lm = left?[2];
            var rm = rightSide?[2];
            if (lm != "-" && rm != "+")
            {
                // A context line shows once.
                Flush();
                output.Add("  " + (left ?? rightSide!)[3].TrimmedEnd());
                lastLeft = (output, output.Count - 1);
                lastRight = null;
                continue;
            }
            lastLeft = null;
            lastRight = null;
            if (lm == "-" && left is not null)
            {
                removed.Add(left[3].TrimmedEnd());
                lastLeft = (removed, removed.Count - 1);
            }
            if (rm == "+" && rightSide is not null)
            {
                added.Add(rightSide[3].TrimmedEnd());
                lastRight = (added, added.Count - 1);
            }
        }
        Flush();
        return output;
    }

    // A tool call of opencode from its head line and the body lines under it.
    internal static ThreadTool OpencodeTool(string head, IReadOnlyList<string> body)
    {
        var lines = Dedent(body.Where(l => !OpencodeText.Hints.Contains(l.Trimmed())).ToList());
        if (OpencodeText.Shell.Whole(head) is { } shell)
        {
            return new ThreadTool("Bash", shell[1], lines);
        }
        if (OpencodeText.Tool.Whole(head) is not { } m)
        {
            return new ThreadTool(head, "", lines);
        }
        var name = m[2];
        var args = OpencodeText.Options.Replace(m[3], "").Trimmed();
        var result = (m[1] == "←" ? UnifySplitDiff(lines) : null) ?? lines;
        var failed = result.Count > 0 && result[0].TrimStartText().Starts("Error");
        FileChange? change = null;
        if (m[1] == "←" && args.Length > 0)
        {
            var (plus, removed) = DiffCounts(result);
            var added = plus;
            // A new file shows its lines with numbers and no mark.
            if (added == 0 && removed == 0 && name == "Write")
            {
                added = result.Count(OpencodeText.Numbered.Contains);
            }
            change = new FileChange(args, added, removed);
        }
        return new ThreadTool(name, args, result, failed, change);
    }

    // The question of the permission dialog of opencode, or null when the
    // output has no dialog. The title of the dialog, for example "# Shell
    // command", does not show. A shell command shows as the command. An
    // edit shows the file, then the first maxLines lines of its diff.
    internal static AgentAsk? OpencodeAsk(IReadOnlyList<string> lines, int maxLines)
    {
        var end = OpencodeEnd(lines);
        if (end.Dialog is not { } ask)
        {
            return null;
        }
        if (end.Question)
        {
            // The question is the text above the first choice. The choices show as buttons.
            var text = new List<string>();
            for (var k = ask; k < lines.Count; k++)
            {
                if (OpencodeText.Panel(lines[k])?.Trimmed() is not { } c)
                {
                    continue;
                }
                if (OpencodeText.ChoiceStart.Matches(c))
                {
                    break;
                }
                if (c.Length > 0)
                {
                    text.Add(c);
                }
            }
            return new AgentAsk(string.Join(" ", text), ValueList<string>.Empty);
        }
        var rows = new List<string>();
        for (var k = ask + 1; k < lines.Count; k++)
        {
            if (OpencodeText.Panel(lines[k]) is not { } c)
            {
                break;
            }
            if (c.Has("⇆") || c.Has("enter confirm"))
            {
                break;
            }
            rows.Add(OpencodeText.ScrollBar.Replace(c, "").TrimmedEnd());
        }
        var content = Dedent(rows);
        var question = OpencodeText.Ask[2..];
        if (content.Count == 0)
        {
            return new AgentAsk(question, ValueList<string>.Empty);
        }
        var title = content[0].Trimmed();
        var body = content.Skip(1).SkipWhile(l => l.IsBlank()).Where(l => !l.IsBlank()).ToList();
        var n = Math.Max(0, maxLines);
        if (title.Starts("#") && body.Count > 0 && body[0].Starts("$ "))
        {
            return new AgentAsk(question, body.Take(n), true);
        }
        if (title.Starts("→ ") || title.Starts("← "))
        {
            return new AgentAsk(question, new[] { title[2..] }.Concat(body).Take(n));
        }
        return new AgentAsk(question, new[] { title }.Concat(body).Take(n));
    }
}

public sealed partial record AgentThread
{
    // The first character of a row of a table that Claude Code draws.
    const string TableEdges = "┌├└│╭╰┏┣┗┃╔╠╚║";

    // The characters after the first one that make a row of a table.
    const string TableInner = "│┃║┐┤┘┬┼┴╮╯┓┫┛╗╣╝";

    // The bars between the cells of a row of a table.
    static readonly char[] TableBars = ['│', '┃', '║'];

    // The mark of a changed line in the result of an edit: + or -, after the number of the line when it has one.
    static readonly ThreadPattern ChangeMarkLine = new($"^{ThreadText.Sp}*(?:[0-9]+ ([+-])|([+-])(?: |$))");

    // True when line is a row of a table: it starts with an edge and has another box character after it.
    internal static bool IsTableRow(string line)
    {
        var t = line.TrimStartText();
        if (t.Length == 0 || TermCells.Count(t) <= 1 || !TableEdges.Contains(t[0]))
        {
            return false;
        }
        return t.Skip(1).Any(c => TableInner.Contains(c));
    }

    // Splits the text of a message into text and tables. A table keeps its
    // rows as they are, because its columns line up only in a mono font.
    public static IReadOnlyList<MessagePart> MessageParts(string text)
    {
        var output = new List<MessagePart>();
        var run = new List<string>();
        var table = false;
        void Flush()
        {
            var t = string.Join("\n", run);
            if (!table)
            {
                t = t.Trim('\n');
            }
            if (!t.IsBlank())
            {
                output.Add(new MessagePart(t, table));
            }
            run.Clear();
        }
        foreach (var l in text.Split('\n'))
        {
            var row = IsTableRow(l);
            if (row != table)
            {
                Flush();
                table = row;
            }
            run.Add(l);
        }
        Flush();
        return output;
    }

    // The cells of a table that the agent drew with box characters, row by
    // row, or null when text is not such a table or its rows have different
    // counts of cells. A rule separates 2 rows. The rows between 2 rules are
    // 1 row whose cells wrapped, so their parts join. The first row is the
    // header when a rule follows it.
    public static IReadOnlyList<IReadOnlyList<string>>? ParseTable(string text)
    {
        var rows = new List<IReadOnlyList<string>>();
        List<List<string>>? parts = null;
        void Flush()
        {
            if (parts is not null)
            {
                rows.Add(parts.Select(p => string.Join(" ", p)).ToArray());
            }
            parts = null;
        }
        foreach (var raw in text.Split('\n'))
        {
            var l = raw.Trimmed();
            if (l.Length == 0)
            {
                continue;
            }
            if (!TableBars.Contains(l[0]))
            {
                Flush();
                continue;
            }
            var pieces = l.Split(TableBars);
            var cells = pieces.Skip(1).Take(Math.Max(0, pieces.Length - 2)).Select(c => c.Trimmed()).ToList();
            if (cells.Count == 0)
            {
                return null;
            }
            var p = parts ?? cells.Select(_ => new List<string>()).ToList();
            if (p.Count != cells.Count)
            {
                return null;
            }
            for (var i = 0; i < cells.Count; i++)
            {
                if (cells[i].Length > 0)
                {
                    p[i].Add(cells[i]);
                }
            }
            parts = p;
        }
        Flush();
        if (rows.Count == 0 || rows.Any(r => r.Count != rows[0].Count))
        {
            return null;
        }
        return rows;
    }

    // The mark of a changed line in the result of an edit, '+' or '-', or null for another line.
    public static char? ChangeMark(string line)
    {
        if (ChangeMarkLine.First(line) is not { } m)
        {
            return null;
        }
        var mark = m.Groups[1].Length == 0 ? m.Groups[2] : m.Groups[1];
        return mark.Length > 0 ? mark[0] : null;
    }
}

public sealed partial record DiffFile
{
    // Parses the review diff that fluxd sends, a git diff with a list of the
    // changed files above it, into files. The lines above the first file and
    // the headers of each file do not show.
    public static IReadOnlyList<DiffFile> Parse(IReadOnlyList<string> lines)
    {
        var files = new List<DiffFile>();
        string? path = null;
        var added = 0;
        var removed = 0;
        var body = new List<DiffLine>();
        var inHunk = false;
        void Flush()
        {
            // fluxd puts an empty line above each new file. It is not a line of the file before it.
            while (body.Count > 0 && body[^1].Kind == DiffLineKind.Context && body[^1].Text.IsBlank())
            {
                body.RemoveAt(body.Count - 1);
            }
            if (path is not null)
            {
                files.Add(new DiffFile(path, added, removed, body.ToArray()));
            }
            path = null;
            added = 0;
            removed = 0;
            body.Clear();
            inHunk = false;
        }
        foreach (var l in lines)
        {
            if (l.Starts("diff --git "))
            {
                Flush();
                var rest = l["diff --git ".Length..];
                path = l.After(" b/", rest.After("a/", rest)).Trimmed();
                continue;
            }
            if (path is null)
            {
                continue;
            }
            if (l.Starts("@@"))
            {
                inHunk = true;
                body.Add(new DiffLine(l, DiffLineKind.Hunk));
            }
            else if (!inHunk)
            {
                // A new file of fluxd has no hunk. Its lines start with + at once.
                if (l.Starts("+") && !l.Starts("+++"))
                {
                    inHunk = true;
                    added++;
                    body.Add(new DiffLine(l, DiffLineKind.Added));
                }
                else if (l == "Binary file" || l.Starts("The new file is larger"))
                {
                    body.Add(new DiffLine(l, DiffLineKind.Context));
                }
            }
            else if (l.Starts("+"))
            {
                added++;
                body.Add(new DiffLine(l, DiffLineKind.Added));
            }
            else if (l.Starts("-"))
            {
                removed++;
                body.Add(new DiffLine(l, DiffLineKind.Removed));
            }
            else
            {
                body.Add(new DiffLine(l, DiffLineKind.Context));
            }
        }
        Flush();
        // fluxd adds an empty line at the end of each new file.
        return files.Select(f => f.Lines.Count > 0 && f.Lines[^1].Text == "+"
            ? new DiffFile(f.Path, f.Added - 1, f.Removed, f.Lines.Take(f.Lines.Count - 1))
            : f).ToArray();
    }
}

// String helpers with the meaning of the Swift and Kotlin helpers. The class
// is local to this file, so that its names do not meet other helpers.
file static class StringOps
{
    // The text without whitespace at the start and the end.
    public static string Trimmed(this string s) => s.Trim();

    // The text without whitespace at the end.
    public static string TrimmedEnd(this string s) => s.TrimEnd();

    // True when the text is empty or has only whitespace.
    public static bool IsBlank(this string s) => string.IsNullOrWhiteSpace(s);

    // The number of blanks at the start, or the length of a text of blanks.
    public static int Indent(this string s) => TermCells.Lead(s);

    // The text after the first delimiter, or missing without it.
    public static string After(this string s, string delimiter, string missing)
    {
        var i = s.IndexOf(delimiter, StringComparison.Ordinal);
        return i < 0 ? missing : s[(i + delimiter.Length)..];
    }

    // The text before the first delimiter, or the whole text without it.
    public static string Before(this string s, string delimiter)
    {
        var i = s.IndexOf(delimiter, StringComparison.Ordinal);
        return i < 0 ? s : s[..i];
    }

    public static bool Starts(this string s, string prefix) => s.StartsWith(prefix, StringComparison.Ordinal);
    public static bool Ends(this string s, string suffix) => s.EndsWith(suffix, StringComparison.Ordinal);
    public static bool Has(this string s, string part) => s.Contains(part, StringComparison.Ordinal);

    // The text without whitespace at the start, as Kotlin's trimStart.
    public static string TrimStartText(this string s) => s.TrimStart();
}
