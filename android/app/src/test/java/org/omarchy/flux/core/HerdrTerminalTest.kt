package org.omarchy.flux.core

import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.str

class HerdrTerminalTest {
    @Test
    fun aReleasedSessionWaitsForItsCloseOnlyWhileItsStreamRemains() {
        val released = HerdrTerminalSession(
            pane = "w1:p1", mode = "control", session = "ts1", open = false,
            sending = false, code = "released",
        )
        assertTrue(terminalClosePending(released))
        // The link dropped, so the stream is gone: a reconnect must not
        // wait for a terminal_closed that can no longer arrive.
        assertFalse(terminalClosePending(null))
        // A close that already arrived does not wait either.
        assertFalse(terminalClosePending(released.copy(reason = "detached")))
        // A session that never opened has no stream to close.
        assertFalse(terminalClosePending(released.copy(session = "")))
        // A live or newly opened session is not a pending release.
        assertFalse(terminalClosePending(released.copy(code = "")))
    }

    @Test
    fun aTerminalSessionNeverSurvivesALinkChange() {
        val link = Any()
        val other = Any()
        assertTrue("the same link keeps its session", terminalSurvivesLinkChange(link, link))
        assertFalse("a dropped link ends the session", terminalSurvivesLinkChange(link, null))
        assertFalse("a replaced link ends the session", terminalSurvivesLinkChange(link, other))
        assertFalse("a new device has no session on the link", terminalSurvivesLinkChange(null, link))
    }

    @Test
    fun losingTheSessionWhileAuthorizedOffersAReconnect() {
        val session = HerdrTerminalSession(
            pane = "w1:p1", mode = "control", session = "ts1", open = true, sending = false,
        )
        // The first open has not asked for a session yet.
        assertFalse(terminalSessionLost(null, wanted = false, authorized = true))
        // A session that the screen asked for and the computer dropped is
        // a loss, also when the screen never observed it.
        assertTrue(terminalSessionLost(null, wanted = true, authorized = true))
        // Before the unlock there is nothing to lose.
        assertFalse(terminalSessionLost(null, wanted = true, authorized = false))
        // A live session is not a loss.
        assertFalse(terminalSessionLost(session, wanted = true, authorized = true))
    }

    @Test
    fun controlIsHiddenUntilItsOwnBaselineAndAuthorizationAreReady() {
        val session = HerdrTerminalSession(
            pane = "w1:p1", mode = "control", session = "ts1", open = true, sending = false,
        )
        assertTrue(terminalControlReady(session, "ts1", true, true))
        assertFalse(terminalControlReady(session, "", true, true))
        assertFalse(terminalControlReady(session, "old-session", true, true))
        assertFalse(terminalControlReady(session, "ts1", false, true))
        assertFalse(terminalControlReady(session, "ts1", true, false))
        assertFalse(terminalControlReady(session.copy(open = false), "ts1", true, true))
        assertFalse(terminalControlReady(session.copy(sending = true), "ts1", true, true))
        assertFalse(terminalControlReady(session.copy(mode = "observe"), "ts1", true, true))
        assertFalse(terminalControlReady(null, "ts1", true, true))
    }

    private fun body(line: String) = Packet.parse("""{"id":1,"type":"flux.herdr","body":$line}""")!!.body

    @Test
    fun parsesTerminalOpened() {
        val s = parseHerdrTerminalOpened(
            body("""{"kind":"terminal_opened","request":7,"pane":"w1:p1","mode":"control","session":"ts1","width":120,"height":40}"""),
        )!!
        assertEquals("w1:p1", s.pane)
        assertEquals("control", s.mode)
        assertEquals(7L, s.request)
        assertEquals("ts1", s.session)
        assertEquals(120, s.width)
        assertEquals(40, s.height)
        assertTrue(s.open)
        assertFalse(s.sending)
        assertNull(s.error)
    }

    @Test
    fun parsesRefusedTerminalOpen() {
        val s = parseHerdrTerminalOpened(
            body("""{"kind":"terminal_opened","request":2,"pane":"w1:p1","mode":"observe","error":"replies are off on this computer"}"""),
        )!!
        assertFalse("a refused open has no stream", s.open)
        assertEquals("replies are off on this computer", s.error)
        assertEquals("", s.session)
    }

