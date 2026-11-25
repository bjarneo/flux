using FluxKit;

namespace FluxKit.Tests;

// The thread of an agent: messages, tool calls, changes, prompts, the
// question of a dialog, and the review diff. The same cases as
// AgentThreadTests.swift of the Mac app and AgentThreadTest.kt of the
// Android app.
public class AgentThreadTests
{
    // The sample output of the demo computer: an approval dialog of Claude Code, with terminal colors.
    const string Demo =
        "\u001B[38;2;215;119;87m●\u001B[0m I added the migration in \u001B[1mdb/migrate/0042_add_invoice_status.sql\u001B[0m.\n\n" +
        "\u001B[38;5;2m●\u001B[0m \u001B[1mBash\u001B[0m(bin/migrate --dry-run)\n" +
        "  \u001B[38;5;8m⎿\u001B[0m  1 migration to apply: \u001B[38;5;6m0042_add_invoice_status\u001B[0m\n\n" +
        "\u001B[38;5;4m────────────────────────────────────────────────────────────────────────\u001B[0m\n" +
        " \u001B[1;38;5;4mBash command\u001B[0m\n\n" +
        "   bin/migrate --apply\n" +
        "   \u001B[38;5;8mApply the pending migration\u001B[0m\n\n" +
        " Do you want to proceed?\n" +
        " \u001B[38;5;4m❯ 1. Yes\u001B[0m\n" +
        "   2. Yes, and do not ask again for bin/migrate commands\n" +
        "   3. No, and tell Codex what to do differently \u001B[38;5;8m(esc)\u001B[0m\n";

    static string[] Text(string ansi) => TermText.Lines(ansi).Select(l => l.Text).ToArray();

    static ThreadTool? Tool(ThreadBlock b) => b is ThreadBlock.Tool t ? t.Call : null;

    static ThreadBlock.Tool ToolBlock(string name, string args, params string[] result) => new(new ThreadTool(name, args, result));

    [Fact]
    public void DemoHasA72ColumnRule()
    {
        Assert.Contains(Text(Demo), l => l.Length == 72 && l.All(c => c == '─'));
    }

    [Fact]
    public void DemoGivesTheMessageAndTheToolAndNoDialog()
    {
        var t = AgentThread.Parse(Text(Demo));
        Assert.Equal(
        [
            new ThreadBlock.Message("I added the migration in db/migrate/0042_add_invoice_status.sql."),
            ToolBlock("Bash", "bin/migrate --dry-run", "1 migration to apply: 0042_add_invoice_status"),
        ], t.Blocks);
        Assert.Equal("", t.Step);
        Assert.Equal("", t.Worked);
    }

    [Fact]
    public void DemoAskHasTheQuestionAndTheCommand()
    {
        var ask = AgentAsk.Find(Text(Demo))!;
        Assert.Equal("Do you want to proceed?", ask.Question);
        Assert.Equal(["$ bin/migrate --apply", "Apply the pending migration"], ask.Lines);
        Assert.True(ask.Command);
    }

    [Fact]
    public void NoChoicesGiveNoAsk()
    {
        Assert.Null(AgentAsk.Find(["● Done.", "", "> "]));
        Assert.Null(AgentAsk.DialogStart(["● Done."]));
    }

    [Fact]
    public void TwoEditsMergeIntoChanges()
    {
        string[] lines =
        [
            "● I wrote the migration.",
            "",
            "● Write(db/migrate/0042.sql)",
            "  ⎿  Wrote 18 lines to db/migrate/0042.sql",
            "",
            "● Update(app/models/invoice.rb)",
            "  ⎿  Updated app/models/invoice.rb with 24 additions and 7 removals",
            "",
            "● Bash(bin/migrate --dry-run)",
            "  ⎿  1 migration to apply",
        ];
        var blocks = AgentThread.Parse(lines).Blocks;
        Assert.Equal(3, blocks.Count);
        var c = Assert.IsType<ThreadBlock.Changes>(blocks[1]).Files;
        Assert.Equal([new FileChange("db/migrate/0042.sql", 18, 0), new FileChange("app/models/invoice.rb", 24, 7)], c.Files);
        Assert.Equal(42, c.Added);
        Assert.Equal(7, c.Removed);
        Assert.Equal("Bash", Tool(blocks[2])?.Name);
    }

