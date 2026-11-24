package org.omarchy.flux.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The kinds of Inbox items. The first 3 kinds need the user: an agent that
 * waits for input, an approval, and a pair request. The agents that are
 * done or that work follow. The chat shows the items in the order of
 * their time, see [chatItems].
 */
enum class InboxKind(val needsYou: Boolean) {
    AgentInput(true),
    Approval(true),
    PairRequest(true),
    AgentDone(false),
    AgentWorking(false),
}

/**
 * One item of the Inbox: something on a computer that has a state now.
 * [key] stays the same while the item is the same, so the UI keeps its
 * place. [deviceIds] are the computers of the item. An item with no
 * computers shows in every scope.
 */
sealed interface InboxItem {
    val key: String
    val kind: InboxKind
    val deviceIds: Set<String>

    /** The name of the computer, or a count of computers. */
    val computer: String
}

/** A herdr agent that waits for input, finished, or works. [control] is true when the computer takes replies. */
data class AgentItem(val deviceId: String, override val computer: String, val agent: HerdrAgent, val control: Boolean) : InboxItem {
    override val kind: InboxKind
        get() = when (agent.status) {
            AgentStatus.Blocked -> InboxKind.AgentInput
            AgentStatus.Done -> InboxKind.AgentDone
            else -> InboxKind.AgentWorking
        }

    // A new status is a new item. An agent that waits again after work moves up again.
    override val key: String get() = "agent|$deviceId|${agent.pane}|${kind.name}"
    override val deviceIds: Set<String> get() = setOf(deviceId)
}

/** A sudo, polkit, or enrollment request that waits for the fingerprint. */
data class ApprovalItem(val request: ApproveRequest) : InboxItem {
    override val kind: InboxKind get() = InboxKind.Approval
    override val key: String get() = "approve|${request.computerId}|${request.id}"
    override val deviceIds: Set<String> get() = setOf(request.computerId)
    override val computer: String get() = request.computerName
}

/** A computer that is not paired and asks to pair. It shows in every scope. */
data class PairItem(val deviceId: String, override val computer: String) : InboxItem {
    override val kind: InboxKind get() = InboxKind.PairRequest
    override val key: String get() = "pair|$deviceId"
    override val deviceIds: Set<String> get() = emptySet()
}

/** The state of a file transfer. */
enum class TransferState { Running, Done, Failed }

/**
 * A clip that this phone sent ([sent]) or received. [preview] is a short
 * form of the text, and it is empty for an image. [at] is the time in
 * milliseconds since the epoch.
 */
data class ClipEvent(
    val deviceIds: List<String>,
    val computer: String,
    val sent: Boolean,
    val preview: String,
    val image: Boolean = false,
    val at: Long = 0,
)

/**
 * Collects the Inbox items of all computers: the agents that wait, are
 * done, or work, the open [approval], and the pair requests. A computer
 * that is not reachable adds no agents. Each key shows once, because a
 * computer can report 2 agents on 1 pane.
 */
fun inboxItems(devices: List<DeviceUi>, approval: ApproveRequest?): List<InboxItem> {
    val out = ArrayList<InboxItem>()
    for (d in devices) {
        if (!d.paired) {
            if (d.pairState == PairState.Incoming) out += PairItem(d.id, d.name)
            continue
        }
        if (!d.online) continue
        val herdr = d.herdr
        if (herdr != null && herdr.anyRunning) {
            for (a in herdr.agents) {
                if (a.status == AgentStatus.Blocked || a.status == AgentStatus.Done || a.status == AgentStatus.Working) {
                    out += AgentItem(d.id, d.name, a, herdr.control)
                }
            }
        }
    }
    approval?.let { out += ApprovalItem(it) }
    return out.distinctBy { it.key }
}

/** The items of the computer [scope], or all items when [scope] is null. */
fun List<InboxItem>.inScope(scope: String?): List<InboxItem> =
    if (scope == null) this else filter { it.deviceIds.isEmpty() || scope in it.deviceIds }

/** The number of items that need the user. */
fun List<InboxItem>.needsYou(): Int = count { it.kind.needsYou }

/**
 * The link state of the paired computers in a scope: the number that are
 * online, and the computers that are not reachable. The Inbox cannot show
 * the agents of a computer that is not reachable.
 */
data class InboxReach(val online: Int, val offline: List<DeviceUi>) {
    /** True when the scope has paired computers and none of them is online. */
    val noneOnline: Boolean get() = online == 0 && offline.isNotEmpty()
}

/** The link state of the paired computers in [scope], or of all paired computers when [scope] is null. */
fun inboxReach(scope: String?, devices: List<DeviceUi>): InboxReach {
    val paired = devices.filter { it.paired && (scope == null || it.id == scope) }
    return InboxReach(paired.count { it.online }, paired.filter { !it.online })
}