    @Test
    fun staleTerminalAnswersAreReleased() {
        val waiting = HerdrTerminalSession(pane = "w1:p1", mode = "observe", request = 3)
        val answer = waiting.copy(request = 3, session = "ts1", sending = false, open = true)
        assertFalse(staleTerminalAnswer(waiting, answer))
        // The screen is gone or now watches another pane.
        assertTrue(staleTerminalAnswer(null, answer))
        assertTrue(staleTerminalAnswer(waiting.copy(pane = "w2:p2"), answer))
        // An answer that is older than the open the phone waits for.
        assertTrue(staleTerminalAnswer(waiting, answer.copy(request = 2)))
        // Without request numbers the pane decides.
        assertFalse(staleTerminalAnswer(waiting.copy(request = 0), answer.copy(request = 0)))
    }

    @Test
    fun terminalFrameNeedsASession() {
        val f = parseHerdrTerminalFrame(
            body("""{"kind":"terminal_frame","session":"ts1","seq":3,"full":false,"width":80,"height":24,"bytes":"aGVsbG8="}"""),
        )!!
        assertEquals("ts1", f.session)
        assertEquals(3L, f.seq)
        assertEquals(80, f.width)
        assertEquals(24, f.height)
        assertEquals("aGVsbG8=", f.bytes)
        assertEquals(false, f.full)
        // Only a full frame draws a baseline that input may follow.
        val full = parseHerdrTerminalFrame(
            body("""{"kind":"terminal_frame","session":"ts1","seq":1,"full":true,"width":80,"height":24,"bytes":"aGVsbG8="}"""),
        )!!
        assertEquals(true, full.full)
        assertNull("a frame without a session is dropped", parseHerdrTerminalFrame(body("""{"kind":"terminal_frame","bytes":"aGk="}""")))
        assertNull("an output is not a frame", parseHerdrTerminalFrame(body("""{"kind":"output","pane":"w1:p1"}""")))
    }

    @Test
    fun parsesTerminalClosed() {
        val c = parseHerdrTerminalClosed(
            body("""{"kind":"terminal_closed","session":"ts1","code":"agent_ended","reason":"the agent left the pane","request":4}"""),
        )!!
        assertEquals("ts1", c.session)
        assertEquals("agent_ended", c.code)
        assertEquals("the agent left the pane", c.reason)
    }

    @Test
    fun buildsTerminalBodies() {
        assertEquals(
            "terminal_open",
            herdrTerminalOpenBody("w1:p1", "observe", 3).str("kind"),
        )
        assertEquals("w1:p1", herdrTerminalOpenBody("w1:p1", "observe", 3).str("pane"))
        assertEquals("observe", herdrTerminalOpenBody("w1:p1", "observe", 3).str("mode"))
        assertEquals(JsonPrimitive(3L), herdrTerminalOpenBody("w1:p1", "observe", 3)["request"])

        val release = herdrTerminalReleaseBody("ts1", 9)
        assertEquals("terminal_release", release.str("kind"))
        assertEquals("ts1", release.str("session"))
        assertEquals(JsonPrimitive(9L), release["request"])

        val scroll = herdrTerminalScrollBody("ts1", "up", 20, 10)
        assertEquals("terminal_scroll", scroll.str("kind"))
        assertEquals("up", scroll.str("direction"))
        assertEquals(JsonPrimitive(20), scroll["column"])
        assertEquals(JsonPrimitive(10), scroll["row"])

        val mouse = herdrTerminalMouseBody("ts1", "down", "left", 5, 6)
        assertEquals("terminal_mouse", mouse.str("kind"))
        assertEquals("down", mouse.str("action"))
        assertEquals("left", mouse.str("button"))
        assertEquals(JsonPrimitive(5), mouse["column"])
        assertEquals(JsonPrimitive(6), mouse["row"])
    }

    @Test
    fun parsesBridgeCapabilities() {
        val s = parseHerdrState(
            body("""{"kind":"state","enabled":true,"running":true,"bridge":["observe","control","scroll","mouse"],"agents":[]}"""),
        )!!
        assertTrue(s.terminalStream)
        assertEquals(listOf("observe", "control", "scroll", "mouse"), s.bridge)
        val old = parseHerdrState(body("""{"kind":"state","enabled":true,"running":true}"""))!!
        assertFalse("a computer without the bridge has no terminal", old.terminalStream)
    }
}
