import XCTest
@testable import FluxKit

/// The thread of an agent: messages, tool calls, changes, prompts, the
/// question of a dialog, and the review diff. The same cases as
/// AgentThreadTest.kt of the Android app.
final class AgentThreadTests: XCTestCase {
    /// The sample output of the demo computer: an approval dialog of Claude Code, with terminal colors.
    private let demo =
        "\u{1B}[38;2;215;119;87m●\u{1B}[0m I added the migration in \u{1B}[1mdb/migrate/0042_add_invoice_status.sql\u{1B}[0m.\n\n" +
        "\u{1B}[38;5;2m●\u{1B}[0m \u{1B}[1mBash\u{1B}[0m(bin/migrate --dry-run)\n" +
        "  \u{1B}[38;5;8m⎿\u{1B}[0m  1 migration to apply: \u{1B}[38;5;6m0042_add_invoice_status\u{1B}[0m\n\n" +
        "\u{1B}[38;5;4m" + String(repeating: "─", count: 72) + "\u{1B}[0m\n" +
        " \u{1B}[1;38;5;4mBash command\u{1B}[0m\n\n" +
        "   bin/migrate --apply\n" +
        "   \u{1B}[38;5;8mApply the pending migration\u{1B}[0m\n\n" +
        " Do you want to proceed?\n" +
        " \u{1B}[38;5;4m❯ 1. Yes\u{1B}[0m\n" +
        "   2. Yes, and do not ask again for bin/migrate commands\n" +
        "   3. No, and tell Codex what to do differently \u{1B}[38;5;8m(esc)\u{1B}[0m\n"

    private func text(_ ansi: String) -> [String] { TermText.lines(ansi).map(\.text) }

    private func tool(_ b: ThreadBlock) -> ThreadTool? {
        if case let .tool(t) = b { return t }
        return nil
    }

    func testDemoGivesTheMessageAndTheToolAndNoDialog() {
        let t = AgentThread.parse(text(demo))
        XCTAssertEqual(t.blocks, [
            .message("I added the migration in db/migrate/0042_add_invoice_status.sql."),
            .tool(ThreadTool("Bash", "bin/migrate --dry-run", ["1 migration to apply: 0042_add_invoice_status"])),
        ])
        XCTAssertEqual(t.step, "")
        XCTAssertEqual(t.worked, "")
    }

    func testDemoAskHasTheQuestionAndTheCommand() throws {
        let ask = try XCTUnwrap(AgentAsk.find(text(demo)))
        XCTAssertEqual(ask.question, "Do you want to proceed?")
        XCTAssertEqual(ask.lines, ["$ bin/migrate --apply", "Apply the pending migration"])
        XCTAssertTrue(ask.command)
    }

    func testNoChoicesGiveNoAsk() {
        XCTAssertNil(AgentAsk.find(["● Done.", "", "> "]))
        XCTAssertNil(AgentAsk.dialogStart(["● Done."]))
    }

    func testTwoEditsMergeIntoChanges() {
        let lines = [
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
        ]
        let blocks = AgentThread.parse(lines).blocks
        XCTAssertEqual(blocks.count, 3)
        guard case let .changes(c) = blocks[1] else { return XCTFail("no changes block") }
        XCTAssertEqual(c.files, [FileChange("db/migrate/0042.sql", 18, 0), FileChange("app/models/invoice.rb", 24, 7)])
        XCTAssertEqual(c.added, 42)
        XCTAssertEqual(c.removed, 7)
        XCTAssertEqual(tool(blocks[2])?.name, "Bash")
    }

    func testOneEditStaysATool() {
        let lines = [
            "● Update(tests/login.spec.ts)",
            "  ⎿  Updated tests/login.spec.ts with 4 additions and 2 removals",
            "",
            "● Bash(npm test -- login)",
            "  ⎿  20 passed",
        ]
        let blocks = AgentThread.parse(lines).blocks
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(tool(blocks[0])?.name, "Update")
        XCTAssertEqual(tool(blocks[0])?.change, FileChange("tests/login.spec.ts", 4, 2))
        XCTAssertNil(tool(blocks[1])?.change)
    }