    [Fact]
    public void OneEditStaysATool()
    {
        string[] lines =
        [
            "● Update(tests/login.spec.ts)",
            "  ⎿  Updated tests/login.spec.ts with 4 additions and 2 removals",
            "",
            "● Bash(npm test -- login)",
            "  ⎿  20 passed",
        ];
        var blocks = AgentThread.Parse(lines).Blocks;
        Assert.Equal(2, blocks.Count);
        Assert.Equal("Update", Tool(blocks[0])?.Name);
        Assert.Equal(new FileChange("tests/login.spec.ts", 4, 2), Tool(blocks[0])?.Change);
        Assert.Null(Tool(blocks[1])?.Change);
    }

    [Fact]
    public void WorkingScreenGivesTheStepAndDropsTheInput()
    {
        string[] lines =
        [
            "● I'll add a token bucket.",
            "",
            "● Bash(npm test -- upload)",
            "  ⎿  Running 48 tests…",
            "     31 passed",
            "",
            "✻ Running tests… (2:14 · esc to interrupt)",
            "  ⎿  ☐ Report back",
            "",
            "╭──────────────────────╮",
            "│ >                    │",
            "╰──────────────────────╯",
            "  ? for shortcuts",
        ];
        var t = AgentThread.Parse(lines);
        Assert.Equal("Running tests", t.Step);
        Assert.Equal("2:14", t.Elapsed);
        Assert.Equal(
        [
            new ThreadBlock.Message("I'll add a token bucket."),
            ToolBlock("Bash", "npm test -- upload", "Running 48 tests…", "31 passed"),
        ], t.Blocks);
    }

    [Fact]
    public void ANumberedListAtTheEndStaysInTheThread()
    {
        var rule = new string('─', 40);
        string[] lines =
        [
            "● Here is what I would add.",
            "",
            "  Highest value",
            "     ",
            "  1. Notify when an agent needs you. Send a desktop notification when an agent",
            "     asks a question.",
            "  2. Hide finished agents.",
            "",
            "  Small fixes",
            "",
            "  3. Show the full command.",
            "",
            "  I would start with 1 and 2.",
            "",
            "✻ Cogitated for 24s · done 10:00 AM",
            "",
            rule,
            "❯ ",
            rule,
            "  ⏵⏵ auto mode on (shift+tab to cycle)",
        ];
        Assert.Null(AgentAsk.DialogStart(lines));
        var t = AgentThread.Parse(lines);
        Assert.Equal("24s", t.Worked);
        var text = Assert.IsType<ThreadBlock.Message>(Assert.Single(t.Blocks)).Text;
        Assert.StartsWith("Here is what I would add.", text);
        Assert.Contains("3. Show the full command.", text);
        Assert.EndsWith("I would start with 1 and 2.", text);
    }

    [Fact]
    public void CodexWorkingLineGivesTheTime()
    {
        var t = AgentThread.Parse(["• I will run it.", "", "• Working (12s • esc to interrupt)", "", "› Ask Codex to do anything"]);
        Assert.Equal("Working", t.Step);
        Assert.Equal("12s", t.Elapsed);
        Assert.Equal([new ThreadBlock.Message("I will run it.")], t.Blocks);
    }

    [Fact]
    public void RuledInputAndHintsGo()
    {
        string[] lines =
        [
            "● All tests pass.",
            "",
            "────────────────────",
            "> ",
            "────────────────────",
            "  ⏵⏵ accept edits on (shift+tab to cycle)",
        ];
        Assert.Equal([new ThreadBlock.Message("All tests pass.")], AgentThread.Parse(lines).Blocks);
    }

    [Fact]
    public void ResultHintIsNotAFooter()
    {
        string[] lines =
        [
            "● Read(src/a.ts)",
            "  ⎿  line 1",
            "     … +12 lines (ctrl+r to expand)",
        ];
        var blocks = AgentThread.Parse(lines).Blocks;
        Assert.Single(blocks);
        Assert.Equal(["line 1", "… +12 lines (ctrl+r to expand)"], Tool(blocks[0])!.Result);
    }

    [Fact]
    public void DoneLineGivesTheTime()
    {
        var t = AgentThread.Parse(["● The test passed 20 times.", "", "✻ Worked for 6m 12s", "", "> ", "  ? for shortcuts"]);
        Assert.Equal("6m 12s", t.Worked);
        Assert.Equal([new ThreadBlock.Message("The test passed 20 times.")], t.Blocks);
    }

    [Fact]
    public void CodexDoneRuleGivesTheTime()
    {
        var t = AgentThread.Parse(["• Done.", "", "─ Worked for 1m 03s ──────────"]);
        Assert.Equal("1m 03s", t.Worked);
        Assert.Equal([new ThreadBlock.Message("Done.")], t.Blocks);
    }

