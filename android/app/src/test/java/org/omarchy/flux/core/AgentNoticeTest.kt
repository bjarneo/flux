package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentNoticeTest {
    private val blocked = HerdrAgent("w2:p1", "codex", AgentStatus.Blocked, "Run the database migration", "billing", "billing")

    private fun choice(n: Int, label: String) = AgentChoice(n.toString(), label)

    private fun dialog(vararg labels: String, question: String = "Do you want to proceed?", lines: List<String> = listOf("$ bin/migrate --apply")) =
        AgentDialog(question, lines, labels.mapIndexed { i, l -> choice(i + 1, l) }, true, dialogId(question, lines, labels.toList()), 0)

    @Test
    fun twoChoicesGiveChoiceActions() {
        val n = agentNotice(blocked, dialog("Yes", "No"), control = true, sdk = 34)
        assertEquals(listOf("Yes", "No"), n.actions.map { it.label })
        assertEquals(listOf("1", "2"), n.actions.map { it.key })
        assertTrue(n.actions.all { it.kind == NoticeKind.Choice })
        assertEquals("codex in billing needs input", n.title)
    }

    @Test
    fun threeChoicesGiveChoiceActionsAndNoReply() {
        val n = agentNotice(blocked, dialog("Yes", "Yes, and do not ask again", "No"), control = true, sdk = 36)
        assertEquals(3, n.actions.size)
        assertTrue(n.actions.none { it.kind == NoticeKind.Reply })
        assertTrue("the text has the command and the question", n.text.contains("bin/migrate --apply") && n.text.endsWith("Do you want to proceed?"))
    }

    @Test
    fun fourChoicesGiveNoAction() {
        val n = agentNotice(blocked, dialog("Yes", "Always", "No", "Tell it what to do"), control = true, sdk = 34)
        assertTrue(n.actions.isEmpty())
        assertTrue("the expanded text lists the 4 choices in full", n.bigText.contains("4. Tell it what to do"))
    }

    @Test
    fun noChoicesGiveReply() {
        val n = agentNotice(blocked, dialog(question = "Which database should I migrate?", lines = emptyList()), control = true, sdk = 34)
        assertEquals(listOf(NoticeAction(NoticeKind.Reply, "Reply", "")), n.actions)
        assertEquals("codex in billing asks a question", n.title)
        assertEquals("Which database should I migrate?", n.text)
    }

    @Test
    fun controlOffGivesNoActionAndReadOnly() {
        val n = agentNotice(blocked, dialog("Yes", "No"), control = false, sdk = 34)
        assertTrue(n.actions.isEmpty())
        assertTrue(n.text.endsWith(" Read only"))
        assertTrue(n.bigText.endsWith("\nRead only"))
        val free = agentNotice(blocked, dialog(question = "Which one?", lines = emptyList()), control = false, sdk = 34)
        assertTrue("Reply is an action too", free.actions.isEmpty())
    }

    @Test
    fun controlOnHasNoReadOnlyText() {
        assertTrue(!agentNotice(blocked, dialog("Yes", "No"), control = true, sdk = 34).text.contains("Read only"))
    }

    @Test
    fun finishedAgentGivesNoAction() {
        val n = agentNotice(blocked.copy(status = AgentStatus.Done), dialog("Yes", "No"), control = true, sdk = 34)
        assertTrue(n.actions.isEmpty())
        assertEquals("codex in billing finished", n.title)
        assertEquals("Run the database migration", n.text)
    }

    @Test
    fun androidTenAndElevenOpenTheThread() {
        for (sdk in listOf(29, 30)) {
            val choices = agentNotice(blocked, dialog("Yes", "No"), control = true, sdk = sdk)
            assertTrue(choices.actions.all { it.kind == NoticeKind.Open })
            assertEquals(listOf("Yes", "No"), choices.actions.map { it.label })
            val reply = agentNotice(blocked, dialog(question = "Which one?", lines = emptyList()), control = true, sdk = sdk)
            assertEquals(listOf(NoticeAction(NoticeKind.Open, "Reply", "")), reply.actions)
        }
        assertTrue(agentNotice(blocked, dialog("Yes", "No"), control = true, sdk = 31).actions.all { it.kind == NoticeKind.Choice })
    }

    @Test
    fun missingDialogGivesNoActionAndTheTitleOfTheAgent() {
        val n = agentNotice(blocked, null, control = true, sdk = 34)
        assertTrue(n.actions.isEmpty())
        assertEquals("Run the database migration", n.text)
        assertEquals("codex in billing needs input", n.title)
    }

    @Test
    fun longLabelIsCutAtAWordEnd() {
        assertEquals("Yes, and do not ask…", cutLabel("Yes, and do not ask again for bin/migrate commands"))
        assertEquals("No", cutLabel("No"))
        assertEquals("exactly twenty-four ch", cutLabel("exactly twenty-four ch"))
        assertEquals("a".repeat(24) + "…", cutLabel("a".repeat(40)))
        assertEquals("one two three four five…", cutLabel("one two three four five six"))
        val n = agentNotice(blocked, dialog("Yes", "Yes, and do not ask again for bin/migrate commands", "No"), control = true, sdk = 34)
        assertEquals("Yes, and do not ask…", n.actions[1].label)
        assertTrue("the expanded text keeps the full label", n.bigText.contains("2. Yes, and do not ask again for bin/migrate commands"))
    }

    @Test
    fun noticeCarriesTheIdOfItsDialog() {
        val d = dialog("Yes", "No")
        assertEquals(d.id, agentNotice(blocked, d, control = true, sdk = 34).dialogId)
        assertEquals("", agentNotice(blocked, null, control = true, sdk = 34).dialogId)
    }

    @Test
    fun replySendsOnlyForTheDialogOfTheNotice() {
        val a = dialog(question = "Which name?", lines = listOf("Name the file."))
        val b = dialog(question = "Which folder?", lines = listOf("Name the folder."))
        assertTrue(replyMatches(a, a.id))
        assertTrue(!replyMatches(b, a.id))
        assertTrue(!replyMatches(null, a.id))
        assertTrue(!replyMatches(a, ""))
        val withChoices = dialog("Yes", "No")
        assertTrue(!replyMatches(withChoices, withChoices.id))
    }
}
