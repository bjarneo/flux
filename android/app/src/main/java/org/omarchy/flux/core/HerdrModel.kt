package org.omarchy.flux.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import org.omarchy.flux.protocol.bodyOf
import org.omarchy.flux.protocol.bool
import org.omarchy.flux.protocol.long
import org.omarchy.flux.protocol.str

/**
 * The status of a herdr agent. [Blocked] waits for an approval or an
 * answer. [Idle] and [Done] are both ready for input. The order of the
 * entries is the sort order of the Agents screen.
 */
enum class AgentStatus(val wire: String) {
    Blocked("blocked"),
    Done("done"),
    Working("working"),
    Idle("idle"),
    Unknown("unknown");

    /** True when the agent is ready for input. */
    val ready: Boolean get() = this == Done || this == Idle

    companion object {
        /** Returns the status for a wire value. An unknown value gives [Unknown]. */
        fun from(value: String?): AgentStatus = entries.firstOrNull { it.wire == value } ?: Unknown
    }
}

/** One coding agent in a herdr pane on a computer. [pane] is the herdr pane ID, for example w5:p1. */
data class HerdrAgent(
    val pane: String,
    val agent: String,
    val status: AgentStatus,
    val title: String = "",
    val project: String = "",
    val workspace: String = "",
)

/** A herdr pane without an agent: a terminal. [title] is the terminal title, which a shell often sets to the command. */
data class HerdrTerminal(
    val pane: String,
    val title: String = "",
    val project: String = "",
    val workspace: String = "",
)

/** A herdr workspace that can get a new tab. [cwd] is the folder of its active tab on the computer. */
data class HerdrWorkspace(val id: String, val label: String, val cwd: String = "")

/**
 * What a computer reports about herdr. [enabled] is false when the computer
 * has `herdr = false` in its config.toml. [running] is true when fluxd
 * reaches the herdr server. [control] is true when the computer accepts
 * replies from this phone, and new agents. [terminals] is true when the
 * computer also opens terminals for this phone and lists them in [panes].
 * [workspaces] and [kinds] are the places and the agent kinds for a new
 * agent.
 */
data class HerdrState(
    val enabled: Boolean,
    val running: Boolean,
    val agents: List<HerdrAgent>,
    val control: Boolean = false,
    val terminals: Boolean = false,
    val panes: List<HerdrTerminal> = emptyList(),
    val workspaces: List<HerdrWorkspace> = emptyList(),
    val kinds: List<String> = emptyList(),
    val review: Boolean = false,
    /** The terminal-session actions of the herdr bridge, such as "observe" and "control". */
    val bridge: List<String> = emptyList(),
) {
    /** The agents with [AgentStatus.Blocked] first, then done, working, idle, and unknown. */
    val sorted: List<HerdrAgent> get() = sortAgents(agents)

    val blocked: Int get() = agents.count { it.status == AgentStatus.Blocked }

    /** True when the herdr bridge can stream the terminal of a pane. */
    val terminalStream: Boolean get() = "observe" in bridge

    fun agent(pane: String): HerdrAgent? = agents.firstOrNull { it.pane == pane }

    fun terminal(pane: String): HerdrTerminal? = panes.firstOrNull { it.pane == pane }
}

/**
 * The recent output of one pane. [lines] keep the terminal colors, and
 * [text] is the same output without styles. [loading] is true while a read
 * waits for its answer. The old lines stay on screen until the new lines
 * come.
 */
data class HerdrOutput(
    val pane: String,
    val loading: Boolean = true,
    val lines: List<TermLine> = emptyList(),
    val truncated: Boolean = false,
    val error: String? = null,
    val request: Long? = null,
    val view: String = "ansi",
    val path: String = "",
) {
    val text: String = lines.joinToString("\n") { it.text }

    /** The numbered choices of the dialog at the end of the output. */
    val choices: List<AgentChoice> by lazy { findChoices(lines.map { it.text }) }
}

/**
 * True when the choices of [out] take a tap. The choices take no tap while
 * a reply is [sending]. After an answer to the output [answered], the
 * choices wait for the next output that is not loading. Thus a second tap
 * does not answer the next question.
 */
fun choicesOpen(out: HerdrOutput?, answered: HerdrOutput?, sending: Boolean): Boolean =
    !sending && (answered == null || (out !== answered && out?.loading == false))

/**
 * The last reply to a pane. [action] is "keys" or "prompt". [sending] is
 * true until the computer answers. [seq] is different for each reply, so
 * the UI sees each answer. [code] is the code of the [error], such as
 * [HERDR_BLOCKED], or null.
 */
