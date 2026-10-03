package org.omarchy.flux.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MulticastTest {
    @Test
    fun aScanAndTheFirstPairingKeepTheLock() {
        assertTrue("a scan", multicastNeeded(scanning = true, paired = true, pairedAway = false, searching = false))
        assertTrue("no paired computer", multicastNeeded(scanning = false, paired = false, pairedAway = false, searching = false))
    }

    @Test
    fun anAwayComputerKeepsTheLockOnlyAfterATrigger() {
        assertTrue("after a trigger", multicastNeeded(scanning = false, paired = true, pairedAway = true, searching = true))
        assertFalse("the time after the trigger ended", multicastNeeded(scanning = false, paired = true, pairedAway = true, searching = false))
    }

    @Test
    fun connectedComputersNeedNoLock() {
        assertFalse(multicastNeeded(scanning = false, paired = true, pairedAway = false, searching = false))
        assertFalse("a trigger alone", multicastNeeded(scanning = false, paired = true, pairedAway = false, searching = true))
    }
}