    func testWorkingScreenGivesTheStepAndDropsTheInput() {
        let lines = [
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
        ]
        let t = AgentThread.parse(lines)
        XCTAssertEqual(t.step, "Running tests")
        XCTAssertEqual(t.elapsed, "2:14")
        XCTAssertEqual(t.blocks, [
            .message("I'll add a token bucket."),
            .tool(ThreadTool("Bash", "npm test -- upload", ["Running 48 tests…", "31 passed"])),
        ])
    }

    func testANumberedListAtTheEndStaysInTheThread() {
        let rule = String(repeating: "─", count: 40)
        let lines = [
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
        ]
        XCTAssertNil(AgentAsk.dialogStart(lines))
        let t = AgentThread.parse(lines)
        XCTAssertEqual(t.worked, "24s")
        guard t.blocks.count == 1, case .message(let text) = t.blocks[0] else { return XCTFail("\(t.blocks)") }
        XCTAssertTrue(text.hasPrefix("Here is what I would add."), text)
        XCTAssertTrue(text.contains("3. Show the full command."), text)
        XCTAssertTrue(text.hasSuffix("I would start with 1 and 2."), text)
    }

    func testCodexWorkingLineGivesTheTime() {
        let t = AgentThread.parse(["• I will run it.", "", "• Working (12s • esc to interrupt)", "", "› Ask Codex to do anything"])
        XCTAssertEqual(t.step, "Working")
        XCTAssertEqual(t.elapsed, "12s")
        XCTAssertEqual(t.blocks, [.message("I will run it.")])
    }

    func testRuledInputAndHintsGo() {
        let lines = [
            "● All tests pass.",
            "",
            "────────────────────",
            "> ",
            "────────────────────",
            "  ⏵⏵ accept edits on (shift+tab to cycle)",
        ]
        XCTAssertEqual(AgentThread.parse(lines).blocks, [.message("All tests pass.")])
    }

    func testResultHintIsNotAFooter() {
        let lines = [
            "● Read(src/a.ts)",
            "  ⎿  line 1",
            "     … +12 lines (ctrl+r to expand)",
        ]
        let blocks = AgentThread.parse(lines).blocks
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(tool(blocks[0])?.result, ["line 1", "… +12 lines (ctrl+r to expand)"])
    }

    func testDoneLineGivesTheTime() {
        let t = AgentThread.parse(["● The test passed 20 times.", "", "✻ Worked for 6m 12s", "", "> ", "  ? for shortcuts"])
        XCTAssertEqual(t.worked, "6m 12s")
        XCTAssertEqual(t.blocks, [.message("The test passed 20 times.")])
    }

    func testCodexDoneRuleGivesTheTime() {
        let t = AgentThread.parse(["• Done.", "", "─ Worked for 1m 03s ──────────"])
        XCTAssertEqual(t.worked, "1m 03s")
        XCTAssertEqual(t.blocks, [.message("Done.")])
    }

    func testPromptsAndParagraphs() {
        let lines = [
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
        ]
        let blocks = AgentThread.parse(lines).blocks
        XCTAssertEqual(blocks.first, .prompt("Fix the login test"))
        XCTAssertEqual(blocks[1], .message("The test waited on a fixed timeout.\nIt now waits for the cookie.\n\nThe run passed 20 times."))
        XCTAssertEqual(blocks.count, 3)
    }

    func testCodexToolsAndMessages() {
        let lines = [
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
        ]
        let blocks = AgentThread.parse(lines).blocks
        XCTAssertEqual(blocks[0], .prompt("Run the migration"))
        XCTAssertEqual(blocks[1], .message("I will run it."))
        XCTAssertEqual(blocks[2], .tool(ThreadTool("Ran", "bin/migrate --dry-run", ["1 migration to apply"])))
        XCTAssertEqual(tool(blocks[3])?.name, "Edited")
        XCTAssertEqual(tool(blocks[3])?.args, "src/a.ts")
        XCTAssertEqual(tool(blocks[3])?.change, FileChange("src/a.ts", 3, 1))
        XCTAssertEqual(blocks.count, 4)
    }

    func testCodexAddedAsAMessageIsNotATool() {
        let blocks = AgentThread.parse(["• Added a token bucket in front of the handler."]).blocks
        XCTAssertEqual(blocks, [.message("Added a token bucket in front of the handler.")])
    }

