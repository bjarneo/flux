package org.omarchy.flux.core

import org.junit.Assert.assertEquals
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
        // The first line of a copy waits for the merge window.
        assertEquals(ClipGate.DEBOUNCE_MS, ClipGate.grabDelay(now = 1_000, pending = false, lastGrab = 0, lastSelfWrite = 0))
        // The next lines of the copy come while that grab waits and need no grab of their own.
        assertEquals(ClipGate.NO_GRAB, ClipGate.grabDelay(now = 1_100, pending = true, lastGrab = 0, lastSelfWrite = 0))
        assertEquals(ClipGate.NO_GRAB, ClipGate.grabDelay(now = 1_900, pending = true, lastGrab = 500, lastSelfWrite = 0))
        // A line after the grab ran starts a new grab.
        assertEquals(ClipGate.DEBOUNCE_MS, ClipGate.grabDelay(now = 5_000, pending = false, lastGrab = 1_250, lastSelfWrite = 0))
    }

    @Test
    fun grabDelayIgnoresFluxOwnWrites() {
        assertEquals(ClipGate.NO_GRAB, ClipGate.grabDelay(now = 10_500, pending = false, lastGrab = 0, lastSelfWrite = 10_000))
        assertEquals(ClipGate.DEBOUNCE_MS, ClipGate.grabDelay(now = 12_000, pending = false, lastGrab = 0, lastSelfWrite = 10_000))
    }

    @Test
    fun rateLimitMovesALineToALaterGrab() {
        // A copy 300 ms after a grab gets a grab 1 s after that grab, not no grab.
        assertEquals(700L, ClipGate.grabDelay(now = 3_300, pending = false, lastGrab = 3_000, lastSelfWrite = 0))
        // Close to the end of the limit, the merge window is the longer wait.
        assertEquals(ClipGate.DEBOUNCE_MS, ClipGate.grabDelay(now = 3_900, pending = false, lastGrab = 3_000, lastSelfWrite = 0))
        // The later grab covers the next lines too.
        assertEquals(ClipGate.NO_GRAB, ClipGate.grabDelay(now = 3_500, pending = true, lastGrab = 3_000, lastSelfWrite = 0))
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

    @Test
    fun selfTestRunsOnlyForANewReader() {
        assertTrue(ClipGate.needsSelfTest(ClipAutoState.Checking, probing = false))
        // A test that runs already covers the next trip to the background.
        assertFalse(ClipGate.needsSelfTest(ClipAutoState.Checking, probing = true))
        // A checked reader needs no test. A test would drop the line of a real copy.
        assertFalse(ClipGate.needsSelfTest(ClipAutoState.Active, probing = false))
        assertFalse(ClipGate.needsSelfTest(ClipAutoState.NeedsConsent, probing = false))
        assertFalse(ClipGate.needsSelfTest(ClipAutoState.Off, probing = false))
        assertFalse(ClipGate.needsSelfTest(ClipAutoState.Unavailable, probing = false))
    }

    @Test
    fun theReaderRunsOnlyAfterTheUserTurnsOnTheAutomaticSync() {
        // With the accesses in place, the reader still waits for the switch of the setup sheet.
        assertFalse(ClipGate.wantsReader(syncOn = true, autoOn = false, enabled = true, hasReadLogs = true, overlayAccess = true))
        assertTrue(ClipGate.wantsReader(syncOn = true, autoOn = true, enabled = true, hasReadLogs = true, overlayAccess = true))
        // Each other condition stops the reader too.
        assertFalse(ClipGate.wantsReader(syncOn = false, autoOn = true, enabled = true, hasReadLogs = true, overlayAccess = true))
        assertFalse(ClipGate.wantsReader(syncOn = true, autoOn = true, enabled = false, hasReadLogs = true, overlayAccess = true))
        assertFalse(ClipGate.wantsReader(syncOn = true, autoOn = true, enabled = true, hasReadLogs = false, overlayAccess = true))
        assertFalse(ClipGate.wantsReader(syncOn = true, autoOn = true, enabled = true, hasReadLogs = true, overlayAccess = false))
    }

    @Test
    fun anUpdateKeepsTheAutomaticSyncOfAUserWhoSetItUp() {
        // An update from a version without the switch keeps the sync when both accesses are in place.
        assertTrue(ClipGate.keepsAutoSync(updated = true, hasReadLogs = true, overlayAccess = true))
        assertFalse(ClipGate.keepsAutoSync(updated = true, hasReadLogs = false, overlayAccess = true))
        assertFalse(ClipGate.keepsAutoSync(updated = true, hasReadLogs = true, overlayAccess = false))
        // A new install starts with the switch off, also after the adb commands.
        assertFalse(ClipGate.keepsAutoSync(updated = false, hasReadLogs = true, overlayAccess = true))
    }

    @Test
    fun theStateKeepsItsMeaningWithTheAutomaticSwitch() {
        val reader = ClipAutoState.Active
        assertEquals(ClipAutoState.Off, ClipGate.autoState(syncOn = false, autoOn = true, hasReadLogs = true, overlayAccess = true, reader = reader))
        // Without the switch, only the open app syncs, and the status line leads to the setup sheet.
        assertEquals(ClipAutoState.Unavailable, ClipGate.autoState(syncOn = true, autoOn = false, hasReadLogs = true, overlayAccess = true, reader = reader))
        assertEquals(ClipAutoState.Unavailable, ClipGate.autoState(syncOn = true, autoOn = true, hasReadLogs = false, overlayAccess = true, reader = reader))
        assertEquals(ClipAutoState.Unavailable, ClipGate.autoState(syncOn = true, autoOn = true, hasReadLogs = true, overlayAccess = false, reader = reader))
        // With the switch and the accesses, the reader gives the state.
        assertEquals(ClipAutoState.Active, ClipGate.autoState(syncOn = true, autoOn = true, hasReadLogs = true, overlayAccess = true, reader = reader))
        assertEquals(
            ClipAutoState.NeedsConsent,
            ClipGate.autoState(syncOn = true, autoOn = true, hasReadLogs = true, overlayAccess = true, reader = ClipAutoState.NeedsConsent),
        )
    }

    @Test
    fun onlyTheFirstLineOfTheSelfTestIsTheProbe() {
        // The first line in the window is the probe line.
        assertTrue(ClipGate.isProbeLine(now = 1_000, probeUntil = 2_500, probeSeen = false))
        // A later line in the window comes from a real copy.
        assertFalse(ClipGate.isProbeLine(now = 1_200, probeUntil = 2_500, probeSeen = true))
        // A line after the window, or with no test, is a real copy.
        assertFalse(ClipGate.isProbeLine(now = 2_500, probeUntil = 2_500, probeSeen = false))
        assertFalse(ClipGate.isProbeLine(now = 1_000, probeUntil = 0, probeSeen = false))
    }
}
