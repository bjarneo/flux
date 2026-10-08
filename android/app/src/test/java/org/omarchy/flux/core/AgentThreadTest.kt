package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentThreadTest {
    /** The sample output of the demo computer: an approval dialog of Claude Code, with terminal colors. */
    private val demo =
        "\u001b[38;2;215;119;87m●\u001b[0m I added the migration in \u001b[1mdb/migrate/0042_add_invoice_status.sql\u001b[0m.\n\n" +
            "\u001b[38;5;2m●\u001b[0m \u001b[1mBash\u001b[0m(bin/migrate --dry-run)\n" +
            "  \u001b[38;5;8m⎿\u001b[0m  1 migration to apply: \u001b[38;5;6m0042_add_invoice_status\u001b[0m\n\n" +
            "\u001b[38;5;4m" + "─".repeat(72) + "\u001b[0m\n" +
            " \u001b[1;38;5;4mBash command\u001b[0m\n\n" +
            "   bin/migrate --apply\n" +
            "   \u001b[38;5;8mApply the pending migration\u001b[0m\n\n" +
            " Do you want to proceed?\n" +
            " \u001b[38;5;4m❯ 1. Yes\u001b[0m\n" +
            "   2. Yes, and do not ask again for bin/migrate commands\n" +
            "   3. No, and tell Codex what to do differently \u001b[38;5;8m(esc)\u001b[0m\n"

    private fun text(ansi: String): List<String> = termLines(ansi).map { it.text }

    @Test
    fun demoGivesTheMessageAndTheToolAndNoDialog() {
        val t = agentThread(text(demo))
        assertEquals(
            listOf(
                ThreadBlock.Message("I added the migration in db/migrate/0042_add_invoice_status.sql."),
                ThreadBlock.Tool("Bash", "bin/migrate --dry-run", listOf("1 migration to apply: 0042_add_invoice_status")),
            ),
            t.blocks,
        )
        assertEquals("", t.step)
        assertEquals("", t.worked)
    }

    @Test
    fun demoAskHasTheQuestionAndTheCommand() {
        val ask = agentAsk(text(demo))!!
        assertEquals("Do you want to proceed?", ask.question)
        assertEquals(listOf("$ bin/migrate --apply", "Apply the pending migration"), ask.lines)
        assertTrue(ask.command)
    }

    @Test
    fun noChoicesGiveNoAsk() {
        assertNull(agentAsk(listOf("● Done.", "", "> ")))
        assertNull(dialogStart(listOf("● Done.")))
    }

    @Test
    fun twoEditsMergeIntoChanges() {
        val lines = listOf(
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
        )
        val blocks = agentThread(lines).blocks
        assertEquals(3, blocks.size)
        val c = blocks[1] as ThreadBlock.Changes
        assertEquals(listOf(FileChange("db/migrate/0042.sql", 18, 0), FileChange("app/models/invoice.rb", 24, 7)), c.files)
        assertEquals(42, c.added)
        assertEquals(7, c.removed)
        assertEquals("Bash", (blocks[2] as ThreadBlock.Tool).name)
    }

    @Test
    fun oneEditStaysATool() {
        val lines = listOf(
            "● Update(tests/login.spec.ts)",
            "  ⎿  Updated tests/login.spec.ts with 4 additions and 2 removals",
            "",
            "● Bash(npm test -- login)",
            "  ⎿  20 passed",
        )
        val blocks = agentThread(lines).blocks
        assertEquals(2, blocks.size)
        val edit = blocks[0] as ThreadBlock.Tool
        assertEquals("Update", edit.name)
        assertEquals(FileChange("tests/login.spec.ts", 4, 2), edit.change)
        assertNull((blocks[1] as ThreadBlock.Tool).change)
    }

    @Test
    fun workingScreenGivesTheStepAndDropsTheInput() {
        val lines = listOf(
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
        )
        val t = agentThread(lines)
        assertEquals("Running tests", t.step)
        assertEquals("2:14", t.elapsed)
        assertEquals(
            listOf(
                ThreadBlock.Message("I'll add a token bucket."),
                ThreadBlock.Tool("Bash", "npm test -- upload", listOf("Running 48 tests…", "31 passed")),
            ),
            t.blocks,
        )
    }

    @Test
    fun codexWorkingLineGivesTheTime() {
        val t = agentThread(listOf("• I will run it.", "", "• Working (12s • esc to interrupt)", "", "› Ask Codex to do anything"))
        assertEquals("Working", t.step)
        assertEquals("12s", t.elapsed)
        assertEquals(listOf(ThreadBlock.Message("I will run it.")), t.blocks)
    }

    @Test
    fun ruledInputAndHintsGo() {
        val lines = listOf(
            "● All tests pass.",
            "",
            "────────────────────",
            "> ",
            "────────────────────",
            "  ⏵⏵ accept edits on (shift+tab to cycle)",
        )
        assertEquals(listOf(ThreadBlock.Message("All tests pass.")), agentThread(lines).blocks)
    }

    @Test
    fun resultHintIsNotAFooter() {
        val lines = listOf(
            "● Read(src/a.ts)",
            "  ⎿  line 1",
            "     … +12 lines (ctrl+r to expand)",
        )
        val tool = agentThread(lines).blocks.single() as ThreadBlock.Tool
        assertEquals(listOf("line 1", "… +12 lines (ctrl+r to expand)"), tool.result)
    }

    @Test
    fun doneLineGivesTheTime() {
        val lines = listOf("● The test passed 20 times.", "", "✻ Worked for 6m 12s", "", "> ", "  ? for shortcuts")
        val t = agentThread(lines)
        assertEquals("6m 12s", t.worked)
        assertEquals(listOf(ThreadBlock.Message("The test passed 20 times.")), t.blocks)
    }

    @Test
    fun codexDoneRuleGivesTheTime() {
        val t = agentThread(listOf("• Done.", "", "─ Worked for 1m 03s ──────────"))
        assertEquals("1m 03s", t.worked)
        assertEquals(listOf(ThreadBlock.Message("Done.")), t.blocks)
    }

    @Test
    fun promptsAndParagraphs() {
        val lines = listOf(
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
        )
        val blocks = agentThread(lines).blocks
        assertEquals(ThreadBlock.Prompt("Fix the login test"), blocks[0])
        assertEquals(
            ThreadBlock.Message("The test waited on a fixed timeout.\nIt now waits for the cookie.\n\nThe run passed 20 times."),
            blocks[1],
        )
        assertEquals(3, blocks.size)
    }

    @Test
    fun codexToolsAndMessages() {
        val lines = listOf(
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
        )
        val blocks = agentThread(lines).blocks
        assertEquals(ThreadBlock.Prompt("Run the migration"), blocks[0])
        assertEquals(ThreadBlock.Message("I will run it."), blocks[1])
        assertEquals(ThreadBlock.Tool("Ran", "bin/migrate --dry-run", listOf("1 migration to apply")), blocks[2])
        val edit = blocks[3] as ThreadBlock.Tool
        assertEquals("Edited", edit.name)
        assertEquals("src/a.ts", edit.args)
        assertEquals(FileChange("src/a.ts", 3, 1), edit.change)
        assertEquals(4, blocks.size)
    }

    @Test
    fun codexAddedAsAMessageIsNotATool() {
        val blocks = agentThread(listOf("• Added a token bucket in front of the handler.")).blocks
        assertEquals(listOf(ThreadBlock.Message("Added a token bucket in front of the handler.")), blocks)
    }

    @Test
    fun codexApprovalWithoutARule() {
        val lines = listOf(
            "• I will apply the migration now.",
            "",
            "  Would you like to run the following command?",
            "",
            "  $ bin/migrate --apply",
            "",
            "› 1. Yes, proceed (y)",
            "  2. Yes, and don't ask again for this command (a)",
            "  3. No, and tell Codex what to do differently (esc)",
        )
        val ask = agentAsk(lines)!!
        assertEquals("Would you like to run the following command?", ask.question)
        assertEquals(listOf("$ bin/migrate --apply"), ask.lines)
        assertTrue(ask.command)
        assertEquals(listOf(ThreadBlock.Message("I will apply the migration now.")), agentThread(lines).blocks)
    }

    @Test
    fun askKeepsTheLinesNearestTheChoices() {
        val lines = listOf(
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
        )
        val ask = agentAsk(lines, maxLines = 3)!!
        assertEquals("Do you want to make this edit?", ask.question)
        assertEquals(listOf("line 3", "line 4", "line 5"), ask.lines)
        assertFalse(ask.command)
    }

    @Test
    fun unknownLinesAreRaw() {
        val lines = listOf(
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
        )
        val blocks = agentThread(lines).blocks
        assertEquals(
            listOf(
                ThreadBlock.Raw(1, 4),
                ThreadBlock.Message("Hello."),
                ThreadBlock.Raw(7, 10),
                ThreadBlock.Message("Bye."),
            ),
            blocks,
        )
    }

    @Test
    fun failedEditIsNotMerged() {
        val lines = listOf(
            "● Update(a.ts)",
            "  ⎿  Error: file not found",
            "",
            "● Update(b.ts)",
            "  ⎿  Updated b.ts with 1 addition",
        )
        val blocks = agentThread(lines).blocks
        assertEquals(2, blocks.size)
        assertTrue((blocks[0] as ThreadBlock.Tool).failed)
        assertEquals(FileChange("b.ts", 1, 0), (blocks[1] as ThreadBlock.Tool).change)
    }

    @Test
    fun diffGivesFilesAndCounts() {
        val lines = listOf(
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
        )
        val files = parseDiff(lines)
        assertEquals(2, files.size)
        val x = files[0]
        assertEquals("app/x.rb", x.path)
        assertEquals(2, x.added)
        assertEquals(1, x.removed)
        assertEquals(
            listOf(DiffLineKind.Hunk, DiffLineKind.Context, DiffLineKind.Removed, DiffLineKind.Added, DiffLineKind.Added),
            x.lines.map { it.kind },
        )
        val n = files[1]
        assertEquals("n.txt", n.path)
        assertEquals(1, n.added)
        assertEquals(0, n.removed)
        assertEquals(listOf(DiffLine("+line1", DiffLineKind.Added)), n.lines)
    }

    @Test
    fun noChangesGiveNoFiles() {
        assertEquals(emptyList<DiffFile>(), parseDiff(listOf("No changes in this repository.")))
    }
}
