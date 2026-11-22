package org.omarchy.flux.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue

class RemoteScreenTest {
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

    private fun source(name: String) = File("src/main/java/org/omarchy/flux/ui/$name").readText()

    @Test
    fun controlHoldsNoAgents() {
        val control = source("RemoteScreen.kt")
        for (gone in listOf("AgentList", "AgentCard", "SessionStrip", "NEW_PANE_PAGE", "New agent or terminal", "AGENT_PAGE", "HerdrSync")) {
            assertFalse("Remote still holds $gone", control.contains(gone))
        }
        assertTrue(control.contains("ListHeader(\"Tools\")"))
        assertTrue(control.contains("ListHeader(\"Stream\")"))
    }

    @Test
    fun trayHasNoAgentKey() {
        val tray = source("ChatTray.kt")
        assertFalse(tray.contains("NEW_PANE_PAGE"))
        assertFalse(tray.contains("\"Agent\""))
    }

    @Test
    fun agentStartPointsAreTwo() {
        // Only the + key of Chats and the menu of a computer chat open the new pane page.
        val users = File("src/main/java/org/omarchy/flux/ui").listFiles().orEmpty()
            .filter { it.extension == "kt" && it.readText().contains("Route(") && it.readText().contains("NEW_PANE_PAGE") }
            .map { it.name }.sorted()
        assertEquals(listOf("AppShell.kt", "ChatScreen.kt", "ChatsScreen.kt", "Nav.kt"), users)
    }
}
