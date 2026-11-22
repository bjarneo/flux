package org.omarchy.flux.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.omarchy.flux.core.StreamKind

class NavTest {
    @Test
    fun backPopsThenGoesToTheChatThenLeaves() {
        val agents = Route("pc", AGENTS_PAGE)
        val agent = Route("pc", "${AGENT_PAGE}w2:p1")
        var nav: Nav? = Nav(Tab.Remote, listOf(agents, agent))
        assertEquals(Dest.Detail(agent, 2, Tab.Remote), nav!!.dest)
        nav = nav.back()
        assertEquals(Dest.Detail(agents, 1, Tab.Remote), nav!!.dest)
        nav = nav.back()
        assertEquals(Dest.Root(Tab.Remote), nav!!.dest)
        nav = nav.back()
        assertEquals(Dest.Root(Tab.Chat), nav!!.dest)
        assertNull("Back on the chat leaves the app", nav.back())
    }

    @Test
    fun aDestinationOpensAtItsRoot() {
        val nav = Nav(Tab.Chat, listOf(Route("pc", "browse")))
        assertEquals(Nav(Tab.Computers), nav.select(Tab.Computers))
        assertEquals(Nav(Tab.Chat), nav.select(Tab.Chat))
    }

    @Test
    fun aNewPaneReplacesItsPage() {
        val nav = Nav(Tab.Remote, listOf(Route("pc", AGENTS_PAGE), Route("pc", NEW_PANE_PAGE)))
        val next = nav.replaceTop(Route("pc", "${TERMINAL_PAGE}w1:p3"))
        assertEquals(listOf(Route("pc", AGENTS_PAGE), Route("pc", "${TERMINAL_PAGE}w1:p3")), next.stack)
    }

    @Test
    fun theStateSurvivesARecreation() {
        val nav = Nav(Tab.Computers, listOf(Route(null, SYNC_PAGE), Route("pc", "media")))
        assertEquals(nav, Nav.restore(nav.save()))
        assertEquals(Nav(), Nav.restore(emptyList()))
        assertEquals(Nav(), Nav.restore(listOf("unknown")))
        assertEquals("the Inbox and Send of older versions are now the chat", Nav(Tab.Chat), Nav.restore(listOf("send")))
    }

    @Test
    fun theScreensOfAComputerThatIsGoneClose() {
        val nav = Nav(Tab.Remote, listOf(Route("pc", AGENTS_PAGE), Route("pc", "${AGENT_PAGE}w1:p1")))
        assertEquals(Nav(Tab.Remote), nav.without { it == "pc" })
        assertEquals(nav, nav.without { it == "other" })
        val sync = Nav(Tab.Computers, listOf(Route(null, SYNC_PAGE)))
        assertEquals(sync, sync.without { true })
    }

    @Test
    fun theChatOfAComputerOpensAboveTheListOfChats() {
        val nav = Nav.chat("pc")
        assertEquals(Dest.Detail(Route("pc", CHAT_PAGE), 1, Tab.Chat), nav.dest)
        assertEquals(Nav(Tab.Chat), nav.back())
    }

    @Test
    fun aNotificationOpensTheAgentAboveTheChat() {
        val nav = Nav.agent("pc", "w2:p1")
        assertEquals(Dest.Detail(Route("pc", "${AGENT_PAGE}w2:p1"), 1, Tab.Chat), nav.dest)
        assertEquals(Nav(Tab.Chat), nav.back())
    }

