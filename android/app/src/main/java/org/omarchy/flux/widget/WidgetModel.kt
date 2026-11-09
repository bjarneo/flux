package org.omarchy.flux.widget

import org.omarchy.flux.core.AgentRow
import org.omarchy.flux.core.AgentStatus
import org.omarchy.flux.core.ApprovalRow
import org.omarchy.flux.core.ApproveRequest
import org.omarchy.flux.core.ChatRow
import org.omarchy.flux.core.ComputerRow
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.PairRow
import org.omarchy.flux.core.SeenClock
import org.omarchy.flux.core.chatList
import org.omarchy.flux.theme.PaletteSpec
import kotlin.math.floor
import kotlin.math.max

/**
 * The model of the agents widget on the home screen. It has no Android
 * dependency, so the JVM tests run it. [AgentsWidgets] builds it from the
 * state of the app, and [widgetViews] draws it.
 */

/** The meaning of a status word and its dot. [WidgetColors] gives each tone its color. */
enum class WidgetTone {
    /** Needs the user: red. */
    Needs,

    /** Works: the accent, with a ring in the place of the dot. */
    Works,

    /** Done: green. */
    Done,

    /** Idle or unknown: the second ink, with a dim dot. */
    Quiet,
}

/** What a tap on a row opens. */
sealed interface WidgetTarget {
    /** Chats in the app, for example for a pair request. */
    data object Chats : WidgetTarget

    /** The approval screen of the request from the computer [computerId]. */
    data class Approval(val computerId: String) : WidgetTarget

    /** The chat of the agent in [pane] on the computer [deviceId]. */
    data class Agent(val deviceId: String, val pane: String) : WidgetTarget
}

/**
 * 1 row of the widget. [title] is the task of an agent or the question of
 * a request. [status] is the state word in the color of [tone]. [source] is
 * the computer data after it, such as the agent and the project. [computer]
 * names the computer. A row that [needs] the user takes the tile and a red
 * border, 2 dp when it is [strong].
 */
data class WidgetRow(
    val key: String,
    val title: String,
    val status: String,
    val tone: WidgetTone,
    val source: String,
    val computer: String,
    val needs: Boolean,
    val strong: Boolean,
    val target: WidgetTarget,
)

/** Why the widget shows no rows. Each state is quiet: it has no red and no fill. */
enum class WidgetQuiet {
    /** The user turned Flux off. */
    Off,

    /** No computer is paired. */
    Unpaired,

    /** The paired computers still connect after a start of the network. */
    Connecting,

    /** No paired computer is connected. */
    Offline,

    /** A computer is connected, and no agent runs and nothing needs the user. */
    NoAgents,
}

/**
 * What the widget shows. [rows] puts what needs the user first: the
 * approval, the pair requests, and the agents that wait for input. Then
 * the agents that work, the agents that are done, and the idle agents
 * follow. [needs] counts the rows that need the user. [quiet] is null
 * while rows show. [name] is the computer that a quiet line names, and
 * [lastSeen] is the time that Flux last saw it, or 0.
 */
data class WidgetModel(
    val rows: List<WidgetRow>,
    val needs: Int,
    val paired: Int,
    val online: Int,
    val quiet: WidgetQuiet?,
    val name: String = "",
    val lastSeen: Long = 0,
)

/** The state word of an agent, the same words as in the app. */
private fun statusWord(s: AgentStatus): String = when (s) {
    AgentStatus.Blocked -> "Needs input"
    AgentStatus.Done -> "Done"
    AgentStatus.Working -> "Working"
    AgentStatus.Idle -> "Idle"
    AgentStatus.Unknown -> "Unknown"
}

private fun toneOf(s: AgentStatus): WidgetTone = when (s) {
    AgentStatus.Blocked -> WidgetTone.Needs
    AgentStatus.Working -> WidgetTone.Works
    AgentStatus.Done -> WidgetTone.Done
    else -> WidgetTone.Quiet
}

private fun join(vararg parts: String): String = parts.filter { it.isNotBlank() }.joinToString(" · ")

/** The row of 1 chat of the Chats list, or null for a computer. */
private fun rowOf(r: ChatRow): WidgetRow? = when (r) {
    is ApprovalRow -> {
        val q = r.request
        WidgetRow(
            key = r.key,
            title = if (q.kind == ApproveRequest.Kind.Approve) "Approve ${q.service} on ${q.host}?" else "Enroll this phone on ${q.host}?",
            status = "Needs approval",
            tone = WidgetTone.Needs,
            source = join("user ${q.user}", q.tty),
            computer = q.computerName,
            needs = true,
            strong = true,
            target = WidgetTarget.Approval(q.computerId),
        )
    }
    is PairRow -> WidgetRow(
        key = r.key,
        title = "${r.computer} asks to pair",
        status = "Pair request",
        tone = WidgetTone.Needs,
        source = "",
        computer = r.computer,
        needs = true,
        strong = true,
        target = WidgetTarget.Chats,
    )
    is AgentRow -> {
        val a = r.agent
        WidgetRow(
            key = r.key,
            // An agent with no task shows its pane, as in the app.
            title = a.title.ifEmpty { a.pane },
            status = statusWord(a.status),
            tone = toneOf(a.status),
            source = join(a.agent, a.project.ifEmpty { a.workspace }),
            computer = r.computer,
            needs = a.status == AgentStatus.Blocked,
            strong = false,
            target = WidgetTarget.Agent(r.deviceId, a.pane),
        )
    }
    is ComputerRow -> null
}

