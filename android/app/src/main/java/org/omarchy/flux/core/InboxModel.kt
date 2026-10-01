package org.omarchy.flux.core

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/**
 * The kinds of Inbox items, in the order of the Inbox. The first 3 kinds
 * need the user: an agent that waits for input, an approval, and a pair
 * request. The other kinds show what happens on the computers.
 */
enum class InboxKind(val needsYou: Boolean) {
    AgentInput(true),
    Approval(true),
    PairRequest(true),
    AgentDone(false),
    AgentWorking(false),
    Transfer(false),
    Clipboard(false),
    Media(false),
}

/**
 * One item of the Inbox. [key] stays the same while the item is the same,
 * so the UI keeps its place. [deviceIds] are the computers of the item. An
 * item with no computers shows in every scope.
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

/** A file that goes to or comes from a computer. */
data class TransferItem(val transfer: Transfer) : InboxItem {
    override val kind: InboxKind get() = InboxKind.Transfer
    override val key: String get() = "transfer|${transfer.id}"
    override val deviceIds: Set<String> get() = setOf(transfer.deviceId)
    override val computer: String get() = transfer.computer
}

/** The last clip that this phone sent or received. */
data class ClipItem(val clip: ClipEvent) : InboxItem {
    override val kind: InboxKind get() = InboxKind.Clipboard
    override val key: String get() = "clip"
    override val deviceIds: Set<String> get() = clip.deviceIds.toSet()
    override val computer: String get() = clip.computer
}

/** What a player on a computer plays now. */
data class MediaItem(val deviceId: String, override val computer: String, val player: PlayerState) : InboxItem {
    override val kind: InboxKind get() = InboxKind.Media
    override val key: String get() = "media|$deviceId"
    override val deviceIds: Set<String> get() = setOf(deviceId)
}

/** The state of a file transfer. */
enum class TransferState { Running, Done, Failed }

/**
 * A file transfer. [incoming] is true for a file from the computer. [at]
 * is the start time in milliseconds since the epoch.
 */
data class Transfer(
    val id: Long,
    val deviceId: String,
    val computer: String,
    val name: String,
    val incoming: Boolean,
    val state: TransferState = TransferState.Running,
    val at: Long = 0,
)

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
 * Collects the Inbox items of all computers and ranks them. The order is
 * the order of [InboxKind]. Inside a kind, the computers keep their order,
 * running transfers come before the newest finished ones, and a player
 * that plays comes before a paused one.
 */
fun inboxItems(devices: List<DeviceUi>, approval: ApproveRequest?, transfers: List<Transfer>, clip: ClipEvent?): List<InboxItem> {
    val out = ArrayList<InboxItem>()
    for (d in devices) {
        if (!d.paired) {
            if (d.pairState == PairState.Incoming) out += PairItem(d.id, d.name)
            continue
        }
        if (!d.online) continue
        val herdr = d.herdr
        if (herdr != null && herdr.running) {
            for (a in herdr.agents) {
                if (a.status == AgentStatus.Blocked || a.status == AgentStatus.Done || a.status == AgentStatus.Working) {
                    out += AgentItem(d.id, d.name, a, herdr.control)
                }
            }
        }
    }
    approval?.let { out += ApprovalItem(it) }
    transfers.sortedWith(compareBy<Transfer> { it.state != TransferState.Running }.thenByDescending { it.at })
        .forEach { out += TransferItem(it) }
    clip?.let { out += ClipItem(it) }
    devices.filter { it.paired && it.online }
        .mapNotNull { d -> d.player?.takeIf { it.playing || it.title.isNotEmpty() }?.let { MediaItem(d.id, d.name, it) } }
        .sortedBy { !it.player.playing }
        .forEach { out += it }
    // The sort is stable, so the order above stays inside each kind.
    return out.sortedBy { it.kind.ordinal }
}

/** The items of the computer [scope], or all items when [scope] is null. */
fun List<InboxItem>.inScope(scope: String?): List<InboxItem> =
    if (scope == null) this else filter { it.deviceIds.isEmpty() || scope in it.deviceIds }

/** The number of items that need the user. */
fun List<InboxItem>.needsYou(): Int = count { it.kind.needsYou }

