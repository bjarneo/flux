package org.omarchy.flux.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.core.AgentStatus
import org.omarchy.flux.core.HerdrAgent
import org.omarchy.flux.core.HerdrState
import org.omarchy.flux.core.HerdrTerminal
import org.omarchy.flux.core.HerdrTerminalSession

class LiveTerminalTest {
    private val herdr = HerdrState(enabled = true, running = true, agents = emptyList(), control = true, bridge = listOf("observe", "control"))

    @Test
    fun liveShowsOnlyWhenTheComputerAllowsControl() {
        assertTrue(liveOffered(online = true, agent = true, herdr = herdr, demo = false, sample = false))
        assertFalse("the computer is not reachable", liveOffered(online = false, agent = true, herdr = herdr, demo = false, sample = false))
        assertFalse("the agent is gone", liveOffered(online = true, agent = false, herdr = herdr, demo = false, sample = false))
        assertFalse("no agent list yet", liveOffered(online = true, agent = true, herdr = null, demo = false, sample = false))
        assertFalse("replies are off", liveOffered(online = true, agent = true, herdr = herdr.copy(control = false), demo = false, sample = false))
        assertFalse("herdr cannot control", liveOffered(online = true, agent = true, herdr = herdr.copy(bridge = listOf("observe")), demo = false, sample = false))
    }

    @Test
    fun aDemoComputerOffersLiveOnlyWithASampleScreen() {
        assertTrue(liveOffered(online = true, agent = true, herdr = herdr, demo = true, sample = true))
        // Without a sample, the demo screen stays as the screenshots show it.
        assertFalse(liveOffered(online = true, agent = true, herdr = herdr, demo = true, sample = false))
    }

    @Test
    fun theEndOfTheAgentOrThePaneEndsLive() {
        assertEquals("The agent in this pane ended.", liveEndReason("agent_ended", "omarchy"))
        assertEquals("herdr closed this pane.", liveEndReason("pane_closed", "omarchy"))
        assertEquals("omarchy stopped the live terminal.", liveEndReason("stopped", "omarchy"))
        // A release or a lost bridge can open again.
        assertNull(liveEndReason("released", "omarchy"))
        assertNull(liveEndReason("bridge", "omarchy"))
        assertNull(liveEndReason("", "omarchy"))
    }

    @Test
    fun theStateWithoutTheAgentEndsLiveBeforeTheStreamCloses() {
        val agent = HerdrAgent("w1:p1", "claude", AgentStatus.Working)
        val running = herdr.copy(agents = listOf(agent), terminals = true)
        assertNull("the agent runs", liveGoneReason(running, "w1:p1", "omarchy"))
        assertNull("no state arrived", liveGoneReason(null, "w1:p1", "omarchy"))
        // The agent ended, and its pane stays as a terminal.
        val shell = running.copy(agents = emptyList(), panes = listOf(HerdrTerminal("w1:p1")))
        assertEquals("The agent in this pane ended.", liveGoneReason(shell, "w1:p1", "omarchy"))
        // herdr closed the pane, so the pane is not in the list of terminals.
        assertEquals("herdr closed this pane.", liveGoneReason(running.copy(agents = emptyList()), "w1:p1", "omarchy"))
        // Without terminals, the state lists no panes, so the agent ended.
        assertEquals(
            "The agent in this pane ended.",
            liveGoneReason(running.copy(agents = emptyList(), terminals = false), "w1:p1", "omarchy"),
        )
        // herdr stopped, or the computer turned agent status off.
        assertEquals("omarchy stopped the live terminal.", liveGoneReason(running.copy(running = false, agents = emptyList()), "w1:p1", "omarchy"))
        assertEquals("omarchy stopped the live terminal.", liveGoneReason(running.copy(enabled = false, agents = emptyList()), "w1:p1", "omarchy"))
        // An agent in another pane does not keep Live of this pane.
        assertEquals("herdr closed this pane.", liveGoneReason(running.copy(agents = listOf(agent.copy(pane = "w2:p1"))), "w1:p1", "omarchy"))
    }

