package org.omarchy.flux.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DndGuardTest {
    @Test
    fun localChangesGoOutOnce() {
        val g = DndGuard()
        assertFalse("the first state is the start value", g.local(false, 0))
        assertFalse("the same state is not a change", g.local(false, 10))
        assertTrue("a new state goes to the computers", g.local(true, 20))
        assertFalse("a change goes out once", g.local(true, 30))
    }

    @Test
    fun remoteChangeDoesNotEcho() {
        val g = DndGuard()
        g.local(false, 0)
        assertTrue("a new state from a computer applies", g.remote(true, 100))
        assertFalse("the old state during the wait is not a change", g.local(false, 500))
        assertFalse("the applied state does not go back", g.local(true, 800))
        assertFalse("the same state from a computer does not apply again", g.remote(true, 900))
        assertTrue("a later local change goes out", g.local(false, 10_000))
    }

    @Test
    fun failedApplyGivesThePhoneState() {
        val g = DndGuard(settleMs = 3_000)
        g.local(false, 0)
        g.remote(true, 0)
        assertFalse(g.local(false, 2_000))
        assertTrue("after the wait, the phone state goes out", g.local(false, 4_000))
    }

    @Test
    fun remoteBeforeTheFirstLocalState() {
        val g = DndGuard()
        assertTrue(g.remote(true, 0))
        assertFalse(g.local(true, 10))
    }
}
