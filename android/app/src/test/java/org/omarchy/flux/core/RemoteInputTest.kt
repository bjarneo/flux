package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.OUTGOING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bool

class RemoteInputTest {
    private fun roundTrip(p: Packet): Packet = Packet.parse(p.serialize().trim())!!

    @Test
    fun capabilitiesMatchTheComputer() {
        assertTrue(Types.MOUSEPAD_REQUEST in OUTGOING)
        assertTrue(Types.FLUX_INPUT in INCOMING)
    }

    @Test
    fun motionAndScrollBodies() {
        val move = roundTrip(RemoteInput.move(3.14159f, -2f))
        assertEquals(Types.MOUSEPAD_REQUEST, move.type)
        assertEquals("3.14", move.body["dx"].toString())
        assertEquals("-2.0", move.body["dy"].toString())
        assertNull(move.body["scroll"])

        val scroll = roundTrip(RemoteInput.scroll(0f, 12.5f))
        assertEquals(true, scroll.body.bool("scroll"))
        assertEquals("12.5", scroll.body["dy"].toString())
    }

    @Test
    fun clicksAndHold() {
        assertEquals(true, RemoteInput.click(RemoteInput.Click.Left).body.bool("singleclick"))
        assertEquals(true, RemoteInput.click(RemoteInput.Click.Right).body.bool("rightclick"))
        assertEquals(true, RemoteInput.click(RemoteInput.Click.Middle).body.bool("middleclick"))
        assertEquals(true, RemoteInput.hold(true).body.bool("singlehold"))
        assertEquals(true, RemoteInput.hold(false).body.bool("singlerelease"))
    }

    @Test
    fun keysUseTheProtocolNumbers() {
        val enter = roundTrip(RemoteInput.key(RemoteInput.Key.Enter))
        assertEquals("12", enter.body["specialKey"].toString())
        assertEquals(1, RemoteInput.Key.Backspace.code)
        assertEquals(14, RemoteInput.Key.Escape.code)

        val tab = RemoteInput.key(RemoteInput.Key.Tab, RemoteInput.Mods(ctrl = true, shift = true))
        assertEquals(true, tab.body.bool("ctrl"))
        assertEquals(true, tab.body.bool("shift"))
        assertNull(tab.body["alt"])
    }

    @Test
    fun textWithSuper() {
        val p = roundTrip(RemoteInput.text(" ", RemoteInput.Mods(meta = true)))
        assertEquals(" ", p.string("key"))
        assertEquals(true, p.body.bool("super"))
    }

    @Test
    fun textEdits() {
        assertEquals(TextEdit(0, "b"), TextEdit.between("a", "ab"))
        assertEquals(TextEdit(1, ""), TextEdit.between("ab", "a"))
        // A correction replaces the word.
        assertEquals(TextEdit(2, "he "), TextEdit.between("teh", "the "))
        assertEquals(TextEdit(0, ""), TextEdit.between("same", "same"))
        // An emoji is 1 backspace on the computer.
        assertEquals(TextEdit(1, ""), TextEdit.between("hi 😀", "hi "))
        assertEquals(TextEdit(2, "å"), TextEdit.between("æøå", "æå"))
    }

    @Test
    fun repeatedKeys() {
        assertTrue(RemoteInput.keys(RemoteInput.Key.Backspace, 0, repeat = true).isEmpty())
        // An older computer reads no repeat: 1 packet for each press.
        val each = RemoteInput.keys(RemoteInput.Key.Backspace, 3, repeat = false)
        assertEquals(3, each.size)
        assertNull(each[0].body["repeat"])

        val one = roundTrip(RemoteInput.keys(RemoteInput.Key.Backspace, 1, repeat = true).single())
        assertNull(one.body["repeat"])

        val many = RemoteInput.keys(RemoteInput.Key.Backspace, RemoteInput.MAX_REPEAT + 2, repeat = true, RemoteInput.Mods(ctrl = true)).map(::roundTrip)
        assertEquals(2, many.size)
        assertEquals("1", many[0].body["specialKey"].toString())
        assertEquals(RemoteInput.MAX_REPEAT.toString(), many[0].body["repeat"].toString())
        assertEquals("2", many[1].body["repeat"].toString())
        assertEquals(true, many[1].body.bool("ctrl"))
    }

