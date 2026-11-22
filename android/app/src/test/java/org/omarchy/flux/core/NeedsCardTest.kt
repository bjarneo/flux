package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NeedsCardTest {
    private class Io : DialogIo {
        var requests = 0L
        override fun screenOpen(deviceId: String, pane: String) = false
        override fun screenReading(deviceId: String, pane: String) = false
        override fun readScreen(deviceId: String, pane: String) = true
        override fun send(deviceId: String, pane: String, register: (Long) -> Unit): Boolean {
            register(++requests)
            return true
        }

        override fun now() = 1_000L
        override fun later(ms: Long, task: () -> Unit) = Unit
        override fun post(task: () -> Unit) = task()
    }

    private val three = "Bash command\n\n   bin/migrate --apply\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, always\n   3. No\n"
    private val four = "Bash command\n\n   bin/migrate --apply\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, always\n   3. No\n   4. Ask later\n"
    private val changed = "Bash command\n\n   bin/migrate --rollback\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"
    private val free = "I can migrate one.\n\n Which database should I migrate: staging or production?\n"

    private fun out(text: String, request: Long? = null) = HerdrOutput("w2:p1", loading = false, lines = termLines(text), request = request)

    private fun row(control: Boolean = true, reachable: Boolean = true, project: String = "billing") =
        AgentRow("d", "omarchy-xps", HerdrAgent("w2:p1", "codex", AgentStatus.Blocked, "Run the migration", project), control, 0, reachable)

    private fun dialog(text: String) = parseDialog(out(text), 1)!!

    @Test
    fun titleNamesTheAgentAndTheProject() {
        assertEquals("codex in billing needs input", needsCard(row(), dialog(three)).title)
        assertEquals("codex needs input", needsCard(row(project = ""), dialog(three)).title)
    }

    @Test
    fun threeChoicesGiveThreeKeys() {
        val c = needsCard(row(), dialog(three))
        assertEquals("Do you want to proceed?", c.question)
        assertEquals(listOf("1", "2", "3"), c.keys.map { it.key })
        assertFalse(c.dim)
    }

    @Test
    fun fourChoicesGiveNoKeys() {
        val c = needsCard(row(), dialog(four))
        assertTrue(c.keys.isEmpty())
        assertEquals("Do you want to proceed?", c.question)
    }

    @Test
    fun noChoicesGiveNoKeysAndTheQuestion() {
        val c = needsCard(row(), dialog(free))
        assertTrue(c.keys.isEmpty())
        assertEquals("Which database should I migrate: staging or production?", c.question)
    }

    @Test
    fun controlOffGivesNoKeys() {
        val c = needsCard(row(control = false), dialog(three))
        assertTrue(c.keys.isEmpty())
        assertEquals("Do you want to proceed?", c.question)
    }

    @Test
    fun noDialogShowsTheTitleOfTheAgentAndNoKeys() {
        val c = needsCard(row(), null)
        assertEquals("Run the migration", c.question)
        assertTrue(c.keys.isEmpty())
    }

    @Test
    fun anUnreachableComputerDimsTheKeys() {
        val c = needsCard(row(reachable = false), dialog(three))
        assertTrue(c.dim)
        assertEquals(3, c.keys.size)
    }

    private class Sent {
        val keys = ArrayList<List<String>>()
        var opened = 0
        var openedWith: AgentDialog? = null
    }

    private fun tap(book: DialogBook, sent: Sent, key: String, id: String, ready: Boolean = true) =
        answerNeedsKey(
            key, id, ready = { ready },
            verify = { i, same, changed -> book.verify("d", "w2:p1", i, onSame = same, onChanged = changed) },
            send = { sent.keys += it },
            open = { sent.opened++; sent.openedWith = it },
        )

    @Test
    fun aKeySendsTheChoiceWhenTheDialogIsTheSame() {
        val book = DialogBook(Io())
        val sent = Sent()
        tap(book, sent, "2", dialog(three).id)
        assertTrue("it reads before it sends", sent.keys.isEmpty())
        book.onOutput("d", out(three, request = 1))
        assertEquals(listOf(listOf("2")), sent.keys)
        assertEquals(0, sent.opened)
    }

    @Test
    fun aKeySendsNothingWhenTheOutputChanged() {
        val book = DialogBook(Io())
        val sent = Sent()
        tap(book, sent, "2", dialog(three).id)
        book.onOutput("d", out(changed, request = 1))
        assertTrue(sent.keys.isEmpty())
        assertEquals(1, sent.opened)
        assertEquals(listOf("Yes", "No"), sent.openedWith?.choices?.map { it.label })
    }

    @Test
    fun aKeySendsNothingWhenTheAgentIsNotReady() {
        val book = DialogBook(Io())
        val sent = Sent()
        tap(book, sent, "1", dialog(three).id, ready = false)
        assertTrue(sent.keys.isEmpty())
        assertEquals(1, sent.opened)
        assertNull(sent.openedWith)
    }

    @Test
    fun aMenuChoiceSendsTheArrowsOfTheNewRead() {
        val menu = "Which database?\n ❯ 1. Staging\n   2. Production\n"
        val book = DialogBook(Io())
        val sent = Sent()
        val d = dialog(menu)
        assertNotNull(d.id)
        tap(book, sent, "2", d.id)
        book.onOutput("d", out(menu, request = 1))
        assertEquals(1, sent.keys.size)
        assertEquals(d.choices.first { it.key == "2" }.keys, sent.keys[0])
    }

    @Test
    fun emptyLineNamesTheComputer() {
        val one = AgentRow("d", "omarchy-xps", HerdrAgent("w1:p1", "claude", AgentStatus.Working, "x", "api"), true, 0)
        assertEquals("1 agent works on omarchy-xps.", needsEmptyLine(listOf(one)))
        assertEquals("2 agents work on omarchy-xps.", needsEmptyLine(listOf(one, one.copy(agent = one.agent.copy(pane = "w1:p2")))))
        assertEquals("3 agents work on 2 computers.", needsEmptyLine(listOf(one, one, one.copy(computer = "desk"))))
        assertEquals("No agent works now.", needsEmptyLine(emptyList()))
    }

    @Test
    fun wakeShowsOnlyForAnUnreachableComputerThatCanWake() {
        fun d(online: Boolean, canWake: Boolean, paired: Boolean = true) = DeviceUi(
            id = "d", name = "desk", type = "desktop", ip = "", paired = paired, online = online,
            pairState = PairState.Paired, pairKey = "", pairOutgoing = false,
            battery = null, charging = false, players = emptyList(), player = null,
            commands = emptyList(), commandsLoaded = false, canWake = canWake,
        )
        assertTrue(showsWake(d(online = false, canWake = true)))
        assertFalse(showsWake(d(online = true, canWake = true)))
        assertFalse(showsWake(d(online = false, canWake = false)))
    }
}