    func testCodexApprovalWithoutARule() throws {
        let lines = [
            "• I will apply the migration now.",
            "",
            "  Would you like to run the following command?",
            "",
            "  $ bin/migrate --apply",
            "",
            "› 1. Yes, proceed (y)",
            "  2. Yes, and don't ask again for this command (a)",
            "  3. No, and tell Codex what to do differently (esc)",
        ]
        let ask = try XCTUnwrap(AgentAsk.find(lines))
        XCTAssertEqual(ask.question, "Would you like to run the following command?")
        XCTAssertEqual(ask.lines, ["$ bin/migrate --apply"])
        XCTAssertTrue(ask.command)
        XCTAssertEqual(AgentThread.parse(lines).blocks, [.message("I will apply the migration now.")])
    }

    func testAskKeepsTheLinesNearestTheChoices() throws {
        let lines = [
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
        ]
        let ask = try XCTUnwrap(AgentAsk.find(lines, maxLines: 3))
        XCTAssertEqual(ask.question, "Do you want to make this edit?")
        XCTAssertEqual(ask.lines, ["line 3", "line 4", "line 5"])
        XCTAssertFalse(ask.command)
    }

    func testUnknownLinesAreRaw() {
        let lines = [
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
        ]
        XCTAssertEqual(AgentThread.parse(lines).blocks, [
            .raw(from: 1, to: 4),
            .message("Hello."),
            .raw(from: 7, to: 10),
            .message("Bye."),
        ])
    }

    func testFailedEditIsNotMerged() {
        let lines = [
            "● Update(a.ts)",
            "  ⎿  Error: file not found",
            "",
            "● Update(b.ts)",
            "  ⎿  Updated b.ts with 1 addition",
        ]
        let blocks = AgentThread.parse(lines).blocks
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(tool(blocks[0])?.failed, true)
        XCTAssertEqual(tool(blocks[1])?.change, FileChange("b.ts", 1, 0))
    }