/**
 * The order that the user gave the Inbox. [pinned] is the item that the
 * user moved to the master tile. [deferred] are the items that the user
 * swiped away, in the order of the swipes. [known] are the item keys of the
 * last [sync], so that a new item that needs the user can take the master
 * tile back.
 */
data class InboxArrangement(
    val pinned: String? = null,
    val deferred: List<String> = emptyList(),
    val known: Set<String> = emptySet(),
    val started: Boolean = false,
) {
    /** Moves the master item [key] to the end of the stack. The next item becomes the master. */
    fun swipe(key: String): InboxArrangement = copy(pinned = pinned?.takeIf { it != key }, deferred = deferred - key + key)

    /** Moves the stack item [key] to the master tile. */
    fun promote(key: String): InboxArrangement = copy(pinned = key, deferred = deferred - key)

    /**
     * Forgets the keys that are gone. A new item that needs the user
     * removes the pin, so that the ranking puts the new item first.
     */
    fun sync(items: List<InboxItem>): InboxArrangement {
        val keys = items.mapTo(HashSet()) { it.key }
        val fresh = started && items.any { it.kind.needsYou && it.key !in known }
        return InboxArrangement(
            pinned = pinned?.takeIf { it in keys && !fresh },
            deferred = deferred.filter { it in keys },
            known = keys,
            started = true,
        )
    }

    /** Puts [items] in the order of the user: the pinned item first, and the deferred items last. */
    fun arrange(items: List<InboxItem>): List<InboxItem> {
        val byKey = items.associateBy { it.key }
        val late = deferred.mapNotNull { byKey[it] }
        val lateKeys = late.mapTo(HashSet()) { it.key }
        val ordered = items.filter { it.key !in lateKeys } + late
        val pin = pinned?.let { byKey[it] } ?: return ordered
        return listOf(pin) + ordered.filter { it.key != pin.key }
    }
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
 * are not empty.
 */
fun agentPrompt(lines: List<String>, maxLines: Int = 4): String {
    val from = maxOf(0, lines.size - PROMPT_SCAN_LINES)
    val start = (lines.size - 1 downTo from).firstOrNull { firstChoice.matches(lines[it]) } ?: lines.size
    val out = ArrayList<String>()
    var i = start - 1
    while (i >= from && out.size < maxLines) {
        val t = lines[i].trim()
        i--
        if (t.isEmpty()) continue
        if (ruleLine.matches(t)) break
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

/** The most transfers that the Inbox keeps. All running transfers stay. */
const val MAX_TRANSFERS = 4

/** Adds the new transfer [t] first, and drops the oldest finished transfers above [max]. */
fun startTransfer(list: List<Transfer>, t: Transfer, max: Int = MAX_TRANSFERS): List<Transfer> {
    val all = listOf(t) + list
    val running = all.filter { it.state == TransferState.Running }
    val done = all.filter { it.state != TransferState.Running }.take(maxOf(0, max - running.size))
    val keep = (running + done).mapTo(HashSet()) { it.id }
    return all.filter { it.id in keep }
}

/** Marks the running transfer [id] as done or failed. */
fun endTransfer(list: List<Transfer>, id: Long, ok: Boolean): List<Transfer> =
    list.map { if (it.id == id && it.state == TransferState.Running) it.copy(state = if (ok) TransferState.Done else TransferState.Failed) else it }

/**
 * The recent transfers and the last clip, for the Inbox. The share and
 * clipboard code reports to it. It keeps no file content and only a short
 * preview of a text clip, in memory.
 */
object InboxFeed {
    private val ids = AtomicLong()
    private val _transfers = MutableStateFlow<List<Transfer>>(emptyList())
    private val _clip = MutableStateFlow<ClipEvent?>(null)

    /** The recent transfers, newest first. */
    val transfers: StateFlow<List<Transfer>> = _transfers

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
    }

    /** Reports a new transfer and returns its ID for [transferEnded]. */
    fun transferStarted(deviceId: String, computer: String, name: String, incoming: Boolean): Long {
        val id = ids.incrementAndGet()
        val t = Transfer(id, deviceId, computer, name, incoming, at = System.currentTimeMillis())
        _transfers.update { startTransfer(it, t) }
        return id
    }

    fun transferEnded(id: Long, ok: Boolean) {
        _transfers.update { endTransfer(it, id, ok) }
    }
}
