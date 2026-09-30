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
) {
    /** The agents with [AgentStatus.Blocked] first, then done, working, idle, and unknown. */
    val sorted: List<HerdrAgent> get() = sortAgents(agents)

    val blocked: Int get() = agents.count { it.status == AgentStatus.Blocked }

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
) {
    val text: String = lines.joinToString("\n") { it.text }

    /** The numbered choices of the dialog at the end of the output. */
    val choices: List<AgentChoice> by lazy { findChoices(lines.map { it.text }) }
}

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