    func testDiffGivesFilesAndCounts() {
        let lines = [
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
        ]
        let files = DiffFile.parse(lines)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].path, "app/x.rb")
        XCTAssertEqual(files[0].added, 2)
        XCTAssertEqual(files[0].removed, 1)
        XCTAssertEqual(files[0].lines.map(\.kind), [.hunk, .context, .removed, .added, .added])
        XCTAssertEqual(files[1].path, "n.txt")
        XCTAssertEqual(files[1].added, 1)
        XCTAssertEqual(files[1].removed, 0)
        XCTAssertEqual(files[1].lines, [DiffLine("+line1", .added)])
    }

    func testNoChangesGiveNoFiles() {
        XCTAssertEqual(DiffFile.parse(["No changes in this repository."]), [])
    }

    // MARK: opencode

    /// A finished turn of opencode after the tidy step: a prompt, 2 edits, a shell command, a message, and the input box.
    private let opencodeDone = [
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
    ]

    func testOpencodeTurnGivesPromptToolsChangesAndTime() {
        let t = AgentThread.parse(opencodeDone)
        XCTAssertEqual(t.blocks, [
            .prompt("Add a tax rate to total, then run the test."),
            .tool(ThreadTool("Read", "invoice.js", [])),
            .changes(ThreadChanges([FileChange("invoice.js", 2, 2), FileChange("invoice.test.js", 1, 0)])),
            .tool(ThreadTool("Bash", "node invoice.test.js", ["ok"])),
            .message("Done. The total takes a tax rate:\n  total(lines, 0.25)"),
        ])
        XCTAssertEqual(t.worked, "21.2s")
        XCTAssertEqual(t.step, "")
        XCTAssertNil(AgentAsk.find(opencodeDone), "no dialog")
    }

    func testOpencodeWorkingHasAStepAndNoTime() throws {
        let lines = [
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
        ]
        let t = AgentThread.parse(lines)
        XCTAssertEqual(t.step, "Working")
        XCTAssertEqual(t.worked, "")
        XCTAssertEqual(t.blocks.count, 1)
        let edit = try XCTUnwrap(tool(t.blocks[0]))
        XCTAssertEqual(edit.name, "Edit")
        XCTAssertEqual(edit.change, FileChange("invoice.js", 1, 0))
    }

    func testOpencodeShellPermissionIsTheCommand() {
        let lines = [
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
        ]
        XCTAssertEqual(AgentAsk.find(lines), AgentAsk("Permission required", ["$ node invoice.test.js"], command: true))
        // The waiting command and the line of the turn belong to the dialog.
        XCTAssertTrue(AgentThread.parse(lines).blocks.isEmpty)
    }

    func testOpencodeEditPermissionIsTheFileAndTheDiff() {
        let lines = [
            "┃",
            "┃  △ Permission required",
            "┃    → Edit invoice.js",
            "┃",
            "┃  1   // Invoices of a small billing app.                                      █",
            "┃  2 - export function total(lines) {                                           █",
            "┃  2 + export function total(lines, taxRate = 0) {                              ▀",
            "┃",
            "┃   Allow once   Allow always   Reject  ctrl+f fullscreen  ⇆ select  enter confirm",
        ]
        XCTAssertEqual(
            AgentAsk.find(lines, maxLines: 3),
            AgentAsk("Permission required", ["Edit invoice.js", "1   // Invoices of a small billing app.", "2 - export function total(lines) {"])
        )
    }

    func testOpencodeMenuRowGivesChoicesWithArrowKeys() {
        let bar = "\u{1B}[38;2;240;198;116;48;2;43;46;49m┃\u{1B}[0m"
        let gray = "48;2;50;53;57"
        let accent = "48;2;240;198;116"
        let row = bar + "\u{1B}[\(gray)m  \u{1B}[\(accent)m \u{1B}[38;2;29;31;33;\(accent)mAllow once\u{1B}[\(accent)m \u{1B}[0m" +
            "\u{1B}[\(gray)m  \u{1B}[38;2;169;169;169;\(gray)mAllow always\u{1B}[\(gray)m   \u{1B}[38;2;169;169;169;\(gray)mReject" +
            "\u{1B}[\(gray)m  \u{1B}[38;2;197;200;198;\(gray)mctrl+f \u{1B}[38;2;169;169;169;\(gray)mfullscreen" +
            "\u{1B}[\(gray)m  \u{1B}[38;2;197;200;198;\(gray)m⇆ \u{1B}[38;2;169;169;169;\(gray)mselect\u{1B}[0m\n"
        XCTAssertEqual(AgentChoice.findMenu(TermText.lines(row)), [
            AgentChoice("1", "Allow once", selected: true, keys: ["enter"]),
            AgentChoice("2", "Allow always", selected: false, keys: ["right", "enter"]),
            AgentChoice("3", "Reject", selected: false, keys: ["right", "right", "enter"]),
        ])
        // After a move to Reject, the arrows wrap to the first choice.
        let moved = row.replacingOccurrences(of: "38;2;29;31;33;\(accent)mAllow once", with: "38;2;169;169;169;\(gray)mAllow once")
            .replacingOccurrences(of: "38;2;169;169;169;\(gray)mReject", with: "38;2;29;31;33;\(accent)mReject")
        let after = AgentChoice.findMenu(TermText.lines(moved))
        XCTAssertEqual(after.first?.keys, ["right", "enter"])
        XCTAssertEqual(after.last?.keys, ["enter"])
        // The choices of a numbered dialog go as their digit.
        XCTAssertEqual(AgentChoice.find(["❯ 1. Yes", "  2. No"]).first?.keys, ["1"])
        XCTAssertEqual(AgentChoice.find(["❯ 1. Yes", "  2. No"]).first?.sentMeta, "Sent key 1")
        XCTAssertEqual(after.first?.sentMeta, "Selected in the menu")
    }

    func testClaudeOutputIsNotOpencode() {
        XCTAssertFalse(AgentThread.isOpencode(text(demo)))
        XCTAssertTrue(AgentThread.isOpencode(opencodeDone))
    }

    /// A question of opencode with 4 choices and descriptions, after the tidy step.
    private let opencodeQuestion = [
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
    ]

    func testOpencodeQuestionGivesTheQuestionAndChoicesWithDescriptions() {
        XCTAssertTrue(AgentThread.isOpencode(opencodeQuestion))
        XCTAssertEqual(AgentAsk.find(opencodeQuestion), AgentAsk("What should I do with the pull request?", []))
        let choices = AgentChoice.find(opencodeQuestion)
        XCTAssertEqual(choices.count, 5)
        XCTAssertEqual(choices.first, AgentChoice("1", "A. Approve CI, merge if green", detail: "Approve the waiting runs. Merge only if both pass."))
        XCTAssertEqual(choices[3].keys, ["4"])
        XCTAssertEqual(choices.last?.detail, "")
        // The thought line, the tool call of the question, and the question itself are not in the thread.
        XCTAssertEqual(AgentThread.parse(opencodeQuestion).blocks, [
            .prompt("ask me a question I can answer a b c or d to"),
            .message("The next step is a merge decision."),
        ])
    }

    func testOpencodeAnsweredQuestionIsTheQuestionAndTheAnswer() {
        let lines = [
            "┃",
            "┃  # Questions",
            "┃",
            "┃  Which tax rate should total use?",
            "┃  C 0.25",
            "┃",
            "",
            "   ▣  Build · Big Pickle · 3.1s",
        ]
        XCTAssertEqual(AgentThread.parse(lines).blocks, [.message("Which tax rate should total use?"), .prompt("C 0.25")])
    }

    func testClaudeQuestionDropsTheHeaderAndKeepsDescriptions() {
        let lines = [
            "● I need a decision.",
            "",
            String(repeating: "─", count: 40),
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
        ]
        XCTAssertEqual(AgentAsk.find(lines), AgentAsk("Which tax rate should total use?", []))
        let choices = AgentChoice.find(lines)
        XCTAssertEqual(choices.map(\.detail), ["No tax", "A quarter", ""])
        XCTAssertEqual(choices.first?.selected, true)
    }

    // MARK: Claude Code 2.1

    /// An idle screen of Claude Code 2.1: the logo, prompts with ❯, tool summaries, and the ruled input with the name of the session.
    private let claude21 = [
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
    ]

    func testClaude21PromptsSummariesAndLongToolCalls() {
        let t = AgentThread.parse(claude21)
        XCTAssertEqual(t.blocks, [
            .prompt("Fix the login test"),
            .tool(ThreadTool("Read", "2 files, listed 1 directory, ran 3 shell commands", [])),
            .message("The test waited on a fixed timeout."),
            .tool(ThreadTool("Ran", "1 shell command", ["“Tell the reviewer” → sent to billing-2"])),
            .tool(ThreadTool("Bash", "cat > /tmp/fix.py <<'EOF' import sys", ["done"])),
            .tool(ThreadTool("Workflow", "Rebase the 3 PRs into one chain and run make check at each step", ["/workflows to view dynamic workflow runs"])),
            .prompt("Ship it"),
            .message("Shipped."),
        ])
        XCTAssertEqual(t.worked, "22s")
        XCTAssertEqual(t.step, "")
    }

    func testClaude21WorkingScreenGivesTheStepAndTheRunningCommand() {
        let lines = [
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
        ]
        let t = AgentThread.parse(lines)
        XCTAssertEqual(t.step, "Orbiting")
        XCTAssertEqual(t.elapsed, "1m 17s")
        XCTAssertEqual(t.blocks, [
            .message("I will capture the output."),
            .tool(ThreadTool("Bash", "Capture the output", ["$ mkdir -p /tmp/cap && cat >", "/tmp/cap/a.txt"])),
        ])
    }

    func testSummaryNeedsACountAndNoSentenceEnd() {
        let lines = ["● Done.", "", "  Waves 1 to 5 each passed.", "", "  Ran 20 tests and all passed."]
        XCTAssertEqual(AgentThread.parse(lines).blocks.count, 1)
    }

    func testALineAtTheLeftEdgeContinuesTheHead() {
        let lines = ["● Dynamic workflow \"Build the PRs\"", "completed · 7h 55m", "", "● Next."]
        XCTAssertEqual(AgentThread.parse(lines).blocks, [.message("Dynamic workflow \"Build the PRs\"\ncompleted · 7h 55m"), .message("Next.")])
    }

    func testMessageSplitsIntoTextAndTables() {
        let text = "The PRs are open:\n┌───┬────┐\n│ # │ PR │\n├───┼────┤\n│ 1 │ #9 │\n└───┴────┘\nMerge them in order."
        XCTAssertEqual(AgentThread.messageParts(text), [
            MessagePart("The PRs are open:", table: false),
            MessagePart("┌───┬────┐\n│ # │ PR │\n├───┼────┤\n│ 1 │ #9 │\n└───┴────┘", table: true),
            MessagePart("Merge them in order.", table: false),
        ])
        XCTAssertEqual(AgentThread.messageParts("│ is a bar"), [MessagePart("│ is a bar", table: false)])
    }

    func testTableGivesRowsOfCellsAndJoinsWrappedCells() {
        let table = [
            "┌───┬──────┬────────────┐",
            "│ # │  PR  │ Fixes      │",
            "├───┼──────┼────────────┤",
            "│ 1 │ #593 │ Keyless    │",
            "│   │      │ REST reads │",
            "├───┼──────┼────────────┤",
            "│ 2 │ #601 │            │",
            "└───┴──────┴────────────┘",
        ].joined(separator: "\n")
        XCTAssertEqual(AgentThread.parseTable(table), [["#", "PR", "Fixes"], ["1", "#593", "Keyless REST reads"], ["2", "#601", ""]])
        XCTAssertNil(AgentThread.parseTable("│ a │ b │\n├───┤\n│ c │"), "rows with other counts of cells")
    }

    func testChangeMarksOfEditResults() {
        XCTAssertEqual(AgentThread.changeMark("      42 -<<<<<<< HEAD"), "-")
        XCTAssertEqual(AgentThread.changeMark("      43 +"), "+")
        XCTAssertEqual(AgentThread.changeMark("+ export function total() {"), "+")
        XCTAssertEqual(AgentThread.changeMark("    2 - export function total() {"), "-")
        XCTAssertNil(AgentThread.changeMark("      40  Operational"))
        XCTAssertNil(AgentThread.changeMark("  context line"))
    }

    // MARK: opencode panels

    func testOpencodeTitledPanelsAreTools() {
        let lines = [
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
        ]
        XCTAssertEqual(AgentThread.parse(lines).blocks, [
            .prompt("Clean up the middleware"),
            .tool(ThreadTool("Todos", "1 of 2 done", ["[✓] Read the middleware.", "[•] Replace the body limit."])),
            .changes(ThreadChanges([FileChange("api/body-limit.ts", 0, 93), FileChange("api/limit.ts", 2, 0)])),
            .tool(ThreadTool("Bash", "npx vitest run src/pages/MySpotsPage.test.tsx src/pages/MapPage.tsx --workers=2", ["ok", "…"])),
        ])
    }

    func testSplitDiffBecomesUnified() {
        let lines = [
            "    1   import { a } from                 1   import { a } from",
            "        'x';                                  'x';",
            "    2 - const b = 1;                     2 + const b = 2;",
            "                                         3 + const c = 3;",
            "    3   export { a }                     4   export { a }",
        ]
        XCTAssertEqual(AgentThread.unifySplitDiff(lines), ["  import { a } from 'x';", "- const b = 1;", "+ const b = 2;", "+ const c = 3;", "  export { a }"])
        // A unified diff of a narrow terminal stays as it is.
        XCTAssertNil(AgentThread.unifySplitDiff(["    1   import { a }", "    2 - const b = 1;", "    2 + const b = 2;"]))
    }

    func testOpencodeSplitEditCountsBothSides() throws {
        let lines = [
            "┃",
            "┃  ← Edit src/a.ts",
            "┃",
            "┃    1   import { a } from 'x';           1   import { a } from 'x';",
            "┃    2 - const b = 1;                     2 + const b = 2;",
            "┃                                         3 + const c = 3;",
            "┃",
            "",
            "   ▣  Build · Big Pickle · 2.1s",
        ]
        let blocks = AgentThread.parse(lines).blocks
        XCTAssertEqual(blocks.count, 1)
        let edit = try XCTUnwrap(tool(blocks[0]))
        XCTAssertEqual(edit.change, FileChange("src/a.ts", 2, 1))
        XCTAssertEqual(edit.result, ["  import { a } from 'x';", "- const b = 1;", "+ const b = 2;", "+ const c = 3;"])
    }

    func testOpencodeThoughtWithATitleAndCompactionDoNotShow() {
        let lines = [
            "   + Thought: Planning the commit · 1.8s",
            "   I will commit now.",
            "    Pushed to main.",
            "",
            "   ─────────────── Compaction ───────────────",
            "",
            "   ▣  Build · Big Pickle · 2.1s",
        ]
        XCTAssertEqual(AgentThread.parse(lines).blocks, [.message("I will commit now.\nPushed to main.")])
    }
}
