package org.omarchy.flux.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectGraceTest {
    @Test
    fun aNewAttemptCountsAsConnecting() {
        assertTrue(inConnectGrace(startedAt = 10_000, now = 10_000))
        assertTrue(inConnectGrace(startedAt = 10_000, now = 10_000 + CONNECT_GRACE_MS - 1))
    }

    @Test
    fun theGraceEndsAfterItsTime() {
        assertFalse(inConnectGrace(startedAt = 10_000, now = 10_000 + CONNECT_GRACE_MS))
        assertFalse(inConnectGrace(startedAt = 10_000, now = 60_000))
    }

    @Test
    fun noAttemptMeansNoGrace() {
        // Before the network starts, and after Flux turns off, a computer that is not online is not reachable.
        assertFalse(inConnectGrace(startedAt = 0, now = 1_000))
    }

    @Test
    fun aClockBeforeTheStartIsNoGrace() {
        assertFalse(inConnectGrace(startedAt = 10_000, now = 9_000))
    }
}