    @Test
    fun liveOpensAgainAtMost4TimesWithALongerWaitEachTime() {
        val retries = LiveRetries()
        assertEquals(LIVE_RETRY_MS, retries.fail())
        assertEquals(LIVE_RETRY_MS * 2, retries.fail())
        assertEquals(LIVE_RETRY_MS * 4, retries.fail())
        // The 4 waits cover the 14 seconds that fluxd can take with an earlier open.
        assertEquals(LIVE_RETRY_MS * 8, retries.fail())
        assertNull("Live ends after $LIVE_RETRIES failures", retries.fail())
    }

    @Test
    fun onlyAStreamThatShowedForAWhileStartsANewCount() {
        val retries = LiveRetries()
        assertEquals(LIVE_RETRY_MS, retries.fail())
        // A stream that draws and then fails at once keeps the count.
        retries.ran(LIVE_STABLE_MS - 1)
        assertEquals(LIVE_RETRY_MS * 2, retries.fail())
        retries.ran(2_000)
        assertEquals(LIVE_RETRY_MS * 4, retries.fail())
        retries.ran(0)
        assertEquals(LIVE_RETRY_MS * 8, retries.fail())
        retries.ran(0)
        assertNull(retries.fail())
        // A stream that showed for a while starts a new count, also after the last failure.
        val stable = LiveRetries()
        repeat(LIVE_RETRIES) { stable.fail() }
        stable.ran(LIVE_STABLE_MS)
        assertEquals(LIVE_RETRY_MS, stable.fail())
    }

    @Test
    fun anOpenThatTheLinkLostCountsButDoesNotWait() {
        val retries = LiveRetries()
        assertTrue(retries.lost())
        // A lost open does not make the next wait longer.
        assertEquals(LIVE_RETRY_MS, retries.fail())
        assertTrue(retries.lost())
        assertTrue(retries.lost())
        assertFalse("a link that keeps changing ends Live", retries.lost())
    }

    @Test
    fun theOpenWaitIgnoresTheSlotFromBeforeTheOpen() {
        val pending = HerdrTerminalSession(pane = "w1:p1", mode = "control", request = 5)
        val old = pending.copy(request = 3, sending = false, session = "ts1", open = true)
        // Right after the open, the published state can still hold no slot or the old slot.
        assertFalse("no slot yet", openSettled(null, 5, seen = false))
        assertFalse("the old slot", openSettled(old, 5, seen = false))
        assertFalse("the open waits for its answer", openSettled(pending, 5, seen = true))
        assertTrue("the answer arrived", openSettled(pending.copy(sending = false, open = true), 5, seen = true))
        assertTrue("a lost link dropped the open", openSettled(null, 5, seen = true))
        assertTrue("a newer open replaced it", openSettled(pending.copy(request = 7), 5, seen = false))
    }

    @Test
    fun aRefusedOpenShowsTheErrorOfTheComputer() {
        assertEquals(
            "The live terminal did not open: another device controls that terminal.",
            liveOpenError("another device controls that terminal"),
        )
        assertEquals("The live terminal did not open: omarchy did not answer.", liveOpenError("omarchy did not answer."))
    }
}
    @Test
    fun directInputRequiresAnOptedInLiveView() {
        val input = herdr.copy(bridge = herdr.bridge + "input")
        assertTrue(liveInputOffered(live = true, herdr = input, sample = false))
        assertFalse("Output keeps its composer", liveInputOffered(false, input, false))
        assertFalse("older computers keep their composer", liveInputOffered(true, herdr, false))
        assertFalse("demo input is off", liveInputOffered(true, input, true))
        assertFalse("no state", liveInputOffered(true, null, false))
        assertFalse("control is off", liveInputOffered(true, input.copy(control = false), false))
    }