    [Fact]
    public void PromptsAndParagraphs()
    {
        string[] lines =
        [
            "> Fix the login test",
            "",
            "● The test waited on a fixed timeout.",
            "  It now waits for the cookie.",
            "",
            "",
            "  The run passed 20 times.",
            "",
            "● Bash(npm test)",
            "  ⎿  20 passed",
        ];
        var blocks = AgentThread.Parse(lines).Blocks;
        Assert.Equal(new ThreadBlock.Prompt("Fix the login test"), blocks[0]);
        Assert.Equal(new ThreadBlock.Message("The test waited on a fixed timeout.\nIt now waits for the cookie.\n\nThe run passed 20 times."), blocks[1]);
        Assert.Equal(3, blocks.Count);
    }

    [Fact]
    public void CodexToolsAndMessages()
    {
        string[] lines =
        [
            "› Run the migration",
            "",
            "• I will run it.",
            "",
            "• Ran bin/migrate --dry-run",
            "  └ 1 migration to apply",
            "",
            "• Edited src/a.ts (+3 -1)",
            "    1 -old",
            "    1 +new",
        ];
        var blocks = AgentThread.Parse(lines).Blocks;
        Assert.Equal(new ThreadBlock.Prompt("Run the migration"), blocks[0]);
        Assert.Equal(new ThreadBlock.Message("I will run it."), blocks[1]);
        Assert.Equal(ToolBlock("Ran", "bin/migrate --dry-run", "1 migration to apply"), blocks[2]);
        Assert.Equal("Edited", Tool(blocks[3])?.Name);
        Assert.Equal("src/a.ts", Tool(blocks[3])?.Args);
        Assert.Equal(new FileChange("src/a.ts", 3, 1), Tool(blocks[3])?.Change);
        Assert.Equal(4, blocks.Count);
    }

    [Fact]
    public void CodexAddedAsAMessageIsNotATool()
    {
        var blocks = AgentThread.Parse(["• Added a token bucket in front of the handler."]).Blocks;
        Assert.Equal([new ThreadBlock.Message("Added a token bucket in front of the handler.")], blocks);
    }

    [Fact]
    public void CodexApprovalWithoutARule()
    {
        string[] lines =
        [
            "• I will apply the migration now.",
            "",
            "  Would you like to run the following command?",
            "",
            "  $ bin/migrate --apply",
            "",
            "› 1. Yes, proceed (y)",
            "  2. Yes, and don't ask again for this command (a)",
            "  3. No, and tell Codex what to do differently (esc)",
        ];
        var ask = AgentAsk.Find(lines)!;
        Assert.Equal("Would you like to run the following command?", ask.Question);
        Assert.Equal(["$ bin/migrate --apply"], ask.Lines);
        Assert.True(ask.Command);
        Assert.Equal([new ThreadBlock.Message("I will apply the migration now.")], AgentThread.Parse(lines).Blocks);
    }

    [Fact]
    public void AskKeepsTheLinesNearestTheChoices()
    {
        string[] lines =
        [
            "────────────",
            " Edit file",
            "",
            "   line 1",
            "   line 2",
            "   line 3",
            "   line 4",
            "   line 5",
            "",
            " Do you want to make this edit?",
            " ❯ 1. Yes",
            "   2. No",
        ];
        var ask = AgentAsk.Find(lines, maxLines: 3)!;
        Assert.Equal("Do you want to make this edit?", ask.Question);
        Assert.Equal(["line 3", "line 4", "line 5"], ask.Lines);
        Assert.False(ask.Command);
    }

    [Fact]
    public void UnknownLinesAreRaw()
    {
        string[] lines =
        [
            "",
            "╭─────────────╮",
            "│ Welcome     │",
            "╰─────────────╯",
            "",
            "● Hello.",
            "",
            "user@host:~$ ls",
            "",
            "a.txt",
            "",
            "● Bye.",
        ];
        Assert.Equal(
        [
            new ThreadBlock.Raw(1, 4),
            new ThreadBlock.Message("Hello."),
            new ThreadBlock.Raw(7, 10),
            new ThreadBlock.Message("Bye."),
        ], AgentThread.Parse(lines).Blocks);
    }

    [Fact]
    public void FailedEditIsNotMerged()
    {
        string[] lines =
        [
            "● Update(a.ts)",
            "  ⎿  Error: file not found",
            "",
            "● Update(b.ts)",
            "  ⎿  Updated b.ts with 1 addition",
        ];
        var blocks = AgentThread.Parse(lines).Blocks;
        Assert.Equal(2, blocks.Count);
        Assert.True(Tool(blocks[0])?.Failed);
        Assert.Equal(new FileChange("b.ts", 1, 0), Tool(blocks[1])?.Change);
    }