/**
 * The computer that a Send or Control action goes to. [One] is the only
 * computer that can take it. [Ask] means that the user picks 1 of
 * [Ask.devices]. [None] means that no computer can take it now. Its
 * [None.device] is the computer in scope, or null.
 */
sealed interface Target {
    data class One(val device: DeviceUi) : Target
    data class Ask(val devices: List<DeviceUi>) : Target
    data class None(val device: DeviceUi?) : Target
}

/**
 * Finds the computer for an action. A computer in [scope] is the target
 * when it is online and [can] take the action. With all computers in
 * scope, the only online computer that can take it is the target, and with
 * more than 1 the user picks.
 */
fun target(scope: String?, devices: List<DeviceUi>, can: (DeviceUi) -> Boolean = { true }): Target {
    val paired = devices.filter { it.paired }
    if (scope != null) {
        val d = paired.firstOrNull { it.id == scope } ?: return Target.None(null)
        return if (d.online && can(d)) Target.One(d) else Target.None(d)
    }
    val ready = paired.filter { it.online && can(it) }
    return when (ready.size) {
        0 -> Target.None(null)
        1 -> Target.One(ready[0])
        else -> Target.Ask(ready)
    }
}

/**
 * The computer for the + key of Chats. A computer in [scope] is the target
 * when it is online. With all computers in scope, the user picks from the
 * online computers. The page of the computer shows when herdr is not
 * running or Agent control is off.
 */
fun newAgentTarget(scope: String?, devices: List<DeviceUi>): Target = target(scope, devices)

/** True when a paired computer in [scope] has a feature, even while it is not reachable. */
fun hasFeature(scope: String?, devices: List<DeviceUi>, can: (DeviceUi) -> Boolean): Boolean =
    devices.any { it.paired && (scope == null || it.id == scope) && can(it) }

private val firstChoice = Regex("""^\s*([❯›>]\s*)?1[.)]\s+.+$""")
private val ruleLine = Regex("""^[\s─━═╌┄╍┈┉\-_]+$""")

/** How far from the end of the output the question can start, in lines. */
private const val PROMPT_SCAN_LINES = 40

/**
 * Finds the question of an agent in its output lines: the lines above the
 * first numbered choice, up to [maxLines] lines that are not empty. A rule
 * line ends the question. Without choices, it gives the last lines that
 * are not empty. The lines nearest the choices stay, because they hold the
 * command that a choice approves. With [dropAsk], the last line above the
 * choices goes away when it ends with a question mark, because the choices
 * ask the same question. The command then gets that line.
 */
fun agentPrompt(lines: List<String>, maxLines: Int = 4, dropAsk: Boolean = false): String {
    val from = maxOf(0, lines.size - PROMPT_SCAN_LINES)
    val choice = (lines.size - 1 downTo from).firstOrNull { firstChoice.matches(lines[it]) }
    val out = ArrayList<String>()
    var i = (choice ?: lines.size) - 1
    var ask = dropAsk && choice != null
    while (i >= from && out.size < maxLines) {
        val t = lines[i].trim()
        i--
        if (t.isEmpty()) continue
        if (ruleLine.matches(t)) break
        if (ask) {
            ask = false
            if (t.endsWith("?")) continue
        }
        out.add(0, t)
    }
    return out.joinToString("\n")
}

/** The longest clip preview, in characters. */
const val CLIP_PREVIEW = 160

/** A short form of a clip for the Inbox: 1 line with single spaces, cut at [max] characters. */
fun clipPreview(text: String, max: Int = CLIP_PREVIEW): String {
    val t = text.trim().replace(Regex("\\s+"), " ")
    return if (t.length > max) t.take(max - 1) + "…" else t
}

/**
 * The last clip that this phone sent or received. The clipboard code
 * reports to it, and a clip from a computer also goes to the chat log. It
 * keeps only a short preview of a text clip, in memory.
 */
object InboxFeed {
    private val _clip = MutableStateFlow<ClipEvent?>(null)

    /** The last clip that this phone sent or received. */
    val clip: StateFlow<ClipEvent?> = _clip

    /** Reports a clip that went to [computers], as pairs of the device ID and the name. [text] is null for an image. */
    fun clipSent(computers: List<Pair<String, String>>, text: String?) {
        if (computers.isEmpty()) return
        val name = computers.singleOrNull()?.second ?: "${computers.size} computers"
        _clip.value = ClipEvent(computers.map { it.first }, name, sent = true, preview = text?.let(::clipPreview).orEmpty(), image = text == null, at = System.currentTimeMillis())
    }

    /** Reports a clip from the computer [deviceId]. [text] is null for an image. */
    fun clipReceived(deviceId: String, computer: String, text: String?) {
        _clip.value = ClipEvent(listOf(deviceId), computer, sent = false, preview = text?.let(::clipPreview).orEmpty(), image = text == null, at = System.currentTimeMillis())
        SendLog.clipIn(deviceId, computer, text)
    }
}
