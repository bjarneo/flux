package org.omarchy.flux.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import org.omarchy.flux.core.AgentStatus

class ControlScreenTest {
    @Test
    fun agentTimes() {
        val now = 10_000_000L
        assertEquals("done", agentWhen(AgentStatus.Done, null, now))
        assertEquals("a time that the phone did not see is empty", "", agentWhen(AgentStatus.Blocked, null, now))
        assertEquals("now", agentWhen(AgentStatus.Blocked, now - 30_000, now))
        assertEquals("3m", agentWhen(AgentStatus.Blocked, now - 3 * 60_000 - 5_000, now))
        assertEquals("2h", agentWhen(AgentStatus.Idle, now - 2 * 3_600_000, now))
        assertEquals("2:14", agentWhen(AgentStatus.Working, now - 134_000, now))
        assertEquals("", agentWhen(AgentStatus.Unknown, now - 134_000, now))
    }

    @Test
    fun agoTexts() {
        val now = 100_000_000L
        assertEquals("just now", agoText(now - 20_000, now))
        assertEquals("1 min ago", agoText(now - 60_000, now))
        assertEquals("2 h ago", agoText(now - 2 * 3_600_000, now))
        assertEquals("1 day ago", agoText(now - 25 * 3_600_000L, now))
        assertEquals("3 days ago", agoText(now - 3 * 24 * 3_600_000L, now))
    }

    @Test
    fun breakAllKeepsTheTextAndTheSpaces() {
        val out = breakAll("ab c😀")
        assertEquals("ab c😀", out.replace("​", ""))
        assertEquals("a​b c​😀", out)
    }

    @Test
    fun windowIcons() {
        assertEquals(Ic.terminal, windowIcon("com.mitchellh.ghostty"))
        assertEquals(Ic.web, windowIcon("chrome-app.hey.com__-Default"))
        assertEquals(Ic.chat, windowIcon("signal"))
        assertEquals(Ic.window, windowIcon("org.example.Unknown"))
    }
}