    [Fact]
    public void DiffGivesFilesAndCounts()
    {
        string[] lines =
        [
            "Changed files",
            " M app/x.rb",
            "?? n.txt",
            "",
            "Working tree changes",
            "diff --git a/app/x.rb b/app/x.rb",
            "index 1111111..2222222 100644",
            "--- a/app/x.rb",
            "+++ b/app/x.rb",
            "@@ -1,2 +1,3 @@",
            " class X",
            "-old",
            "+new",
            "+more",
            "",
            "diff --git a/n.txt b/n.txt",
            "new file",
            "+line1",
            "+",
        ];
        var files = DiffFile.Parse(lines);
        Assert.Equal(2, files.Count);
        Assert.Equal("app/x.rb", files[0].Path);
        Assert.Equal(2, files[0].Added);
        Assert.Equal(1, files[0].Removed);
        Assert.Equal([DiffLineKind.Hunk, DiffLineKind.Context, DiffLineKind.Removed, DiffLineKind.Added, DiffLineKind.Added],
            files[0].Lines.Select(l => l.Kind));
        Assert.Equal("n.txt", files[1].Path);
        Assert.Equal(1, files[1].Added);
        Assert.Equal(0, files[1].Removed);
        Assert.Equal([new DiffLine("+line1", DiffLineKind.Added)], files[1].Lines);
    }

    [Fact]
    public void NoChangesGiveNoFiles()
    {
        Assert.Empty(DiffFile.Parse(["No changes in this repository."]));
    }

    // opencode

    // A finished turn of opencode after the tidy step: a prompt, 2 edits, a shell command, a message, and the input box.
    static readonly string[] OpencodeDone =
    [
        "┃",
        "┃  Add a tax rate to total, then run the test.",
        "┃",
        "",
        "   → Read invoice.js",
        "",
        "┃",
        "┃  ← Edit invoice.js",
        "┃",
        "┃    1   // Invoices of a small billing app.",
        "┃    2 - export function total(lines) {",
        "┃    2 + export function total(lines, taxRate = 0) {",
        "┃    3     let sum = 0",
        "┃    5 -   return sum",
        "┃    5 +   return sum * (1 + taxRate)",
        "┃",
        "",
        "┃",
        "┃  ← Edit invoice.test.js",
        "┃",
        "┃    4 + if (total(lines, 0.25) !== 31.25) throw new Error('wrong')",
        "┃",
        "",
        "┃",
        "┃  $ node invoice.test.js",
        "┃",
        "┃  ok",
        "┃",
        "",
        "   Done. The total takes a tax rate:",
        "     total(lines, 0.25)",
        "",
        "   ▣  Build · Big Pickle · 21.2s",
        "",
        "┃",
        "┃  Build · Big Pickle OpenCode Zen",
        " ~/Code/billing                                          13.1K (7%)  ctrl+p commands",
    ];

    [Fact]
    public void OpencodeTurnGivesPromptToolsChangesAndTime()
    {
        var t = AgentThread.Parse(OpencodeDone);
        Assert.Equal(
        [
            new ThreadBlock.Prompt("Add a tax rate to total, then run the test."),
            ToolBlock("Read", "invoice.js"),
            new ThreadBlock.Changes(new ThreadChanges([new FileChange("invoice.js", 2, 2), new FileChange("invoice.test.js", 1, 0)])),
            ToolBlock("Bash", "node invoice.test.js", "ok"),
            new ThreadBlock.Message("Done. The total takes a tax rate:\n  total(lines, 0.25)"),
        ], t.Blocks);
        Assert.Equal("21.2s", t.Worked);
        Assert.Equal("", t.Step);
        // No dialog.
        Assert.Null(AgentAsk.Find(OpencodeDone));
    }

    [Fact]
    public void OpencodeWorkingHasAStepAndNoTime()
    {
        string[] lines =
        [
            "┃",
            "┃  ← Edit invoice.js",
            "┃",
            "┃    5 +   return sum * (1 + taxRate)",
            "┃",
            "",
            "   ▣  Build · Big Pickle",
            "┃",
            "┃",
            "┃  Build · Big Pickle OpenCode Zen",
            " ⬝⬝⬝⬝⬝⬝⬝⬝  esc interrupt                                 12.8K (6%)  ctrl+p commands",
        ];
        var t = AgentThread.Parse(lines);
        Assert.Equal("Working", t.Step);
        Assert.Equal("", t.Worked);
        Assert.Single(t.Blocks);
        var edit = Tool(t.Blocks[0])!;
        Assert.Equal("Edit", edit.Name);
        Assert.Equal(new FileChange("invoice.js", 1, 0), edit.Change);
    }

