package org.omarchy.flux.ui

import android.view.MotionEvent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OverlaysTest {
    private val over = MotionEvent.FLAG_WINDOW_IS_OBSCURED
    private val part = MotionEvent.FLAG_WINDOW_IS_PARTIALLY_OBSCURED

    @Test
    fun aWindowOverTheTouchAlwaysBlocksTheTap() {
        assertTrue(Overlays.obscured(over, sdk = 29))
        assertTrue(Overlays.obscured(over, sdk = 31))
        assertTrue(Overlays.obscured(over or part, sdk = 36))
    }

    @Test
    fun aWindowOverAPartBlocksTheTapOnlyBeforeAndroid12() {
        assertTrue(Overlays.obscured(part, sdk = 29))
        assertTrue(Overlays.obscured(part, sdk = 30))
        assertFalse("Android 12 hides the windows of other apps", Overlays.obscured(part, sdk = 31))
        assertFalse(Overlays.obscured(part, sdk = 36))
    }

    @Test
    fun aClearTouchPasses() {
        assertFalse(Overlays.obscured(0, sdk = 29))
        assertFalse(Overlays.obscured(0, sdk = 36))
    }
}
