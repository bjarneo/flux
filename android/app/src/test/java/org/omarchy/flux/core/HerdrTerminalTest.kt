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
        // The link dropped, so the stream is gone. A reconnect must not
        // wait for a terminal_closed that can no longer arrive.
        assertFalse(terminalClosePending(null))
        // A close that already arrived does not wait either, also when
        // the computer sent no reason.
        assertFalse(terminalClosePending(released.copy(closed = true, reason = "detached")))
        assertFalse(terminalClosePending(released.copy(closed = true)))
        // Only the closed flag counts, not the text of a reason.
        assertTrue(terminalClosePending(released.copy(reason = "released")))
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
    fun terminalFrameNeedsBase64BytesAndAValidGrid() {
        fun frame(bytes: String, width: Int = 80, height: Int = 24) = parseHerdrTerminalFrame(
            body("""{"kind":"terminal_frame","session":"ts1","seq":1,"width":$width,"height":$height,"bytes":${JsonPrimitive(bytes)}}"""),
        )
        assertEquals("", frame("")?.bytes)
        assertEquals("aGk=", frame("aGk=")?.bytes)
        assertEquals("a+/b", frame("a+/b")?.bytes)
        // The bytes go into the page as a string literal, so a quote or
        // any other character is refused.
        assertNull(frame("');FluxBridge.grid(20,6);('"))
        assertNull(frame("aGk=\n"))
        assertNull(frame("aGk"))
        assertNull(frame("a==="))
        assertNull(frame("a=b="))
        // The grid has the limits of fluxd.
        assertNull(frame("aGk=", width = 0))
        assertNull(frame("aGk=", height = 0))
        assertNull(frame("aGk=", width = 1001))
        assertNull(frame("aGk=", height = 100_000))
        assertEquals(1000, frame("aGk=", width = 1000, height = 1000)?.height)
        assertNull(
            "a frame without a size is refused",
            parseHerdrTerminalFrame(body("""{"kind":"terminal_frame","session":"ts1","bytes":"aGk="}""")),
        )
    }

    @Test
    fun aReleaseActsOnlyOnTheSessionOfItsPane() {
        val open = HerdrTerminalSession(
            pane = "w1:p1", mode = "control", request = 4, sending = false, session = "ts1", open = true,
        )
        // The screen of another pane leaves the session alone.
        assertNull(terminalReleaseChange(open, "w2:p1"))
        assertNull(terminalReleaseChange(null, "w1:p1"))
        // An open stream waits for its close, and the computer releases it.
        val released = terminalReleaseChange(open, "w1:p1")!!
        assertEquals("ts1", released.release)
        assertEquals("released", released.slot?.code)
        assertFalse(released.slot!!.open)
        assertTrue(terminalClosePending(released.slot))
        // A second release while the close waits changes nothing.
        assertNull(terminalReleaseChange(released.slot, "w1:p1"))
        // An open that waits for its answer goes. Its late answer is then stale.
        val pending = HerdrTerminalSession(pane = "w1:p1", mode = "control", request = 5)
        val dropped = terminalReleaseChange(pending, "w1:p1")!!
        assertNull(dropped.slot)
        assertNull(dropped.release)
        assertTrue(staleTerminalAnswer(dropped.slot, open.copy(request = 5)))
        // A stream that ended and an open that failed also go.
        assertEquals(TerminalSlotChange(null), terminalReleaseChange(released.slot!!.copy(closed = true), "w1:p1"))
        assertEquals(TerminalSlotChange(null), terminalReleaseChange(pending.copy(sending = false, error = "no"), "w1:p1"))
    }

    @Test
    fun anOpenReleasesTheOpenStreamThatItReplaces() {
        val open = HerdrTerminalSession(
            pane = "w1:p1", mode = "control", request = 4, sending = false, session = "ts1", open = true,
        )
        val change = terminalOpenChange(open, "w2:p1", "control", 7)
        assertEquals("ts1", change.release)
        assertEquals(HerdrTerminalSession(pane = "w2:p1", mode = "control", request = 7), change.slot)
        assertTrue(change.slot!!.sending)
        // Nothing runs on the computer for a pending, released, or empty slot.
        assertNull(terminalOpenChange(null, "w1:p1", "control", 8).release)
        assertNull(terminalOpenChange(open.copy(open = false, code = "released"), "w1:p1", "control", 8).release)
        assertNull(terminalOpenChange(HerdrTerminalSession(pane = "w1:p1", mode = "control", request = 3), "w2:p1", "control", 8).release)
    }

    @Test
    fun anOpenWithoutAnswerFailsSoThatItCanRetry() {
        val pending = HerdrTerminalSession(pane = "w1:p1", mode = "control", request = 7)
        val failed = terminalOpenTimeout(pending, 7, "omarchy did not answer")!!
        assertFalse(failed.sending)
        assertTrue(failed.retry)
        assertEquals("omarchy did not answer", failed.error)
        // The answer came first, or a newer open took the slot.
        assertNull(terminalOpenTimeout(pending.copy(sending = false, session = "ts1", open = true), 7, "late"))
        assertNull(terminalOpenTimeout(pending.copy(request = 8), 7, "late"))
        assertNull(terminalOpenTimeout(null, 7, "late"))
        // A late answer to the failed open is still the answer of that open.
        assertFalse(staleTerminalAnswer(failed, pending.copy(sending = false, session = "ts1", open = true)))
        // A refusal of the computer is no reason to retry.
        val refused = parseHerdrTerminalOpened(
            body("""{"kind":"terminal_opened","request":7,"pane":"w1:p1","mode":"control","error":"another device controls that terminal"}"""),
        )!!
        assertFalse(refused.retry)
    }

    @Test
    fun aRefusalWithTheRetryFlagCanOpenAgain() {
        // fluxd still opens an earlier terminal for this phone, or the open took too long.
        val busy = parseHerdrTerminalOpened(
            body(
                """{"kind":"terminal_opened","request":8,"pane":"w1:p1","mode":"control",""" +
                    """"error":"fluxd already opens a terminal for this device. Try again.","retry":true}""",
            ),
        )!!
        assertTrue(busy.retry)
        assertFalse(busy.open)
        assertFalse(busy.sending)
        assertEquals("fluxd already opens a terminal for this device. Try again.", busy.error)
        // A false flag and a flag that is not a boolean are no reason to retry.
        val final = parseHerdrTerminalOpened(
            body("""{"kind":"terminal_opened","request":8,"pane":"w1:p1","mode":"control","error":"no","retry":false}"""),
        )!!
        assertFalse(final.retry)
        val text = parseHerdrTerminalOpened(
            body("""{"kind":"terminal_opened","request":8,"pane":"w1:p1","mode":"control","error":"no","retry":"yes"}"""),
        )!!
        assertFalse(text.retry)
        // An open stream has nothing to retry, also with the flag.
        val open = parseHerdrTerminalOpened(
            body("""{"kind":"terminal_opened","request":8,"pane":"w1:p1","mode":"control","session":"ts1","width":60,"height":37,"retry":true}"""),
        )!!
        assertTrue(open.open)
        assertFalse(open.retry)
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

        val resize = herdrTerminalResizeBody("ts1", 48, 80)
        assertEquals("terminal_resize", resize.str("kind"))
        assertEquals("ts1", resize.str("session"))
        assertEquals(JsonPrimitive(48), resize["cols"])
        assertEquals(JsonPrimitive(80), resize["rows"])

        val text = herdrTerminalInputBody("ts1", "@")
        assertEquals("terminal_input", text.str("kind"))
        assertEquals("ts1", text.str("session"))
        assertEquals("@", text.str("text"))
        assertNull(text["key"])

        val key = herdrTerminalKeyBody("ts1", "down")
        assertEquals("terminal_input", key.str("kind"))
        assertEquals("ts1", key.str("session"))
        assertEquals("down", key.str("key"))
        assertNull(key["text"])

        val paste = herdrTerminalPasteBody("ts1", "one\ntwo")
        assertEquals("terminal_paste", paste.str("kind"))
        assertEquals("ts1", paste.str("session"))
        assertEquals("one\ntwo", paste.str("text"))
        assertNull(paste["key"])

        val image = herdrTerminalPasteImageBody("ts1")
        assertEquals("terminal_paste_image", image.str("kind"))
        assertEquals("ts1", image.str("session"))
        assertNull("the image travels as the payload, not the body", image["text"])
    }

    @Test
    fun parsesTerminalInputError() {
        val e = parseHerdrTerminalInputError(
            body("""{"kind":"terminal_input_error","session":"ts1","code":"invalid_input","error":"no"}"""),
        )!!
        assertEquals("ts1", e.session)
        assertEquals("invalid_input", e.code)
        assertEquals("no", e.error)
        assertNull("another kind is not an input error", parseHerdrTerminalInputError(body("""{"kind":"sent","session":"ts1"}""")))
        assertNull("an error without a session is dropped", parseHerdrTerminalInputError(body("""{"kind":"terminal_input_error","code":"x"}""")))
    }

    @Test
    fun parsesBridgeCapabilities() {
        val s = parseHerdrState(
            body("""{"kind":"state","enabled":true,"running":true,"control":true,"bridge":["observe","control","scroll","mouse"],"agents":[]}"""),
        )!!
        assertTrue(s.liveTerminal)
        assertFalse(s.terminalInput)
        assertTrue(s.copy(bridge = s.bridge + "input").terminalInput)
        assertEquals(listOf("observe", "control", "scroll", "mouse"), s.bridge)
        assertFalse(s.terminalImage)
        assertTrue(s.copy(bridge = s.bridge + "image").terminalImage)
        assertFalse(s.terminalPaste)
        assertTrue(s.copy(bridge = s.bridge + "paste").terminalPaste)
        val old = parseHerdrState(body("""{"kind":"state","enabled":true,"running":true,"control":true}"""))!!
        assertFalse("a computer without the bridge has no live terminal", old.liveTerminal)
    }

    @Test
    fun theLiveTerminalNeedsControlAndTheControlBridge() {
        val state = HerdrState(enabled = true, running = true, agents = emptyList(), control = true, bridge = listOf("observe", "control"))
        assertTrue(state.liveTerminal)
        assertFalse("replies are off", state.copy(control = false).liveTerminal)
        assertFalse("the bridge only observes", state.copy(bridge = listOf("observe")).liveTerminal)
        assertFalse("an older fluxd sends no bridge", state.copy(bridge = emptyList()).liveTerminal)
    }
}
