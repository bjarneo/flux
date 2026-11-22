package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LinkNoteTest {
    private val time: (Long) -> String = { "14:02" }
    private val minute = 60_000L

    @Test
    fun aClosedLinkSaysThatTheComputerIsNotReachableAndWhenTheOutputIsFrom() {
        val n = LinkNote.threadNote(online = false, connecting = false, name = "omarchy-xps", outputAt = 5_000, now = 9_000_000, time = time)!!
        assertEquals(ThreadLink.Unreachable, n.state)
        assertEquals("omarchy-xps is not reachable.", n.title)
        assertEquals("This output is from 14:02.", n.detail)
    }

    @Test
    fun aClosedLinkWithNoKnownTimeHasNoSecondLine() {
        val n = LinkNote.threadNote(false, false, "omarchy-xps", 0, 9_000, time)!!
        assertEquals("omarchy-xps is not reachable.", n.title)
        assertEquals("", n.detail)
    }

    @Test
    fun aComputerThatConnectsShowsTheConnectingLine() {
        val n = LinkNote.threadNote(false, true, "omarchy-xps", 5_000, 9_000, time)!!
        assertEquals(ThreadLink.Connecting, n.state)
        assertEquals("Connecting to omarchy-xps", n.title)
        assertEquals("", n.detail)
    }

    @Test
    fun anOpenLinkShowsTheTimeAndTheAgeOfTheOutput() {
        val n = LinkNote.threadNote(true, false, "omarchy-xps", 1_000, 1_000 + 30_000, time)!!
        assertEquals(ThreadLink.Connected, n.state)
        assertEquals("Output from 14:02", n.title)
        assertEquals("now", n.detail)
        assertEquals("3m", LinkNote.threadNote(true, false, "omarchy-xps", 1_000, 1_000 + 3 * minute, time)!!.detail)
    }

    @Test
    fun anOpenLinkWithNoOutputHasNoNote() {
        assertNull(LinkNote.threadNote(true, false, "omarchy-xps", 0, 9_000, time))
    }

    @Test
    fun anOpenLinkWinsOverTheConnectingFlag() {
        assertEquals(ThreadLink.Connected, LinkNote.threadNote(true, true, "omarchy-xps", 1_000, 2_000, time)!!.state)
    }

    @Test
    fun theAgeGrowsInSteps() {
        assertEquals("now", LinkNote.age(59_999))
        assertEquals("1m", LinkNote.age(minute))
        assertEquals("59m", LinkNote.age(59 * minute))
        assertEquals("1h", LinkNote.age(60 * minute))
        assertEquals("23h", LinkNote.age(23 * 60 * minute))
        assertEquals("2d", LinkNote.age(48 * 60 * minute))
        assertEquals("a clock that moves back gives now", "now", LinkNote.age(-5))
    }

    @Test
    fun aRowOfAComputerThatIsNotReachableShowsSince() {
        assertEquals("Not reachable since 14:02", LinkNote.rowLine(false, 5_000, time))
        assertEquals("Not reachable", LinkNote.rowLine(false, 0, time))
        assertNull(LinkNote.rowLine(true, 5_000, time))
    }
}
