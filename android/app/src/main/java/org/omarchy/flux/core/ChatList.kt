package org.omarchy.flux.core

/**
 * 1 row of the Chats list. [key] stays the same while the row is the same,
 * so the list keeps its place. [at] is the time of the row in
 * milliseconds since the epoch, or 0 when it is not known.
 */
sealed interface ChatRow {
    val key: String
    val at: Long
}

/** A sudo, polkit, or enrollment request that waits for the fingerprint. The list shows it as a card with Deny and Approve. */
data class ApprovalRow(val request: ApproveRequest, override val at: Long) : ChatRow {
    override val key: String get() = "approve|${request.computerId}|${request.id}"
}

/** A computer that is not paired and asks to pair. */
data class PairRow(val deviceId: String, val computer: String, override val at: Long) : ChatRow {
    override val key: String get() = "pair|$deviceId"
}

/**
 * A herdr agent: 1 chat. [at] is the start of its status. [control] is
 * true when the computer takes replies. [reachable] is false while the
 * computer is not reachable. The row then shows the last known agent, and
 * [since] is the time that Flux last saw the computer, or 0.
 */
data class AgentRow(
    val deviceId: String,
    val computer: String,
    val agent: HerdrAgent,
    val control: Boolean,
    override val at: Long,
    val reachable: Boolean = true,
    val since: Long = 0,
) : ChatRow {
    override val key: String get() = "agent|$deviceId|${agent.pane}"
}

/**
 * A paired computer: 1 chat. [last] is the newest entry of its chat log,
 * or the newest entry that matches the search.
 */
data class ComputerRow(val device: DeviceUi, val last: SendEntry?) : ChatRow {
    override val key: String get() = "computer|${device.id}"
    override val at: Long get() = last?.at ?: 0L
}

/**
 * The rows of the Chats list in 3 groups. [needs] holds the approvals, the
 * pair requests, and the agents that wait for input, the newest first.
 * [agents] holds the other agents: the agents that work, then the agents
 * that are done, then the idle agents. [computers] holds the paired
 * computers, the online computers first.
 */
data class ChatList(val needs: List<ChatRow>, val agents: List<AgentRow>, val computers: List<ComputerRow>) {
    val isEmpty: Boolean get() = needs.isEmpty() && agents.isEmpty() && computers.isEmpty()
}

/** The order of an agent in the Agents group: the agents that work first, then the agents that are done. */
private fun agentRank(s: AgentStatus): Int = when (s) {
    AgentStatus.Working -> 0
    AgentStatus.Done -> 1
    else -> 2
}

/** The key that [SeenClock] keeps for a row. An agent with a new status is new. */
private fun seenKey(r: ChatRow): String = if (r is AgentRow) "${r.key}|${r.agent.status.name}" else r.key

/** True when [query] is empty or when 1 of [fields] holds it, without case. */
private fun matches(query: String, vararg fields: String?): Boolean =
    query.isEmpty() || fields.any { it != null && it.contains(query, ignoreCase = true) }

/**
 * Builds the Chats list: 1 chat for each agent and each paired computer,
 * and the [approval] and the pair requests on top. A computer that is not
 * reachable keeps the last known agents, with [AgentRow.reachable] false and
 * [AgentRow.since] set. An agent takes the start time of its status
 * from [DeviceUi.agentSince], and an approval the time of its request.
 * Any other row with no time takes the time
 * that [seen] first saw it at [now]. [log] gives each computer its newest
 * entry. A [query] keeps only the rows that hold it: a computer also stays
 * when an entry of its chat log holds it, and that entry shows.
 */
fun chatList(
    devices: List<DeviceUi>,
    approval: ApproveRequest?,
    log: List<SendEntry>,
    seen: SeenClock,
    now: Long,
    query: String = "",
): ChatList {
    val q = query.trim()
    val paired = devices.filter { it.paired }
    val rows = ArrayList<ChatRow>()
    if (approval != null && paired.any { it.id == approval.computerId }) rows += ApprovalRow(approval, approval.time * 1000)
    for (d in devices) if (!d.paired && d.pairState == PairState.Incoming) rows += PairRow(d.id, d.name, 0)
    for (d in paired) {
        val herdr = d.herdr ?: continue
        if (!herdr.anyRunning) continue
        for (a in herdr.agents.distinctBy { it.pane }) {
            rows += AgentRow(d.id, d.name, a, herdr.control, d.agentSince[a.pane] ?: 0L, reachable = d.online, since = if (d.online) 0L else d.lastSeen)
        }
    }
    val times = seen.update(rows.map(::seenKey), now)
    val timed = rows.map { r ->
        val at = times[seenKey(r)] ?: now
        when (r) {
            is ApprovalRow -> if (r.at > 0) r else r.copy(at = at)
            is PairRow -> r.copy(at = at)
            is AgentRow -> if (r.at > 0) r else r.copy(at = at)
            is ComputerRow -> r
        }
    }.filter { r ->
        when (r) {
            is ApprovalRow -> matches(q, r.request.service, r.request.host, r.request.computerName, r.request.user)
            is PairRow -> matches(q, r.computer)
            is AgentRow -> matches(q, r.agent.title, r.agent.agent, r.agent.project, r.agent.workspace, r.agent.pane, r.computer)
            is ComputerRow -> true
        }
    }
    val needs = timed.filter { it !is AgentRow || it.agent.status == AgentStatus.Blocked }.sortedByDescending { it.at }
    val agents = timed.filterIsInstance<AgentRow>().filter { it.agent.status != AgentStatus.Blocked }
        .sortedWith(compareBy<AgentRow> { agentRank(it.agent.status) }.thenByDescending { it.at })
    val computers = paired.mapNotNull { d ->
        val entries = log.filter { it.deviceId == d.id }
        val last = if (matches(q, d.name)) entries.maxByOrNull { it.at } else entries.filter { matches(q, it.text, it.computer) }.maxByOrNull { it.at }
        if (q.isNotEmpty() && last == null && !matches(q, d.name)) null else ComputerRow(d, last)
    }.sortedWith(compareByDescending<ComputerRow> { it.device.online }.thenByDescending { it.at }.thenBy { it.device.name.lowercase() })
    return ChatList(needs, agents, computers)
}

/** The number of rows that need the user: the approvals, the pair requests, and the agents that wait for input. */
val ChatList.needsYou: Int get() = needs.size

/**
 * The number of rows that need the user, for the badge of the Chats tab.
 * It equals the Needs you count of the list, also for a blocked agent of a
 * computer that is not reachable (decision 004).
 */
fun needsYouCount(devices: List<DeviceUi>, approval: ApproveRequest?): Int =
    chatList(devices, approval, emptyList(), SeenClock(), 0L).needsYou

/**
 * The rows of 1 computer. With [scope] null, all rows stay. A pair request
 * has no paired computer, so it stays in each scope.
 */
fun ChatList.inScope(scope: String?): ChatList {
    if (scope == null) return this
    return ChatList(
        needs.filter { r ->
            when (r) {
                is ApprovalRow -> r.request.computerId == scope
                is AgentRow -> r.deviceId == scope
                is PairRow, is ComputerRow -> true
            }
        },
        agents.filter { it.deviceId == scope },
        computers.filter { it.device.id == scope },
    )
}
