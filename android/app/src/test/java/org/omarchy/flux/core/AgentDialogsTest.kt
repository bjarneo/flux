package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentDialogsTest {
    /** A fake app: it records the reads and runs the timers by hand. */
    private class Io : DialogIo {
        var open = false
        var reading = false
        var reachable = true
        var requests = 0L
        val sends = ArrayList<String>()
        val screenReads = ArrayList<String>()
        val timers = ArrayList<() -> Unit>()

        override fun screenOpen(deviceId: String, pane: String) = open
        override fun screenReading(deviceId: String, pane: String) = reading
        override fun readScreen(deviceId: String, pane: String): Boolean {
            screenReads += pane
            return reachable
        }

        override fun send(deviceId: String, pane: String, register: (Long) -> Unit): Boolean {
            val r = ++requests
            register(r)
            sends += pane
            return reachable
        }

        override fun now() = 1_000L
        override fun later(ms: Long, task: () -> Unit) {
            timers += task
        }

        override fun post(task: () -> Unit) = task()
    }

    private val three = "Bash command\n\n   bin/migrate --apply\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, always\n   3. No\n"
    private val changed = "Bash command\n\n   bin/migrate --rollback\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"

    private fun out(text: String, request: Long? = null, pane: String = "w2:p1") =
        HerdrOutput(pane, loading = false, lines = termLines(text), request = request)

    @Test
    fun parsesTheQuestionTheChoicesAndAnId() {
        val d = parseDialog(out(three), 5)!!
        assertEquals("Do you want to proceed?", d.question)
        assertEquals(listOf("Yes", "Yes, always", "No"), d.choices.map { it.label })
        assertEquals(16, d.id.length)
        assertEquals(d.id, parseDialog(out(three), 9)!!.id)
        assertNotEquals(d.id, parseDialog(out(changed), 9)!!.id)
        assertNull(parseDialog(out(three).copy(error = "x"), 1))
    }

    @Test
    fun aFreeTextQuestionHasNoChoices() {
        val d = parseDialog(out("I can migrate one.\n\n Which database should I migrate: staging or production?\n"), 1)!!
        assertTrue(d.choices.isEmpty())
        assertEquals("Which database should I migrate: staging or production?", d.question)
    }

    @Test
    fun readsEachPaneOnce() {
        val io = Io()
        val book = DialogBook(io)
        val got = ArrayList<AgentDialog?>()
        book.peek("d", "w2:p1") { got += it }
        book.peek("d", "w2:p1") { got += it }
        assertEquals("a second call joins the read", 1, io.sends.size)
        assertTrue(book.onOutput("d", out(three, request = 1)))
        assertEquals(2, got.size)
        assertNotNull(got[0])
        assertEquals(got[0], book.latest("d", "w2:p1"))
        book.peek("d", "w2:p2") { }
        assertEquals("another pane has its own read", 2, io.sends.size)
    }

    @Test
    fun anOpenScreenSharesItsRead() {
        val io = Io().apply { open = true; reading = true }
        val book = DialogBook(io)
        var got: AgentDialog? = null
        book.peek("d", "w2:p1") { got = it }
        assertTrue("no read of its own", io.sends.isEmpty() && io.screenReads.isEmpty())
        assertFalse("the screen keeps the output", book.onOutput("d", out(three, request = 7)))
        book.onScreenOutput("d", out(three, request = 7))
        assertEquals("Do you want to proceed?", got?.question)
    }

    @Test
    fun anOpenScreenWithNoReadAsksTheScreenToRead() {
        val io = Io().apply { open = true }
        DialogBook(io).peek("d", "w2:p1") { }
        assertEquals(listOf("w2:p1"), io.screenReads)
        assertTrue(io.sends.isEmpty())
    }

    @Test
    fun aPeekAnswerIsNotForTheScreen() {
        val io = Io()
        val book = DialogBook(io)
        book.peek("d", "w2:p1") { }
        assertTrue(book.onOutput("d", out(three, request = 1)))
        assertFalse("an output of another request goes to the screen", book.onOutput("d", out(three, request = 99)))
    }

    @Test
    fun sameIdSendsTheKeysOfTheNewRead() {
        val io = Io()
        val book = DialogBook(io)
        val id = parseDialog(out(three), 0)!!.id
        var same: AgentDialog? = null
        var other: AgentDialog? = null
        book.verify("d", "w2:p1", id, onSame = { same = it }, onChanged = { other = it })
        book.onOutput("d", out(three, request = 1))
        assertEquals(listOf("2"), same?.choices?.get(1)?.keys)
        assertNull(other)
    }

    @Test
    fun aChangedDialogSendsNothing() {
        val io = Io()
        val book = DialogBook(io)
        val id = parseDialog(out(three), 0)!!.id
        var same: AgentDialog? = null
        var other: AgentDialog? = null
        book.verify("d", "w2:p1", id, onSame = { same = it }, onChanged = { other = it })
        book.onOutput("d", out(changed, request = 1))
        assertNull(same)
        assertEquals(listOf("Yes", "No"), other?.choices?.map { it.label })
    }

    @Test
    fun aMenuChoiceGetsTheArrowsFromTheNewSelection() {
        // The selected choice is the one with the other background. The new read selects Allow always.
        fun menu(selected: Int): HerdrOutput {
            val bgs = listOf("44", "44", "44").toMutableList().also { it[selected] = "46" }
            val row = listOf("Allow once", "Allow always", "Reject").mapIndexed { i, t -> "\u001b[48;5;${bgs[i]}m $t \u001b[0m" }
                .joinToString("  ") + "   ⇆ select  enter confirm"
            return HerdrOutput("w2:p1", loading = false, lines = termLines("Permission required\n\n$row\n"), request = 1)
        }
        val first = parseDialog(menu(0), 0)!!
        val second = parseDialog(menu(1), 0)!!
        assertEquals(listOf("right", "enter"), first.choices[1].keys)
        assertEquals("the selection moved, so the keys differ", listOf("enter"), second.choices[1].keys)
    }

    @Test
    fun aTimeoutSendsNothing() {
        val io = Io()
        val book = DialogBook(io)
        val got = ArrayList<AgentDialog?>()
        book.verify("d", "w2:p1", "x", onSame = { got += it }, onChanged = { got += it })
        assertTrue(got.isEmpty())
        io.timers[0]()
        assertEquals(listOf<AgentDialog?>(null), got)
        // A late answer finds no waiting read.
        assertFalse(book.onOutput("d", out(three, request = 1)))
        io.timers[0]()
        assertEquals("a second timer call does nothing", 1, got.size)
    }

    @Test
    fun aTimerOfAnOldReadDoesNotEndANewRead() {
        val io = Io()
        val book = DialogBook(io)
        book.peek("d", "w2:p1") { }
        book.onOutput("d", out(three, request = 1))
        val got = ArrayList<AgentDialog?>()
        book.peek("d", "w2:p1") { got += it }
        io.timers[0]()
        assertTrue(got.isEmpty())
    }

    @Test
    fun anUnreachableComputerGivesNull() {
        val io = Io().apply { reachable = false }
        var called = false
        var got: AgentDialog? = parseDialog(out(three), 0)
        DialogBook(io).peek("d", "w2:p1") { called = true; got = it }
        assertTrue(called)
        assertNull(got)
    }

    @Test
    fun anOlderComputerAnswersWithNoRequestNumber() {
        val io = Io()
        val book = DialogBook(io)
        var got: AgentDialog? = null
        book.peek("d", "w2:p1") { got = it }
        assertTrue(book.onOutput("d", out(three, request = null)))
        assertNotNull(got)
    }
}