    @Test
    fun draftLinesUseShiftEnter() {
        val p = RemoteInput.draft("Hei,\r\n\nsee you").map(::roundTrip)
        assertEquals(4, p.size)
        assertEquals("Hei,", p[0].string("key"))
        assertEquals("12", p[1].body["specialKey"].toString())
        assertEquals(true, p[1].body.bool("shift"))
        assertEquals(true, p[2].body.bool("shift"))
        assertEquals("see you", p[3].string("key"))
        assertTrue(RemoteInput.draft("").isEmpty())
        val lines = List(150) { "line $it" }.joinToString("\n")
        assertEquals(RemoteInput.MAX_DRAFT_LINES, RemoteInput.draftLines(lines).split('\n').size)
        assertEquals("a\nb", RemoteInput.draftLines("a\nb"))

        // A long line goes in parts of whole characters.
        val long = "😀".repeat(5000)
        val parts = RemoteInput.draft(long).map { it.string("key")!! }
        assertEquals(2, parts.size)
        assertEquals(4096, parts[0].codePointCount(0, parts[0].length))
        assertEquals(long, parts.joinToString(""))
    }

    @Test
    fun typeMirror() {
        val m = TypeMirror()
        assertEquals(TypeMirror.Change.Edit(0, "hel"), m.change("hel", modsHeld = false))
        assertEquals(TypeMirror.Change.Edit(0, "lo 😀"), m.change("hello 😀", modsHeld = false))
        // A correction replaces the end.
        assertEquals(TypeMirror.Change.Edit(4, "p"), m.change("help", modsHeld = false))
        assertTrue(m.dropLast())
        assertEquals("hel", m.sent)
        assertEquals(3, m.clear())
        assertEquals("", m.sent)
        assertTrue(!m.dropLast())

        m.change("ab", modsHeld = false)
        assertEquals(TypeMirror.Change.Shortcut("c"), m.change("abc", modsHeld = true))
        assertEquals("", m.sent)
        // The text stays after 48 characters, so that Clear deletes all of it.
        val long = "word ".repeat(30)
        m.change(long, modsHeld = false)
        assertEquals(long, m.sent)
        m.reset()
        assertEquals(0, m.clear())
    }

    @Test
    fun fastFingersMoveFurther() {
        val slow = RemoteInput.pointerScale(1f)
        val fast = RemoteInput.pointerScale(30f)
        assertTrue(fast > slow)
        assertEquals(RemoteInput.pointerScale(100f), RemoteInput.pointerScale(1000f), 0.0001f)
    }

    @Test
    fun positionsOfTheRemoteDesktop() {
        val at = roundTrip(RemoteInput.at(0.123456f, 2f))
        assertEquals("0.1235", at.body["x"].toString())
        assertEquals("1.0", at.body["y"].toString())
        assertNull(at.body["dx"])

        val click = roundTrip(RemoteInput.clickAt(RemoteInput.Click.Right, 0.5f, 0.25f))
        assertEquals(true, click.body.bool("rightclick"))
        assertEquals("0.5", click.body["x"].toString())
        assertEquals("0.25", click.body["y"].toString())

        assertEquals(true, RemoteInput.holdAt(true, 0f, 0f).body.bool("singlehold"))
        assertEquals(true, RemoteInput.holdAt(false, 0f, 0f).body.bool("singlerelease"))

        val scroll = roundTrip(RemoteInput.scrollAt(0f, -3f, 0.5f, 0.5f))
        assertEquals(true, scroll.body.bool("scroll"))
        assertEquals("-3.0", scroll.body["dy"].toString())
        assertEquals("0.5", scroll.body["x"].toString())
    }
}
