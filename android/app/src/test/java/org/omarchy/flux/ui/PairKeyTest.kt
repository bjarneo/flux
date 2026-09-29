package org.omarchy.flux.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairKeyTest {
    @Test
    fun theKeyShowsIn4GroupsOf4() {
        // The shared test vector of the pairing key.
        assertEquals(listOf("5EE6", "825F", "974E", "D59A"), PairKey.groups("5EE6825F974ED59A"))
        assertEquals("5EE6 825F 974E D59A", PairKey.display("5EE6825F974ED59A"))
        assertEquals("5BB2 2DB1 1047 F34B", PairKey.display("5bb22db11047f34b"))
        assertEquals("the stored value has no spaces, but a spaced value shows the same", "5EE6 825F 974E D59A", PairKey.display("5EE6 825F 974E D59A"))
    }

    @Test
    fun aKeyThatIsNotReadyShowsDots() {
        assertEquals(List(4) { "…" }, PairKey.groups(""))
    }

    @Test
    fun theUnlockEndsAtItsTime() {
        assertTrue(ReplyLock.unlocked(now = 1_000, until = 1_001))
        assertFalse(ReplyLock.unlocked(now = 1_001, until = 1_001))
        assertFalse("no unlock yet", ReplyLock.unlocked(now = 5, until = 0))
    }
}