    [Fact]
    public void OpencodeShellPermissionIsTheCommand()
    {
        string[] lines =
        [
            "   $ node invoice.test.js",
            "   ▣  Build · Big Pickle",
            "┃",
            "┃  △ Permission required",
            "┃    # Shell command",
            "┃",
            "┃  $ node invoice.test.js",
            "┃",
            "┃",
            "┃   Allow once   Allow always   Reject  ctrl+f fullscreen  ⇆ select  enter confirm",
            "┃",
        ];
        Assert.Equal(new AgentAsk("Permission required", ["$ node invoice.test.js"], true), AgentAsk.Find(lines));
        // The waiting command and the line of the turn belong to the dialog.
        Assert.Empty(AgentThread.Parse(lines).Blocks);
    }

    [Fact]
    public void OpencodeEditPermissionIsTheFileAndTheDiff()
    {
        string[] lines =
        [
            "┃",
            "┃  △ Permission required",
            "┃    → Edit invoice.js",
            "┃",
            "┃  1   // Invoices of a small billing app.                                      █",
            "┃  2 - export function total(lines) {                                           █",
            "┃  2 + export function total(lines, taxRate = 0) {                              ▀",
            "┃",
            "┃   Allow once   Allow always   Reject  ctrl+f fullscreen  ⇆ select  enter confirm",
        ];
        Assert.Equal(
            new AgentAsk("Permission required", ["Edit invoice.js", "1   // Invoices of a small billing app.", "2 - export function total(lines) {"]),
            AgentAsk.Find(lines, maxLines: 3));
    }

    [Fact]
    public void OpencodeMenuRowGivesChoicesWithArrowKeys()
    {
        const string bar = "\u001B[38;2;240;198;116;48;2;43;46;49m┃\u001B[0m";
        const string gray = "48;2;50;53;57";
        const string accent = "48;2;240;198;116";
        var row = bar + $"\u001B[{gray}m  \u001B[{accent}m \u001B[38;2;29;31;33;{accent}mAllow once\u001B[{accent}m \u001B[0m" +
            $"\u001B[{gray}m  \u001B[38;2;169;169;169;{gray}mAllow always\u001B[{gray}m   \u001B[38;2;169;169;169;{gray}mReject" +
            $"\u001B[{gray}m  \u001B[38;2;197;200;198;{gray}mctrl+f \u001B[38;2;169;169;169;{gray}mfullscreen" +
            $"\u001B[{gray}m  \u001B[38;2;197;200;198;{gray}m⇆ \u001B[38;2;169;169;169;{gray}mselect\u001B[0m\n";
        Assert.Equal(
        [
            new AgentChoice("1", "Allow once", true, ["enter"]),
            new AgentChoice("2", "Allow always", false, ["right", "enter"]),
            new AgentChoice("3", "Reject", false, ["right", "right", "enter"]),
        ], AgentChoice.FindMenu(TermText.Lines(row)));
        // After a move to Reject, the arrows wrap to the first choice.
        var moved = row.Replace($"38;2;29;31;33;{accent}mAllow once", $"38;2;169;169;169;{gray}mAllow once")
            .Replace($"38;2;169;169;169;{gray}mReject", $"38;2;29;31;33;{accent}mReject");
        var after = AgentChoice.FindMenu(TermText.Lines(moved));
        Assert.Equal(["right", "enter"], after[0].Keys);
        Assert.Equal(["enter"], after[^1].Keys);
        // The choices of a numbered dialog go as their digit.
        Assert.Equal(["1"], AgentChoice.Find(["❯ 1. Yes", "  2. No"])[0].Keys);
        Assert.Equal("Sent key 1", AgentChoice.Find(["❯ 1. Yes", "  2. No"])[0].SentMeta);
        Assert.Equal("Selected in the menu", after[0].SentMeta);
    }

    [Fact]
    public void ClaudeOutputIsNotOpencode()
    {
        Assert.False(AgentThread.IsOpencode(Text(Demo)));
        Assert.True(AgentThread.IsOpencode(OpencodeDone));
    }