data class HerdrReply(
    val pane: String,
    val action: String,
    val seq: Long,
    val sending: Boolean = true,
    val error: String? = null,
    val code: String? = null,
)

/**
 * The answer of the computer to a reply: `{"kind":"sent"}`. [error] is null
 * on success. [request] is the number of the reply, or null from a fluxd
 * that does not send it back. [code] names the kind of error, such as
 * [HERDR_BLOCKED], or it is null.
 */
data class HerdrSent(val pane: String, val action: String, val error: String?, val request: Long? = null, val code: String? = null) {
    /**
     * True when this is the answer to [reply], while the reply waits. A newer
     * fluxd sends back the number of the reply, and only that reply matches.
     * An older fluxd sends no number, so the pane and the action must match.
     */
    fun answers(reply: HerdrReply): Boolean {
        if (reply.pane != pane || !reply.sending) return false
        // A late answer to an earlier reply does not end this reply.
        if (action.isNotEmpty() && action != reply.action) return false
        return request == null || request == reply.seq
    }
}

/**
 * The code of a sent answer when fluxd refused a prompt, because the agent
 * waits for a choice. The same text can go again as the answer, see
 * [herdrPromptBody].
 */
const val HERDR_BLOCKED = "blocked"

/**
 * The body of a prompt to the agent in [pane]. fluxd refuses a prompt to
 * an agent that waits for a choice. With [answer], fluxd types [text] as
 * the answer to that agent instead.
 */
fun herdrPromptBody(pane: String, text: String, answer: Boolean): JsonObject {
    val fields = listOf<Pair<String, Any?>>("kind" to "prompt", "pane" to pane, "text" to text) + if (answer) listOf("answer" to true) else emptyList()
    return bodyOf(*fields.toTypedArray())
}

/**
 * The last new agent, new terminal, or close from this phone. [action] is
 * "create" or "close". [pane] is the new or closed pane, and it is null
 * until the computer reports it. [sending] is true until the computer
 * answers. [seq] is different for each action, so the UI sees each answer.
 */
data class HerdrAction(
    val action: String,
    val seq: Long,
    val sending: Boolean = true,
    val pane: String? = null,
    val what: String = "",
    val error: String? = null,
)

/**
 * The answer of the computer to a create or a close: `{"kind":"created"}` or
 * `{"kind":"closed"}`. [what] is "agent" or "terminal" for a create.
 * [request] is the number of the action, or null from a fluxd that does not
 * send it back.
 */
data class HerdrDone(val action: String, val pane: String?, val error: String?, val what: String = "", val request: Long? = null) {
    /**
     * True when this is the answer to [started], while it waits. A newer
     * fluxd sends back the number of the action, and only that action
     * matches. An older fluxd sends no number, so the kind, the closed
     * pane, and the kind of the new pane must match.
     */
    fun answers(started: HerdrAction): Boolean {
        if (started.action != action || !started.sending) return false
        if (action == "close" && started.pane != pane) return false
        // A late answer to an earlier create does not end this one.
        if (action == "create" && what.isNotEmpty() && started.what.isNotEmpty() && what != started.what) return false
        return request == null || request == started.seq
    }
}

/** Sorts by status in the order of [AgentStatus]. The sort is stable, so herdr order stays inside a group. */
fun sortAgents(agents: List<HerdrAgent>): List<HerdrAgent> = agents.sortedBy { it.status.ordinal }

