package org.omarchy.flux.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import org.omarchy.flux.protocol.bool
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

/**
 * What a computer reports about herdr. [enabled] is false when the computer
 * has `herdr = false` in its config.toml. [running] is true when fluxd
 * reaches the herdr server. [control] is true when the computer accepts
 * replies from this phone.
 */
data class HerdrState(
    val enabled: Boolean,
    val running: Boolean,
    val agents: List<HerdrAgent>,
    val control: Boolean = false,
) {
    /** The agents with [AgentStatus.Blocked] first, then done, working, idle, and unknown. */
    val sorted: List<HerdrAgent> get() = sortAgents(agents)

    val blocked: Int get() = agents.count { it.status == AgentStatus.Blocked }

    fun agent(pane: String): HerdrAgent? = agents.firstOrNull { it.pane == pane }
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
 * the UI sees each answer.
 */
data class HerdrReply(
    val pane: String,
    val action: String,
    val seq: Long,
    val sending: Boolean = true,
    val error: String? = null,
)

/** The answer of the computer to a reply: `{"kind":"sent"}`. [error] is null on success. */
data class HerdrSent(val pane: String, val action: String, val error: String?)

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
    val enabled = body.bool("enabled") ?: true
    return HerdrState(
        enabled = enabled,
        running = enabled && (body.bool("running") ?: false),
        agents = agents,
        control = enabled && (body.bool("control") ?: false),
    )
}

/** Parses the body of an output packet. It returns null for a body that is not an output. */
fun parseHerdrOutput(body: JsonObject): HerdrOutput? {
    if (body.str("kind") != "output") return null
    val pane = body.str("pane")?.takeIf { it.isNotEmpty() } ?: return null
    val error = body.str("error")?.takeIf { it.isNotEmpty() }
    // An older fluxd sends plain text. It has no escape sequences, so the
    // same parser reads it.
    return HerdrOutput(
        pane = pane,
        loading = false,
        lines = if (error == null) termLines(body.str("text").orEmpty()) else emptyList(),
        truncated = body.bool("truncated") ?: false,
        error = error,
    )
}

/** Parses the body of a sent packet. It returns null for a body that is not a sent answer. */
fun parseHerdrSent(body: JsonObject): HerdrSent? {
    if (body.str("kind") != "sent") return null
    val pane = body.str("pane")?.takeIf { it.isNotEmpty() } ?: return null
    return HerdrSent(pane, body.str("action").orEmpty(), body.str("error")?.takeIf { it.isNotEmpty() })
}

/** The key names that fluxd accepts in a keys packet. */
val HERDR_KEYS: Set<String> = setOf("enter", "esc", "tab", "shift+tab", "up", "down", "left", "right", "backspace", "space", "y", "n") +
    (0..9).map { it.toString() }

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
