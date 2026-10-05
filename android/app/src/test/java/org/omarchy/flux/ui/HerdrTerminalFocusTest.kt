package org.omarchy.flux.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The keyboard key of the live terminal. Android ignores showSoftInput()
 * for a view that is not served, and a phone is in touch mode: a view that
 * is not focusable in touch mode cannot take focus there, so requestFocus()
 * returns false and the keyboard never opens. These tests guard the focus
 * flags and the input gate. The real open still needs the phone.
 */
class HerdrTerminalFocusTest {
    @Test
    fun theTerminalTakesFocusInTheTouchModeOfThePhone() {
        // The regression: with focusable-in-touch-mode false, the button
        // did nothing, because Android refused requestFocus() and then
        // ignored showSoftInput() on a view that was not served.
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
        // A reconnect, an expired unlock, or a first frame that has not
        // drawn yet must not open the keyboard onto a stale stream.
        assertFalse(keyboardMayOpen(ready = false, focusableInTouchMode = true))
        assertFalse(keyboardMayOpen(ready = false, focusableInTouchMode = false))
    }

    @Test
    fun aCommittedBlockIsAPasteAndATypedCharacterIsNot() {
        // Ordinary typing arrives one character at a time, so `@` still
        // opens the program's own menu.
        assertFalse(committedAsPaste("a"))
        assertFalse(committedAsPaste("@"))
        assertFalse(committedAsPaste("/"))
        // A paste, a dictation, or a composed word arrives as one block.
        assertTrue(committedAsPaste("hello"))
        assertTrue(committedAsPaste("one\ntwo"))
        assertTrue(committedAsPaste("a\r\nb"))
    }
}
