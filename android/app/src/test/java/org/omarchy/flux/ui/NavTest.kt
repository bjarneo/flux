package org.omarchy.flux.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NavTest {
    @Test
    fun backPopsThenGoesToTheInboxThenLeaves() {
        val agents = Route("pc", AGENTS_PAGE)
        val agent = Route("pc", "${AGENT_PAGE}w2:p1")
        var nav: Nav? = Nav(Tab.Control, listOf(agents, agent))
        assertEquals(Dest.Detail(agent, 2, Tab.Control), nav!!.dest)
        nav = nav.back()
        assertEquals(Dest.Detail(agents, 1, Tab.Control), nav!!.dest)
        nav = nav.back()
        assertEquals(Dest.Root(Tab.Control), nav!!.dest)
        nav = nav.back()
        assertEquals(Dest.Root(Tab.Inbox), nav!!.dest)
        assertNull("Back on the Inbox leaves the app", nav.back())
    }

    @Test
    fun aDestinationOpensAtItsRoot() {
        val nav = Nav(Tab.Send, listOf(Route("pc", "browse")))
        assertEquals(Nav(Tab.Computers), nav.select(Tab.Computers))
        assertEquals(Nav(Tab.Send), nav.select(Tab.Send))
    }

    @Test
    fun aNewPaneReplacesItsPage() {
        val nav = Nav(Tab.Control, listOf(Route("pc", AGENTS_PAGE), Route("pc", NEW_PANE_PAGE)))
        val next = nav.replaceTop(Route("pc", "${TERMINAL_PAGE}w1:p3"))
        assertEquals(listOf(Route("pc", AGENTS_PAGE), Route("pc", "${TERMINAL_PAGE}w1:p3")), next.stack)
    }

    @Test
    fun theStateSurvivesARecreation() {
        val nav = Nav(Tab.Computers, listOf(Route(null, SYNC_PAGE), Route("pc", "media")))
        assertEquals(nav, Nav.restore(nav.save()))
        assertEquals(Nav(), Nav.restore(emptyList()))
        assertEquals(Nav(), Nav.restore(listOf("unknown")))
    }

    @Test
    fun theScreensOfAComputerThatIsGoneClose() {
        val nav = Nav(Tab.Control, listOf(Route("pc", AGENTS_PAGE), Route("pc", "${AGENT_PAGE}w1:p1")))
        assertEquals(Nav(Tab.Control), nav.without { it == "pc" })
        assertEquals(nav, nav.without { it == "other" })
        val sync = Nav(Tab.Computers, listOf(Route(null, SYNC_PAGE)))
        assertEquals(sync, sync.without { true })
    }

    @Test
    fun aNotificationOpensTheAgentAboveTheInbox() {
        val nav = Nav.agent("pc", "w2:p1")
        assertEquals(Dest.Detail(Route("pc", "${AGENT_PAGE}w2:p1"), 1, Tab.Inbox), nav.dest)
        assertEquals(Nav(Tab.Inbox), nav.back())
    }

    @Test
    fun theDebugPagesOpenTheirDestination() {
        assertEquals(Nav(Tab.Inbox) to null, Nav.debug("inbox", "pc"))
        assertEquals(Nav(Tab.Send) to null, Nav.debug("send", "pc"))
        assertEquals(Nav(Tab.Control) to null, Nav.debug("control", "pc"))
        assertEquals(Nav(Tab.Computers) to null, Nav.debug("devices", "pc"))
        assertEquals(Nav(Tab.Computers, listOf(Route(null, SYNC_PAGE))) to null, Nav.debug("sync", "pc"))
        assertEquals("the old computer page is Control with the computer in scope", Nav(Tab.Control) to "pc", Nav.debug("home", "pc"))
        assertEquals(Nav(Tab.Send, listOf(Route("pc", "camera:photo"))) to null, Nav.debug("camera:photo", "pc"))
        assertEquals(Nav(Tab.Control, listOf(Route("pc", "camera:webcam"))) to null, Nav.debug("camera:webcam", "pc"))
        assertEquals(Nav(Tab.Control, listOf(Route("pc", WEBCAM_PAGE))) to null, Nav.debug(WEBCAM_PAGE, "pc"))
        assertEquals(Nav(Tab.Send, listOf(Route("pc", "browse"))) to null, Nav.debug("browse", "pc"))
        assertEquals(Nav(Tab.Control, listOf(Route("pc", "media"))) to null, Nav.debug("media", "pc"))
        assertEquals(
            Nav(Tab.Control, listOf(Route("pc", AGENTS_PAGE), Route("pc", "${AGENT_PAGE}w2:p1"))) to null,
            Nav.debug("${AGENT_PAGE}w2:p1", "pc"),
        )
        assertEquals(
            Nav(Tab.Control, listOf(Route("pc", AGENTS_PAGE), Route("pc", NEW_PANE_PAGE))) to null,
            Nav.debug(NEW_PANE_PAGE, "pc"),
        )
    }
}
