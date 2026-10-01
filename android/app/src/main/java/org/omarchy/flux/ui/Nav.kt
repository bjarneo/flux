package org.omarchy.flux.ui

/** The 4 destinations of the navigation bar. [key] is also the debug page name. */
enum class Tab(val key: String, val label: String) {
    Inbox("inbox", "Inbox"),
    Send("send", "Send"),
    Control("control", "Control"),
    Computers("computers", "Computers");

    companion object {
        fun fromKey(key: String?): Tab = entries.firstOrNull { it.key == key } ?: Inbox
    }
}

/**
 * One screen above a destination. [deviceId] is the computer of the screen,
 * or null for a screen of the app, such as [SYNC_PAGE].
 */
data class Route(val deviceId: String?, val page: String)

/**
 * What the screen shows: a destination, or a screen above it at [depth] 1
 * or more. [tab] is the destination, or the destination under the screen.
 */
sealed interface Dest {
    val depth: Int
    val tab: Tab

    data class Root(override val tab: Tab) : Dest {
        override val depth: Int get() = 0
    }

    data class Detail(val route: Route, override val depth: Int, override val tab: Tab) : Dest
}

/** The page prefix of the screen of one agent. The herdr pane ID follows it. */
const val AGENT_PAGE = "agent:"

/** The page prefix of the screen of one herdr terminal. The pane ID follows it. */
const val TERMINAL_PAGE = "terminal:"

/** The page that starts a herdr agent or opens a terminal. */
const val NEW_PANE_PAGE = "newpane"

/** The page with the agents and terminals of a computer. */
const val AGENTS_PAGE = "agents"

/** The Omarchy panel: workspaces, windows, and key bindings. */
const val OMARCHY_PAGE = "omarchy"

/** The webcam of 1 computer, in the Stream band of Control. */
const val WEBCAM_PAGE = "webcam"

/** The sync switches. They apply to every computer, so the page has no computer. */
const val SYNC_PAGE = "sync"

/**
 * The navigation state: the destination [tab] and the screens above it.
 * System Back pops a screen, then goes to the Inbox, then leaves the app.
 */
data class Nav(val tab: Tab = Tab.Inbox, val stack: List<Route> = emptyList()) {
    val dest: Dest get() = stack.lastOrNull()?.let { Dest.Detail(it, stack.size, tab) } ?: Dest.Root(tab)

    fun push(r: Route): Nav = copy(stack = stack + r)

    /** Replaces the top screen, so that Back skips the old one. */
    fun replaceTop(r: Route): Nav = copy(stack = stack.dropLast(1) + r)

    /** Opens a destination. A tap on the open destination goes back to its root. */
    fun select(t: Tab): Nav = Nav(t)

    /** The state after Back, or null when Back leaves the app. */
    fun back(): Nav? = when {
        stack.isNotEmpty() -> copy(stack = stack.dropLast(1))
        tab != Tab.Inbox -> Nav(Tab.Inbox)
        else -> null
    }

    /** Drops the screens of computers that are gone or no longer paired. */
    fun without(gone: (String) -> Boolean): Nav {
        val keep = stack.takeWhile { it.deviceId == null || !gone(it.deviceId) }
        return if (keep.size == stack.size) this else copy(stack = keep)
    }

    /** The state as a flat list for a saved instance state: the tab, then pairs of the device ID and the page. */
    fun save(): List<String> = listOf(tab.key) + stack.flatMap { listOf(it.deviceId.orEmpty(), it.page) }

    companion object {
        fun restore(saved: List<String>): Nav {
            if (saved.isEmpty()) return Nav()
            val stack = saved.drop(1).chunked(2).filter { it.size == 2 }.map { (id, page) -> Route(id.ifEmpty { null }, page) }
            return Nav(Tab.fromKey(saved[0]), stack)
        }

        /** The destination that holds a page of a computer, so that Back goes there. */
        fun tabOf(page: String): Tab = when {
            page == "browse" || page.startsWith("camera") && !page.endsWith(":webcam") -> Tab.Send
            else -> Tab.Control
        }

        /** The navigation of a notification that opens an agent. Back goes to the Inbox. */
        fun agent(deviceId: String, pane: String): Nav = Nav(Tab.Inbox, listOf(Route(deviceId, "$AGENT_PAGE$pane")))

        /**
         * The navigation for a debug page name, see the Test section of
         * docs/android.md. [deviceId] is the computer for the pages of a
         * computer. It returns the state and the computer for the scope.
         */
        fun debug(page: String, deviceId: String): Pair<Nav, String?> = when (page) {
            "inbox", "ring" -> Nav(Tab.Inbox) to null
            "send" -> Nav(Tab.Send) to null
            "control" -> Nav(Tab.Control) to null
            "computers", "devices", "pair", "unpair" -> Nav(Tab.Computers) to null
            SYNC_PAGE -> Nav(Tab.Computers, listOf(Route(null, SYNC_PAGE))) to null
            // The old computer page is now the Control destination of 1 computer.
            "home" -> Nav(Tab.Control) to deviceId
            else -> {
                val agents = Route(deviceId, AGENTS_PAGE)
                val stack = when {
                    page.startsWith(AGENT_PAGE) || page.startsWith(TERMINAL_PAGE) || page == NEW_PANE_PAGE -> listOf(agents, Route(deviceId, page))
                    else -> listOf(Route(deviceId, page))
                }
                Nav(tabOf(page), stack) to null
            }
        }
    }
}
