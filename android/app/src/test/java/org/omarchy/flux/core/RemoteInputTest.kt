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
