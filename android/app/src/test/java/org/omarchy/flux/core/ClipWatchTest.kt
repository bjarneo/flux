package org.omarchy.flux.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipWatchTest {
    private val pkg = "org.omarchy.flux"

    @Test
    fun matchesTheAospDenialLine() {
        val line = "10-01 09:15:22.351  1000  1234  1300 E ClipboardService: " +
            "Denying clipboard access to org.omarchy.flux, application is not in focus nor is it a system service for user 0"
        assertTrue(ClipGate.isDenial(line, pkg))
    }

    @Test
    fun matchesTheKdeConnectVariant() {
        val line = "E ClipboardService: Denying clipboard access to org.omarchy.flux, " +
            "application is not an active IME nor does it have the necessary permissions"
        assertTrue(ClipGate.isDenial(line, pkg))
    }

    @Test
    fun aPackageWithASuffixDoesNotMatch() {
        val debug = "E ClipboardService: Denying clipboard access to org.omarchy.flux.debug, application is not in focus"
        val longer = "E ClipboardService: Denying clipboard access to org.omarchy.fluxx, application is not in focus"
        assertFalse(ClipGate.isDenial(debug, pkg))
        assertFalse(ClipGate.isDenial(longer, pkg))
    }

    @Test
    fun anotherLineDoesNotMatch() {
        assertFalse(ClipGate.isDenial("E ClipboardService: setPrimaryClip from org.omarchy.flux", pkg))
        assertFalse(ClipGate.isDenial("", pkg))
    }

    @Test
    fun debounceMergesABurst() {
        // The lines of 1 copy come within the merge window and fold into 1 read.
        assertTrue(ClipGate.debounced(now = 1_100, firstLine = 1_000))
        assertTrue(ClipGate.debounced(now = 1_000 + ClipGate.DEBOUNCE_MS - 1, firstLine = 1_000))
        // A later line starts a new read.
        assertFalse(ClipGate.debounced(now = 1_000 + ClipGate.DEBOUNCE_MS, firstLine = 1_000))
        assertFalse(ClipGate.debounced(now = 5_000, firstLine = 1_000))
        // No window is open yet.
        assertFalse(ClipGate.debounced(now = 1_000, firstLine = 0))
    }

    @Test
    fun selfWriteWindowIgnoresFluxOwnWrites() {
        // A line within 2 s of a Flux write is Flux's own line.
        assertTrue(ClipGate.isSelfWrite(now = 10_500, lastSelfWrite = 10_000))
        assertTrue(ClipGate.isSelfWrite(now = 10_000 + ClipGate.SELF_WRITE_MS - 1, lastSelfWrite = 10_000))
        // A line after the window is a real copy.
        assertFalse(ClipGate.isSelfWrite(now = 10_000 + ClipGate.SELF_WRITE_MS, lastSelfWrite = 10_000))
        assertFalse(ClipGate.isSelfWrite(now = 20_000, lastSelfWrite = 10_000))
        // No write happened yet.
        assertFalse(ClipGate.isSelfWrite(now = 500, lastSelfWrite = 0))
    }

    @Test
    fun rateLimitAllowsOneGrabPerSecond() {
        // A second grab within 1 s of the last one is refused.
        assertTrue(ClipGate.rateLimited(now = 3_500, lastGrab = 3_000))
        assertTrue(ClipGate.rateLimited(now = 3_000 + ClipGate.RATE_MS - 1, lastGrab = 3_000))
        // A grab after 1 s is allowed.
        assertFalse(ClipGate.rateLimited(now = 3_000 + ClipGate.RATE_MS, lastGrab = 3_000))
        assertFalse(ClipGate.rateLimited(now = 9_000, lastGrab = 3_000))
        // The first grab is allowed.
        assertFalse(ClipGate.rateLimited(now = 100, lastGrab = 0))
    }
}