    // A question of opencode with 4 choices and descriptions, after the tidy step.
    static readonly string[] OpencodeQuestion =
    [
        "┃",
        "┃  ask me a question I can answer a b c or d to",
        "┃",
        "",
        "   + Thought: 984ms",
        "   The next step is a merge decision.",
        "   → Asked 1 question",
        "   ▣  Build · Grok 4.7",
        "┃",
        "┃  What should I do with the pull request?",
        "┃",
        "┃  1. A. Approve CI, merge if green",
        "┃     Approve the waiting runs. Merge only if both pass.",
        "┃  2. B. Full review before any merge",
        "┃     Read the change for bugs first.",
        "┃  3. C. Do not merge",
        "┃     Leave the pull request open.",
        "┃  4. D. Close the pull request",
        "┃     Reject the design.",
        "┃  5. Type your own answer",
        "┃",
        "┃  ↑↓ select  enter submit  esc dismiss",
        "┃",
    ];

    [Fact]
    public void OpencodeQuestionGivesTheQuestionAndChoicesWithDescriptions()
    {
        Assert.True(AgentThread.IsOpencode(OpencodeQuestion));
        Assert.Equal(new AgentAsk("What should I do with the pull request?", ValueList<string>.Empty), AgentAsk.Find(OpencodeQuestion));
        var choices = AgentChoice.Find(OpencodeQuestion);
        Assert.Equal(5, choices.Count);
        Assert.Equal(new AgentChoice("1", "A. Approve CI, merge if green", detail: "Approve the waiting runs. Merge only if both pass."), choices[0]);
        Assert.Equal(["4"], choices[3].Keys);
        Assert.Equal("", choices[^1].Detail);
        // The thought line, the tool call of the question, and the question itself are not in the thread.
        Assert.Equal(
        [
            new ThreadBlock.Prompt("ask me a question I can answer a b c or d to"),
            new ThreadBlock.Message("The next step is a merge decision."),
        ], AgentThread.Parse(OpencodeQuestion).Blocks);
    }

    [Fact]
    public void OpencodeAnsweredQuestionIsTheQuestionAndTheAnswer()
    {
        string[] lines =
        [
            "┃",
            "┃  # Questions",
            "┃",
            "┃  Which tax rate should total use?",
            "┃  C 0.25",
            "┃",
            "",
            "   ▣  Build · Big Pickle · 3.1s",
        ];
        Assert.Equal([new ThreadBlock.Message("Which tax rate should total use?"), new ThreadBlock.Prompt("C 0.25")], AgentThread.Parse(lines).Blocks);
    }

    [Fact]
    public void ClaudeQuestionDropsTheHeaderAndKeepsDescriptions()
    {
        string[] lines =
        [
            "● I need a decision.",
            "",
            new string('─', 40),
            " ☐ Tax rate",
            "",
            "Which tax rate should total use?",
            "",
            "❯ 1. A 0",
            "     No tax",
            "  2. B 0.25",
            "     A quarter",
            "  3. Type something.",
            "",
            "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
        ];
        Assert.Equal(new AgentAsk("Which tax rate should total use?", ValueList<string>.Empty), AgentAsk.Find(lines));
        var choices = AgentChoice.Find(lines);
        Assert.Equal(["No tax", "A quarter", ""], choices.Select(c => c.Detail));
        Assert.True(choices[0].Selected);
    }

    // Claude Code 2.1

    // An idle screen of Claude Code 2.1: the logo, prompts with ❯, tool summaries, and the ruled input with the name of the session.
    static readonly string[] Claude21 =
    [
        " ▐▛███▜▌   Claude Code v2.1.293",
        "▝▜█████▛▘  Opus 5.5 · Claude Max",
        "  ▘▘ ▝▝    ~/Code/billing",
        "",
        "❯ Fix the login test",
        "  ⎿  1 skill available",
        "",
        "  Read 2 files, listed 1 directory, ran 3 shell commands (ctrl+o to expand)",
        "",
        "● The test waited on a fixed timeout.",
        "",
        "  Ran 1 shell command",
        "  ⎿  “Tell the reviewer” → sent to billing-2",
        "",
        "● Bash(cat > /tmp/fix.py <<'EOF'",
        "      import sys",
        "  ⎿  done",
        "",
        "● Workflow(Rebase the 3 PRs into one chain and run make check at each",
        "          step)",
        "  ⎿  /workflows to view dynamic workflow runs",
        "",
        "✻ Sautéed for 6m 47s · done Tuesday 7:11 PM",
        "",
        "❯ Ship it",
        "",
        "● Shipped.",
        "",
        "✻ Worked for 22s · done 10:08 PM",
        "                                                              new task? /clear to save 671.7k tokens",
        "✦ Heads up · Publishing a release deploys to production.",
        "  1: Learn more   2: Knew this already   0: Dismiss",
        "──────────────────────────────────── Fix the login test ─",
        "❯",
        "────────────────────────────────────────────────────────",
        "  ▸▸ auto mode on (shift+tab to cycle) · ← for agents",
    ];