/** Parses the body of a state packet. It returns null for a body that is not a state. */
fun parseHerdrState(body: JsonObject): HerdrState? {
    if (body.str("kind") != "state") return null
    val agents = (body["agents"] as? JsonArray).orEmpty().mapNotNull { e ->
        val o = e as? JsonObject ?: return@mapNotNull null
        val pane = o.str("pane")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
        HerdrAgent(
            pane = pane,
            agent = o.str("agent").orEmpty().ifEmpty { "agent" },
            status = AgentStatus.from(o.str("status")),
            title = o.str("title").orEmpty(),
            project = o.str("project").orEmpty(),
            workspace = o.str("workspace").orEmpty(),
        )
    }
    val panes = (body["panes"] as? JsonArray).orEmpty().mapNotNull { e ->
        val o = e as? JsonObject ?: return@mapNotNull null
        val pane = o.str("pane")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
        HerdrTerminal(pane, o.str("title").orEmpty(), o.str("project").orEmpty(), o.str("workspace").orEmpty())
    }
    val workspaces = (body["workspaces"] as? JsonArray).orEmpty().mapNotNull { e ->
        val o = e as? JsonObject ?: return@mapNotNull null
        val id = o.str("id")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
        HerdrWorkspace(id, o.str("label").orEmpty().ifEmpty { id }, o.str("cwd").orEmpty())
    }
    val kinds = (body["kinds"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.takeIf { k -> k.isNotEmpty() } }
    val bridge = (body["bridge"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.takeIf { k -> k.isNotEmpty() } }
    val enabled = body.bool("enabled") ?: true
    val control = enabled && (body.bool("control") ?: false)
    val terminals = control && (body.bool("terminals") ?: false)
    return HerdrState(
        enabled = enabled,
        running = enabled && (body.bool("running") ?: false),
        agents = agents,
        control = control,
        terminals = terminals,
        panes = if (terminals) panes else emptyList(),
        workspaces = if (control) workspaces else emptyList(),
        kinds = if (control) kinds else emptyList(),
        review = enabled && (body.bool("review") ?: false),
        bridge = bridge,
    )
}

/** The longest output text that the phone reads, in characters. fluxd sends at most 1 MiB. */
const val HERDR_MAX_TEXT = 1 shl 20

/**
 * The most output lines that the phone keeps: the lines of a read and the
 * rows of the screen that fluxd puts under them.
 */
const val HERDR_MAX_LINES = 2 * HERDR_READ_LINES

/**
 * Parses the body of an output packet. It returns null for a body that is
 * not an output. It keeps the end of a text that is longer than
 * [HERDR_MAX_TEXT] or has more than [HERDR_MAX_LINES] lines.
 */
fun parseHerdrOutput(body: JsonObject): HerdrOutput? {
    if (body.str("kind") != "output") return null
    val pane = body.str("pane")?.takeIf { it.isNotEmpty() } ?: return null
    val error = body.str("error")?.takeIf { it.isNotEmpty() }
    var text = if (error == null) body.str("text").orEmpty() else ""
    var cut = false
    if (text.length > HERDR_MAX_TEXT) {
        // Start after a line break, so that the first line is whole.
        val tail = text.substring(text.length - HERDR_MAX_TEXT)
        val nl = tail.indexOf('\n')
        text = if (nl >= 0 && nl < tail.length - 1) tail.substring(nl + 1) else tail
        cut = true
    }
    if (!cut && text.count { it == '\n' } >= HERDR_MAX_LINES) cut = true
    // An older fluxd sends plain text. It has no escape sequences, so the
    // same parser reads it.
    return HerdrOutput(
        pane = pane,
        loading = false,
        lines = if (error == null) tidyLines(parseAnsi(text, HERDR_MAX_LINES)) else emptyList(),
        truncated = (body.bool("truncated") ?: false) || cut,
        error = error,
        request = body.long("request"),
        view = body.str("view") ?: "ansi",
        path = body.str("path").orEmpty(),
    )
}

/** Parses the body of a created or closed packet. It returns null for another body. */
fun parseHerdrDone(body: JsonObject): HerdrDone? {
    val action = when (body.str("kind")) {
        "created" -> "create"
        "closed" -> "close"
        else -> return null
    }
    return HerdrDone(
        action, body.str("pane")?.takeIf { it.isNotEmpty() }, body.str("error")?.takeIf { it.isNotEmpty() },
        body.str("what").orEmpty(), body.long("request"),
    )
}

/** Parses the body of a sent packet. It returns null for a body that is not a sent answer. */
fun parseHerdrSent(body: JsonObject): HerdrSent? {
    if (body.str("kind") != "sent") return null
    val pane = body.str("pane")?.takeIf { it.isNotEmpty() } ?: return null
    return HerdrSent(
        pane, body.str("action").orEmpty(), body.str("error")?.takeIf { it.isNotEmpty() }, body.long("request"),
        body.str("code")?.takeIf { it.isNotEmpty() },
    )
}

/**
 * One terminal-session stream of a pane: the live terminal of the pane
 * on the computer. [mode] is "observe" for a stream that only shows the
 * terminal, and "control" for one that also sends gestures and keys.
 * [session] names the stream after the computer opened it, and [width]
 * and [height] are its terminal cells, which are the cells that the pane
 * has on the computer. [sending] is true while the open waits for its
 * answer, [open] is true while the stream runs, and [error] is why the
 * open failed. [code] and [reason] are how the stream ended, such as
 * "released", "bridge", or "agent_ended".
 */
data class HerdrTerminalSession(
    val pane: String,
    val mode: String,
    val request: Long = 0,
    val sending: Boolean = true,
    val session: String = "",
    val width: Int = 0,
    val height: Int = 0,
    val open: Boolean = false,
    val error: String? = null,
    val code: String = "",
    val reason: String = "",
)

/** One event of a terminal session, in the order that the computer sent it. */
sealed class HerdrTerminalEvent {
    /** The stream opened with this grid of terminal cells. */
    data class Opened(val session: String, val width: Int, val height: Int) : HerdrTerminalEvent()

    /** One frame of the terminal screen: base64 ANSI bytes. */
    data class Frame(
        val session: String,
        val seq: Long,
        val width: Int,
        val height: Int,
        val bytes: String,
        val full: Boolean = false,
    ) : HerdrTerminalEvent()

    /** The stream ended. */
    data class Closed(val session: String, val code: String, val reason: String) : HerdrTerminalEvent()
}

/**
 * True when a terminal_opened answers an open that the phone does not
 * wait for any more: its screen is gone, watches another pane, or the
 * answer is older than the current open. The caller releases such a
 * session at once, so its stream never runs for nobody.
 */
fun staleTerminalAnswer(waiting: HerdrTerminalSession?, opened: HerdrTerminalSession): Boolean {
    if (waiting == null || waiting.pane != opened.pane) return true
    return waiting.request != 0L && opened.request != 0L && waiting.request != opened.request
}

/**
 * Parses the body of a terminal_opened packet: the answer to a
 * terminal_open. It returns null for another body. The answer with an
 * [HerdrTerminalSession.error] refused the open.
 */
fun parseHerdrTerminalOpened(body: JsonObject): HerdrTerminalSession? {
    if (body.str("kind") != "terminal_opened") return null
    val pane = body.str("pane")?.takeIf { it.isNotEmpty() } ?: return null
    val error = body.str("error")?.takeIf { it.isNotEmpty() }
    val session = body.str("session").orEmpty()
    return HerdrTerminalSession(
        pane = pane,
        mode = body.str("mode").orEmpty().ifEmpty { "observe" },
        request = body.long("request") ?: 0,
        sending = false,
        session = session,
        width = body.long("width")?.toInt() ?: 0,
        height = body.long("height")?.toInt() ?: 0,
        open = error == null && session.isNotEmpty(),
        error = error,
    )
}

/**
 * True while the terminal session that [opened] created still belongs to
 * the current link. A stream belongs to the link that opened it: the
 * computer ends it with that link, so a dropped or replaced link never
 * keeps its session, whatever name the session has.
 */
fun terminalSurvivesLinkChange(opened: Any?, current: Any?): Boolean =
    opened != null && opened === current

/**
 * True when the terminal screen asked for a session and the computer now
 * shows none while the unlock is still valid. That happens when a new
 * link replaces the old one: the computer drops the session of the old
 * link, which the screen may never have observed. The first open has not
 * asked yet, so it must not count as a loss.
 */
fun terminalSessionLost(session: HerdrTerminalSession?, wanted: Boolean, authorized: Boolean): Boolean =
    authorized && wanted && session == null

/**
 * True while [session] is a released session whose terminal_closed has not
 * arrived. The phone waits for that event before it opens a new stream on
 * the same pane, because the computer keeps one controller per pane. A
 * session without an ID, one that already got its reason, or one that the
 * lost link dropped does not wait.
 */
fun terminalClosePending(session: HerdrTerminalSession?): Boolean =
    session != null && session.code == "released" &&
        session.reason.isEmpty() && session.session.isNotEmpty()

/** Show only an authorized control stream whose own baseline finished drawing. */
fun terminalControlReady(
    session: HerdrTerminalSession?, drawn: String, authorized: Boolean, active: Boolean,
): Boolean = active && authorized && session != null && session.open && !session.sending &&
    session.mode == "control" && session.session.isNotEmpty() && drawn == session.session

/** Parses the body of a terminal_frame packet. It returns null for another body. */
fun parseHerdrTerminalFrame(body: JsonObject): HerdrTerminalEvent.Frame? {
    if (body.str("kind") != "terminal_frame") return null
    val session = body.str("session")?.takeIf { it.isNotEmpty() } ?: return null
    val bytes = body.str("bytes") ?: return null
    return HerdrTerminalEvent.Frame(
        session, body.long("seq") ?: 0, body.long("width")?.toInt() ?: 0,
        body.long("height")?.toInt() ?: 0, bytes, body.bool("full") == true,
    )
}

/** Parses the body of a terminal_closed packet. It returns null for another body. */
fun parseHerdrTerminalClosed(body: JsonObject): HerdrTerminalEvent.Closed? {
    if (body.str("kind") != "terminal_closed") return null
    val session = body.str("session")?.takeIf { it.isNotEmpty() } ?: return null
    return HerdrTerminalEvent.Closed(
        session, body.str("code").orEmpty(), body.str("reason").orEmpty(),
    )
}

/**
 * The body of a terminal_open: a stream of [mode] on [pane]. A control
 * stream may name the terminal size it wants in cells; 0 keeps the size
 * of the pane on the computer.
 */
fun herdrTerminalOpenBody(pane: String, mode: String, request: Long, cols: Int = 0, rows: Int = 0): JsonObject =
    bodyOf(
        "kind" to "terminal_open", "pane" to pane, "mode" to mode, "request" to request,
        "cols" to cols, "rows" to rows,
    )

/** The body of a terminal_release of [session]. */
fun herdrTerminalReleaseBody(session: String, request: Long): JsonObject =
    bodyOf("kind" to "terminal_release", "session" to session, "request" to request)

/** The body of one wheel step at the zero-based cell ([column], [row]). */
fun herdrTerminalScrollBody(session: String, direction: String, column: Int, row: Int): JsonObject =
    bodyOf(
        "kind" to "terminal_scroll", "session" to session, "direction" to direction,
        "column" to column, "row" to row,
    )

/** The body of one pointer event at the zero-based cell ([column], [row]). */
fun herdrTerminalMouseBody(session: String, action: String, button: String, column: Int, row: Int): JsonObject =
    bodyOf(
        "kind" to "terminal_mouse", "session" to session, "action" to action, "button" to button,
        "column" to column, "row" to row,
    )

/** The key names that fluxd accepts in a keys packet. */
val HERDR_KEYS: Set<String> = setOf("enter", "esc", "tab", "shift+tab", "up", "down", "left", "right", "backspace", "space", "y", "n") +
    (0..9).map { it.toString() }

/** The key names that fluxd accepts in an input packet for a terminal. */
val HERDR_TERMINAL_KEYS: Set<String> = setOf("enter", "esc", "tab", "shift+tab", "up", "down", "left", "right", "backspace", "space") +
    ('a'..'z').map { "ctrl+$it" }

/** The most keys in 1 keys packet. */
const val HERDR_MAX_KEYS = 8

/** The longest prompt, in UTF-8 bytes. */
const val HERDR_MAX_PROMPT = 16 * 1024

/** A notification change for one pane that [HerdrTracker] finds. */
sealed interface AgentAlert {
    val pane: String

    /** The agent waits for an approval or an answer. */
    data class NeedsInput(val agent: HerdrAgent) : AgentAlert {
        override val pane: String get() = agent.pane
    }

    /** The agent stopped working and is ready for input. The phone waits a moment before it posts this. */
    data class Finished(val agent: HerdrAgent) : AgentAlert {
        override val pane: String get() = agent.pane
    }

    /** The notification of the pane is no longer true. */
    data class Clear(override val pane: String) : AgentAlert
}

/**
 * Finds the status changes of the agents on one computer. The first state
 * after a connection only sets the start values, so it posts nothing. The
 * core lock guards it.
 */
class HerdrTracker {
    private val last = LinkedHashMap<String, AgentStatus>()
    private var fresh = true

    /** Makes the next state set the start values. Call it when the computer connects. */
    fun restart() {
        fresh = true
    }

    /** Takes a new agent list and returns the notification changes. */
    fun update(agents: List<HerdrAgent>): List<AgentAlert> {
        val out = ArrayList<AgentAlert>()
        val seen = HashSet<String>()
        for (a in agents) {
            seen += a.pane
            val prev = last[a.pane]
            // An unknown status gives no information. The last known status stays.
            if (a.status == AgentStatus.Unknown) continue
            last[a.pane] = a.status
            if (fresh) {
                if (a.status == AgentStatus.Working) out += AgentAlert.Clear(a.pane)
                continue
            }
            when {
                prev == a.status -> Unit
                a.status == AgentStatus.Blocked -> if (prev != null) out += AgentAlert.NeedsInput(a)
                a.status.ready && prev == AgentStatus.Working -> out += AgentAlert.Finished(a)
                prev != null -> out += AgentAlert.Clear(a.pane)
            }
        }
        val gone = last.keys.filter { it !in seen }
        for (pane in gone) {
            last.remove(pane)
            out += AgentAlert.Clear(pane)
        }
        fresh = false
        return out
    }
}