    @Test
    fun theDebugPagesOpenTheirDestination() {
        assertEquals(Nav(Tab.Chat) to null, Nav.debug("chat", "pc"))
        assertEquals(Nav(Tab.Chat) to null, Nav.debug("inbox", "pc"))
        assertEquals(Nav(Tab.Chat) to null, Nav.debug("send", "pc"))
        assertEquals(Nav(Tab.Remote) to null, Nav.debug("control", "pc"))
        assertEquals(Nav(Tab.Computers) to null, Nav.debug("devices", "pc"))
        assertEquals(Nav(Tab.Chat, listOf(Route(null, SETTINGS_PAGE), Route(null, SYNC_PAGE))) to null, Nav.debug("sync", "pc"))
        assertEquals(Nav(Tab.Chat, listOf(Route(null, SETTINGS_PAGE), Route(null, ABOUT_PAGE))) to null, Nav.debug("about", "pc"))
        assertEquals("the old computer page is Remote with the computer in scope", Nav(Tab.Remote) to "pc", Nav.debug("home", "pc"))
        assertEquals(Nav(Tab.Chat, listOf(Route("pc", "camera:photo"))) to null, Nav.debug("camera:photo", "pc"))
        assertEquals(Nav(Tab.Remote, listOf(Route("pc", "camera:webcam"))) to null, Nav.debug("camera:webcam", "pc"))
        assertEquals(Nav(Tab.Remote, listOf(Route("pc", WEBCAM_PAGE))) to null, Nav.debug(WEBCAM_PAGE, "pc"))
        assertEquals(Nav(Tab.Chat, listOf(Route("pc", "browse"))) to null, Nav.debug("browse", "pc"))
        assertEquals(Nav(Tab.Remote, listOf(Route("pc", "media"))) to null, Nav.debug("media", "pc"))
        assertEquals(
            "an agent is a chat, so Back goes to the list of chats",
            Nav(Tab.Chat, listOf(Route("pc", "${AGENT_PAGE}w2:p1"))) to null,
            Nav.debug("${AGENT_PAGE}w2:p1", "pc"),
        )
        assertEquals(Nav.chat("pc") to null, Nav.debug("thread", "pc"))
        assertEquals(Nav(Tab.Chat, listOf(Route("pc", CHAT_TRAY_PAGE))) to null, Nav.debug("tray", "pc"))
        assertEquals(
            Nav(Tab.Remote, listOf(Route("pc", AGENTS_PAGE), Route("pc", NEW_PANE_PAGE))) to null,
            Nav.debug(NEW_PANE_PAGE, "pc"),
        )
        assertEquals("the prompt of a stream request shows over the chat", Nav(Tab.Chat) to null, Nav.debug("${ASK_PAGE}webcam", "pc"))
        assertEquals(Nav(Tab.Chat) to null, Nav.debug("${NOTIFY_PAGE}mic", "pc"))
    }

    @Test
    fun aStreamRequestOpensItsPageAboveTheCurrentScreen() {
        val webcam = Route("pc", streamPage(StreamKind.Webcam))
        assertEquals(Route("pc", WEBCAM_PAGE), webcam)
        assertEquals(Route("pc", MIC_PAGE), Route("pc", streamPage(StreamKind.Mic)))
        val agent = Nav(Tab.Remote, listOf(Route("pc", AGENTS_PAGE)))
        assertEquals(Nav(Tab.Remote, listOf(Route("pc", AGENTS_PAGE), webcam)), agent.open(webcam))
        assertEquals(Nav(Tab.Chat, listOf(webcam)), Nav().open(webcam))
        val open = Nav(Tab.Remote, listOf(webcam))
        assertEquals("the page that shows already stays", open, open.open(webcam))
        assertEquals(Nav(Tab.Remote, listOf(webcam, Route("desk", WEBCAM_PAGE))), open.open(Route("desk", WEBCAM_PAGE)))
    }

    @Test
    fun theSecondDestinationIsRemoteAndControlIsItsOldKey() {
        assertEquals("Remote", Tab.Remote.label)
        assertEquals(Tab.Remote, Tab.fromKey("remote"))
        assertEquals("a saved state with the old key opens Remote", Tab.Remote, Tab.fromKey("control"))
        assertEquals(Nav(Tab.Remote), Nav.restore(listOf("control")))
        assertEquals(Nav(Tab.Remote) to null, Nav.debug("remote", "pc"))
        assertEquals(Nav(Tab.Remote) to null, Nav.debug("control", "pc"))
        assertEquals(Nav(Tab.Remote, listOf(Route("pc", "media"))) to null, Nav.debug("media", "pc"))
        assertEquals(listOf("Chats", "Remote", "Computers"), Tab.entries.map { it.label })
    }

    @Test
    fun settingsLiesAboveChatsAndItsScreensAboveSettings() {
        val settings = Route(null, SETTINGS_PAGE)
        val (nav, scope) = Nav.debug("settings", "pc")
        assertEquals(Nav(Tab.Chat, listOf(settings)), nav)
        assertNull(scope)
        assertEquals(Dest.Detail(settings, 1, Tab.Chat), nav.dest)
        for (page in listOf(SYNC_PAGE, SSH_PAGE, ABOUT_PAGE)) {
            val above = Nav.debug(page, "pc").first
            assertEquals(listOf(settings, Route(null, page)), above.stack)
            assertEquals("Back goes to Settings, then to Chats", Nav(Tab.Chat, listOf(settings)), above.back())
        }
        assertEquals(Nav(Tab.Chat), nav.back())
        assertEquals("Settings has no computer, so it stays when a computer is gone", nav, nav.without { true })
        assertEquals(nav, Nav.restore(nav.save()))
    }
}