/**
 * Builds the model from the [devices], the open [approval], and the
 * settings of the app. It uses [chatList], so the order is the order of
 * Chats. [seen] gives a time to a row that has no time of its own, at [now].
 * [connecting] is true while the computers still connect after a start.
 */
fun widgetModel(
    devices: List<DeviceUi>,
    approval: ApproveRequest?,
    enabled: Boolean,
    connecting: Boolean,
    seen: SeenClock,
    now: Long,
): WidgetModel {
    val paired = devices.filter { it.paired }
    val online = paired.filter { it.online }
    if (!enabled) return WidgetModel(emptyList(), 0, paired.size, 0, WidgetQuiet.Off)
    val list = chatList(devices, approval, emptyList(), seen, now)
    val rows = list.needs.mapNotNull(::rowOf) + list.agents.mapNotNull(::rowOf)
    val needs = rows.count { it.needs }
    val quiet = when {
        rows.isNotEmpty() -> null
        paired.isEmpty() -> WidgetQuiet.Unpaired
        online.isEmpty() -> if (connecting) WidgetQuiet.Connecting else WidgetQuiet.Offline
        else -> WidgetQuiet.NoAgents
    }
    // A quiet line names 1 computer: the only one, or the one that Flux saw last.
    val named = when (quiet) {
        WidgetQuiet.NoAgents -> online.singleOrNull()
        WidgetQuiet.Offline -> paired.maxByOrNull { it.lastSeen }
        WidgetQuiet.Connecting -> paired.singleOrNull()
        else -> null
    }
    return WidgetModel(rows, needs, paired.size, online.size, quiet, named?.name.orEmpty(), named?.lastSeen ?: 0L)
}

/** "1 needs you" or "3 need you", or empty when nothing needs the user. */
fun WidgetModel.needsText(): String = when (needs) {
    0 -> ""
    1 -> "1 needs you"
    else -> "$needs need you"
}

/**
 * The context line of the header after [needsText]. A [wide] widget also
 * shows how many computers are online. A narrow widget shows only what
 * needs the user, or the state. When [hidden] rows do not fit and no line
 * under the rows tells about them, the header tells it in the place of
 * the computers online.
 */
fun WidgetModel.contextText(wide: Boolean, hidden: Int = 0): String {
    val onlineText = if (hidden > 0) "$hidden more" else if (paired > 0) "$online of $paired online" else ""
    val state = when (quiet) {
        WidgetQuiet.Off -> "off"
        WidgetQuiet.Unpaired -> "not paired"
        WidgetQuiet.Connecting -> "connecting"
        WidgetQuiet.Offline -> "offline"
        WidgetQuiet.NoAgents, null -> if (needs > 0) "" else "nothing needs you"
    }
    if (!wide) return if (needs > 0) "" else if (hidden > 0) join(state, onlineText) else state
    return when {
        needs > 0 -> if (onlineText.isEmpty()) "" else " · $onlineText"
        quiet == WidgetQuiet.Off || quiet == WidgetQuiet.Unpaired -> state
        // The quiet title under the header tells the state.
        quiet != null -> onlineText
        else -> join(state, onlineText)
    }
}

/**
 * The title and the line of a quiet widget. [time] gives a time in
 * milliseconds since the epoch as "at 09:12" today, or else "on" and the date.
 */
fun WidgetModel.quietText(time: (Long) -> String): Pair<String, String> = when (quiet) {
    WidgetQuiet.Off -> "Flux is off" to "Open Flux to turn it on."
    WidgetQuiet.Unpaired -> "No computer is paired" to "Open Flux to pair this phone."
    WidgetQuiet.Connecting -> (if (name.isNotEmpty()) "Connecting to $name" else "Connecting to $paired computers") to ""
    WidgetQuiet.Offline -> "No computer is connected" to when {
        name.isEmpty() -> ""
        lastSeen > 0 -> "$name was last seen ${time(lastSeen)}."
        else -> "$name is not reachable."
    }
    WidgetQuiet.NoAgents -> "Nothing needs you" to (if (name.isNotEmpty()) "No agents run on $name." else "No agents run on $online computers.")
    null -> "" to ""
}

