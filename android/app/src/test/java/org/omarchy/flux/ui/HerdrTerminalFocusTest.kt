package org.omarchy.flux.ui

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.core.terminalImageSize

/**
 * The keyboard of the live terminal. Android ignores showSoftInput() for a
 * view that it does not serve. A phone is in touch mode, and a view that
 * is not focusable in touch mode cannot take focus there. requestFocus()
 * then returns false, and the keyboard never opens. These tests guard the
 * focus flags, the input gate, and the typed line. The real keyboard still
 * needs the phone.
 */
class HerdrTerminalFocusTest {
    @Test
    fun correctionOffsetsStayValidBeyondTheOldMirrorLimit() {
        assertTrue(imeReplacementInBounds(664, 670, 712))
        assertTrue(imeReplacementInBounds(707, 712, 712))
        assertFalse("a truncated buffer loses the range", imeReplacementInBounds(664, 670, 256))
        assertFalse("an old connection has stale offsets", imeReplacementInBounds(707, 712, 0))
        assertFalse(imeReplacementInBounds(-1, 4, 712))
    }

    @Test
    fun theTerminalTakesFocusInTheTouchModeOfThePhone() {
        // With focusable-in-touch-mode false, the key did nothing, because
        // Android refused requestFocus() and then ignored showSoftInput()
        // on a view that it did not serve.
        assertTrue("the terminal view must be focusable in touch mode", TERMINAL_FOCUSABLE_IN_TOUCH_MODE)
        assertTrue(
            "the keyboard opens when the gate is ready and the view takes focus",
            keyboardMayOpen(ready = true, focusableInTouchMode = TERMINAL_FOCUSABLE_IN_TOUCH_MODE),
        )
    }

    @Test
    fun aViewThatCannotTakeFocusInTouchModeOpensNoKeyboard() {
        assertFalse(keyboardMayOpen(ready = true, focusableInTouchMode = false))
    }

    @Test
    fun theInputGateBlocksTheKeyboardBeforeTheTerminalIsReady() {
        // A reconnect, an ended unlock, or a first frame that did not draw
        // yet must not open the keyboard onto a stale stream.
        assertFalse(keyboardMayOpen(ready = false, focusableInTouchMode = true))
        assertFalse(keyboardMayOpen(ready = false, focusableInTouchMode = false))
    }

    @Test
    fun aBlockWithALineBreakOrALongBlockIsAPaste() {
        // Typing and composed words go as text, so @ and / still open the menus of the agent.
        assertFalse(committedAsPaste("a"))
        assertFalse(committedAsPaste("@"))
        assertFalse("a swiped word is typed text", committedAsPaste("hello"))
        assertFalse("an emoji is 1 character", committedAsPaste("😀"))
        assertFalse(committedAsPaste("x".repeat(TERMINAL_PASTE_FROM - 1)))
        // A line break must not submit the prompt, and a tab must not complete a word.
        assertTrue(committedAsPaste("one\ntwo"))
        assertTrue(committedAsPaste("a\r\nb"))
        assertTrue(committedAsPaste("\t"))
        // A long block gets the paste handling of the agent.
        assertTrue(committedAsPaste("x".repeat(TERMINAL_PASTE_FROM)))
    }

    @Test
    fun aLineEditCountsCodePoints() {
        assertEquals(LineEdit(0, "b"), lineEdit("a", "ab"))
        assertEquals(LineEdit(1, "é"), lineEdit("cafe", "café"))
        assertEquals(LineEdit(6, "an the"), lineEdit("run the", "ran the"))
        // An emoji is 2 UTF-16 units and 1 backspace.
        assertEquals(LineEdit(1, ""), lineEdit("hi 😀", "hi "))
        assertEquals(LineEdit(2, ""), lineEdit("👍🏽", ""))
        // 😀 and 😃 share the high surrogate. The edit must not start with half of 😃.
        assertEquals(LineEdit(1, "😃"), lineEdit("😀", "😃"))
        assertEquals(LineEdit(0, ""), lineEdit("same", "same"))
    }

    @Test
    fun aSentLineSendsTheEditAndForgetsTheLineWhenAnEventDoesNotGoOut() {
        val sent = mutableListOf<String>()
        val line = SentLine()
        val ok = { s: String -> sent += s; true }
        assertTrue(line.sync("helo", key = ok, type = ok, paste = { false }))
        assertEquals("a word goes as typed text", listOf("helo"), sent)
        sent.clear()
        // A correction becomes backspaces and the new end.
        assertTrue(line.sync("hello", key = ok, type = ok, paste = ok))
        assertEquals(listOf("backspace", "lo"), sent)
        assertEquals("hello", line.text)
        // A dropped event leaves the line empty, so the next edit does not count on it.
        assertFalse(line.sync("hello!", key = ok, type = { false }, paste = ok))
        assertEquals("", line.text)
        line.reset()
        assertEquals("", line.text)
    }

    @Test
    fun theNamedKeysOfAKeyboard() {
        assertEquals("enter", terminalKeyName(KeyEvent.KEYCODE_ENTER, shift = false))
        assertEquals("enter", terminalKeyName(KeyEvent.KEYCODE_NUMPAD_ENTER, shift = false))
        assertEquals("tab", terminalKeyName(KeyEvent.KEYCODE_TAB, shift = false))
        assertEquals("shift+tab", terminalKeyName(KeyEvent.KEYCODE_TAB, shift = true))
        assertEquals("backspace", terminalKeyName(KeyEvent.KEYCODE_DEL, shift = false))
        assertEquals("esc", terminalKeyName(KeyEvent.KEYCODE_ESCAPE, shift = false))
        assertEquals("left", terminalKeyName(KeyEvent.KEYCODE_DPAD_LEFT, shift = false))
        // A digit is a character, not a named key.
        assertNull(terminalKeyName(KeyEvent.KEYCODE_4, shift = false))
        assertNull(terminalKeyName(KeyEvent.KEYCODE_BACK, shift = false))
    }

    @Test
    fun aPastedImageKeepsItsAspectAtMost2048Pixels() {
        assertEquals(1080 to 2340, terminalImageSize(1080, 2340, max = 4096))
        assertEquals(945 to 2048, terminalImageSize(1080, 2340))
        assertEquals(2048 to 1536, terminalImageSize(4000, 3000))
        assertEquals(800 to 600, terminalImageSize(800, 600))
        assertEquals(2048 to 1, terminalImageSize(65535, 1))
    }
}