    [Fact]
    public void Claude21PromptsSummariesAndLongToolCalls()
    {
        var t = AgentThread.Parse(Claude21);
        Assert.Equal(
        [
            new ThreadBlock.Prompt("Fix the login test"),
            ToolBlock("Read", "2 files, listed 1 directory, ran 3 shell commands"),
            new ThreadBlock.Message("The test waited on a fixed timeout."),
            ToolBlock("Ran", "1 shell command", "“Tell the reviewer” → sent to billing-2"),
            ToolBlock("Bash", "cat > /tmp/fix.py <<'EOF' import sys", "done"),
            ToolBlock("Workflow", "Rebase the 3 PRs into one chain and run make check at each step", "/workflows to view dynamic workflow runs"),
            new ThreadBlock.Prompt("Ship it"),
            new ThreadBlock.Message("Shipped."),
        ], t.Blocks);
        Assert.Equal("22s", t.Worked);
        Assert.Equal("", t.Step);
    }

    [Fact]
    public void Claude21WorkingScreenGivesTheStepAndTheRunningCommand()
    {
        string[] lines =
        [
            "● I will capture the output.",
            "",
            // The bullet of a call that runs blinks, so this capture has 2 blanks in its place.
            "  Capture the output · 11s",
            "  ⎿  $ mkdir -p /tmp/cap && cat >",
            "     /tmp/cap/a.txt",
            "     (ctrl+b to run in background)",
            "",
            "✶ Orbiting… (1m 17s · ↓ 5.7k tokens)",
            "  ⎿  Tip: Use /btw to ask a quick side question",
            "                                                     Update available! Run: mise upgrade claude",
            "────────────────────────────────────────────────────",
            "❯",
            "────────────────────────────────────────────────────",
            "  ▸▸ auto mode on · 1 shell · esc to interrupt · ← for agents · ↓ to manage",
        ];
        var t = AgentThread.Parse(lines);
        Assert.Equal("Orbiting", t.Step);
        Assert.Equal("1m 17s", t.Elapsed);
        Assert.Equal(
        [
            new ThreadBlock.Message("I will capture the output."),
            ToolBlock("Bash", "Capture the output", "$ mkdir -p /tmp/cap && cat >", "/tmp/cap/a.txt"),
        ], t.Blocks);
    }

    [Fact]
    public void SummaryNeedsACountAndNoSentenceEnd()
    {
        string[] lines = ["● Done.", "", "  Waves 1 to 5 each passed.", "", "  Ran 20 tests and all passed."];
        Assert.Single(AgentThread.Parse(lines).Blocks);
    }

    [Fact]
    public void ALineAtTheLeftEdgeContinuesTheHead()
    {
        string[] lines = ["● Dynamic workflow \"Build the PRs\"", "completed · 7h 55m", "", "● Next."];
        Assert.Equal(
            [new ThreadBlock.Message("Dynamic workflow \"Build the PRs\"\ncompleted · 7h 55m"), new ThreadBlock.Message("Next.")],
            AgentThread.Parse(lines).Blocks);
    }

    [Fact]
    public void MessageSplitsIntoTextAndTables()
    {
        const string text = "The PRs are open:\n┌───┬────┐\n│ # │ PR │\n├───┼────┤\n│ 1 │ #9 │\n└───┴────┘\nMerge them in order.";
        Assert.Equal(
        [
            new MessagePart("The PRs are open:", false),
            new MessagePart("┌───┬────┐\n│ # │ PR │\n├───┼────┤\n│ 1 │ #9 │\n└───┴────┘", true),
            new MessagePart("Merge them in order.", false),
        ], AgentThread.MessageParts(text));
        Assert.Equal([new MessagePart("│ is a bar", false)], AgentThread.MessageParts("│ is a bar"));
    }

    [Fact]
    public void TableGivesRowsOfCellsAndJoinsWrappedCells()
    {
        var table = string.Join("\n",
            "┌───┬──────┬────────────┐",
            "│ # │  PR  │ Fixes      │",
            "├───┼──────┼────────────┤",
            "│ 1 │ #593 │ Keyless    │",
            "│   │      │ REST reads │",
            "├───┼──────┼────────────┤",
            "│ 2 │ #601 │            │",
            "└───┴──────┴────────────┘");
        var rows = AgentThread.ParseTable(table)!;
        Assert.Equal(3, rows.Count);
        Assert.Equal(["#", "PR", "Fixes"], rows[0]);
        Assert.Equal(["1", "#593", "Keyless REST reads"], rows[1]);
        Assert.Equal(["2", "#601", ""], rows[2]);
        // Rows with other counts of cells.
        Assert.Null(AgentThread.ParseTable("│ a │ b │\n├───┤\n│ c │"));
    }