/** The text after a row is cut: "2 more in Chats". */
fun moreText(hidden: Int): String = "$hidden more in Chats"

/** What the widget shows, and its colors in the light and the dark mode of the phone. */
data class WidgetInput(val model: WidgetModel, val day: WidgetColors, val night: WidgetColors)

/**
 * The layout of the widget at 1 size: [wide] or narrow, the number of
 * [rows], and [more] when the line under the rows tells about the rest. A
 * [compact] widget shows only the state word under the task of a row.
 */
data class WidgetFit(val wide: Boolean, val rows: Int, val more: Boolean, val compact: Boolean = false)

/** The inset of the widget on each side, in dp. */
const val WIDGET_INSET_DP = 8f

/** The least height of the header, in dp. */
const val WIDGET_HEADER_DP = 36f

/** The space under the header, in dp. */
const val WIDGET_HEADER_GAP_DP = 2f

/** The least height of a row, in dp. It is the touch target of the app. */
const val WIDGET_ROW_DP = 48f

/** The space between 2 rows, in dp. */
const val WIDGET_ROW_GAP_DP = 4f

/** The height of the line that tells about more rows, in dp. */
const val WIDGET_MORE_DP = 24f

/** From this width in dp, the header shows its title and a row shows its computer at the end of its title. */
const val WIDGET_WIDE_DP = 240f

/** Below this width in dp, a row has no room for the source after the state word. */
const val WIDGET_COMPACT_DP = 180f

/** The most rows of 1 widget, so that the update stays small. */
const val WIDGET_MAX_ROWS = 12

/**
 * The layout of a widget of [widthDp] by [heightDp] with [total] rows.
 * [textScale] is the size of 12 sp text against 12 dp. It is the font
 * scale, but Android 14 and later grow large text less. A larger text
 * makes a row higher, so fewer rows fit, and the widget takes the narrow
 * and the compact forms at a larger width. When not all rows fit, a line
 * under the rows tells about the rest, but only when it costs no row.
 * Else the header tells about the rest, see [contextText].
 */
fun widgetFit(widthDp: Float, heightDp: Float, textScale: Float, total: Int): WidgetFit {
    val scale = max(textScale, 1f)
    // The header is 1 line of 15 sp. A row has a line of 14 sp and a line of 12 sp, 10 dp of padding, and a 2 dp gap.
    val header = max(WIDGET_HEADER_DP, 16f + 20f * scale)
    val row = max(WIDGET_ROW_DP, 12f + 35f * scale)
    val more = max(WIDGET_MORE_DP, 8f + 16f * scale)
    val room = heightDp - 2 * WIDGET_INSET_DP - header - WIDGET_HEADER_GAP_DP
    fun fit(h: Float): Int = max(0, floor((h + WIDGET_ROW_GAP_DP) / (row + WIDGET_ROW_GAP_DP)).toInt())
    val rows = fit(room).coerceAtMost(WIDGET_MAX_ROWS).coerceAtMost(total)
    val line = total > rows && rows > 0 && fit(room - more) >= rows
    val textWidth = widthDp / scale
    return WidgetFit(wide = textWidth >= WIDGET_WIDE_DP, rows = rows, more = line, compact = textWidth < WIDGET_COMPACT_DP)
}

/**
 * The colors of the widget, from the roles of 1 palette. The contrast
 * guard of [org.omarchy.flux.theme.paletteOf] makes each ink read on each
 * ground: each of [inks] reaches 4.5:1 on each of [grounds], and each of
 * [marks] reaches 3:1. The widget uses no other pair.
 */
data class WidgetColors(
    /** The widget: the page of the theme. */
    val ground: Int,
    /** A row that needs the user. */
    val tile: Int,
    val text: Int,
    val sub: Int,
    /** The dot of an idle agent and the mark of a quiet widget. It is never text. */
    val dim: Int,
    val red: Int,
    val accent: Int,
    val green: Int,
) {
    /** The color of the state word of [t]. */
    fun ink(t: WidgetTone): Int = when (t) {
        WidgetTone.Needs -> red
        WidgetTone.Works -> accent
        WidgetTone.Done -> green
        WidgetTone.Quiet -> sub
    }

    /** The color of the dot of [t]. */
    fun dot(t: WidgetTone): Int = if (t == WidgetTone.Quiet) dim else ink(t)

    val grounds: List<Int> get() = listOf(ground, tile)
    val inks: List<Int> get() = listOf(text, sub, red, accent, green)
    val marks: List<Int> get() = listOf(text, red, accent, green, dim)

    companion object {
        fun of(p: PaletteSpec) = WidgetColors(p.bg, p.tile, p.text, p.sub, p.dim, p.red, p.accent, p.green)
    }
}