    [Fact]
    public void ChangeMarksOfEditResults()
    {
        Assert.Equal('-', AgentThread.ChangeMark("      42 -<<<<<<< HEAD"));
        Assert.Equal('+', AgentThread.ChangeMark("      43 +"));
        Assert.Equal('+', AgentThread.ChangeMark("+ export function total() {"));
        Assert.Equal('-', AgentThread.ChangeMark("    2 - export function total() {"));
        Assert.Null(AgentThread.ChangeMark("      40  Operational"));
        Assert.Null(AgentThread.ChangeMark("  context line"));
    }

    // opencode panels

    [Fact]
    public void OpencodeTitledPanelsAreTools()
    {
        string[] lines =
        [
            "┃",
            "┃  Clean up the middleware",
            "┃",
            "",
            "┃",
            "┃  # Todos",
            "┃",
            "┃  [✓] Read the middleware.",
            "┃  [•] Replace the body limit.",
            "┃",
            "",
            "┃",
            "┃  # Deleted api/body-limit.ts",
            "┃",
            "┃  -93 lines",
            "┃",
            "",
            "┃",
            "┃  # Created api/limit.ts",
            "┃",
            "┃                              1 + import { limit } from 'x';",
            "┃                              2 + export default limit;",
            "┃",
            "",
            "┃",
            "┃  # Running in /tmp/review",
            "┃",
            "┃  $ npx vitest run src/pages/MySpotsPage.test.tsx src/",
            "┃  pages/MapPage.tsx --",
            "┃  workers=2",
            "┃",
            "┃  ok",
            "┃  …",
            "┃",
            "┃  Click to expand",
            "┃",
            "",
            "   ▣  Build · Big Pickle · 21.2s",
        ];
        Assert.Equal(
        [
            new ThreadBlock.Prompt("Clean up the middleware"),
            ToolBlock("Todos", "1 of 2 done", "[✓] Read the middleware.", "[•] Replace the body limit."),
            new ThreadBlock.Changes(new ThreadChanges([new FileChange("api/body-limit.ts", 0, 93), new FileChange("api/limit.ts", 2, 0)])),
            ToolBlock("Bash", "npx vitest run src/pages/MySpotsPage.test.tsx src/pages/MapPage.tsx --workers=2", "ok", "…"),
        ], AgentThread.Parse(lines).Blocks);
    }

    [Fact]
    public void SplitDiffBecomesUnified()
    {
        string[] lines =
        [
            "    1   import { a } from                 1   import { a } from",
            "        'x';                                  'x';",
            "    2 - const b = 1;                     2 + const b = 2;",
            "                                         3 + const c = 3;",
            "    3   export { a }                     4   export { a }",
        ];
        Assert.Equal(["  import { a } from 'x';", "- const b = 1;", "+ const b = 2;", "+ const c = 3;", "  export { a }"], AgentThread.UnifySplitDiff(lines));
        // A unified diff of a narrow terminal stays as it is.
        Assert.Null(AgentThread.UnifySplitDiff(["    1   import { a }", "    2 - const b = 1;", "    2 + const b = 2;"]));
    }

    [Fact]
    public void OpencodeSplitEditCountsBothSides()
    {
        string[] lines =
        [
            "┃",
            "┃  ← Edit src/a.ts",
            "┃",
            "┃    1   import { a } from 'x';           1   import { a } from 'x';",
            "┃    2 - const b = 1;                     2 + const b = 2;",
            "┃                                         3 + const c = 3;",
            "┃",
            "",
            "   ▣  Build · Big Pickle · 2.1s",
        ];
        var blocks = AgentThread.Parse(lines).Blocks;
        Assert.Single(blocks);
        var edit = Tool(blocks[0])!;
        Assert.Equal(new FileChange("src/a.ts", 2, 1), edit.Change);
        Assert.Equal(["  import { a } from 'x';", "- const b = 1;", "+ const b = 2;", "+ const c = 3;"], edit.Result);
    }

    [Fact]
    public void OpencodeThoughtWithATitleAndCompactionDoNotShow()
    {
        string[] lines =
        [
            "   + Thought: Planning the commit · 1.8s",
            "   I will commit now.",
            "    Pushed to main.",
            "",
            "   ─────────────── Compaction ───────────────",
            "",
            "   ▣  Build · Big Pickle · 2.1s",
        ];
        Assert.Equal([new ThreadBlock.Message("I will commit now.\nPushed to main.")], AgentThread.Parse(lines).Blocks);
    }
}
