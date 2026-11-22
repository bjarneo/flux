package org.omarchy.flux.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.text.BasicText
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.omarchy.flux.core.AgentRow
import org.omarchy.flux.core.AgentStatus
import org.omarchy.flux.core.ApprovalRow
import org.omarchy.flux.core.Approvals
import org.omarchy.flux.core.ChatRow
import org.omarchy.flux.core.ComputerRow
import org.omarchy.flux.core.DebugInbox
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.HerdrSync
import org.omarchy.flux.core.LinkNote
import org.omarchy.flux.core.PairRow
import org.omarchy.flux.core.SeenClock
import org.omarchy.flux.core.SendEntry
import org.omarchy.flux.core.SendKind
import org.omarchy.flux.core.TransferState
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.agentsOfPickedSessions
import org.omarchy.flux.core.chatList
import org.omarchy.flux.core.inScope
import org.omarchy.flux.core.needsEmptyLine
import org.omarchy.flux.core.showsWake
import org.omarchy.flux.core.stripComputers
import org.omarchy.flux.core.target

/** The first time that the list showed each row whose start is not known. It lives as long as the app process. */
private val listClock = SeenClock()

/**
 * The Chats destination, the home of the app: 1 chat for each agent and
 * each paired computer. What needs the user is on top: the approvals and
 * the pair requests as cards with their buttons, and the agents that wait
 * for input. The other agents and the computers follow. A tap on an agent
 * opens its chat, where the dock holds its question. A tap on a computer
 * opens its chat with the clipboard, the photos, and the tools. The top bar
 * has the scope chip, the search key, the Settings key, and the + key. The
 * scope keeps only the chats of 1 computer. The search key opens a field
 * that keeps only the chats that hold its text. The + key starts an agent
 * or a terminal. [active] is false while the screen moves, so that it reads
 * nothing new then. [selected] is the chat at the side of the list in a
 * split window, and its row has the accent.
 */
@Composable
fun ChatsScreen(
    state: UiState,
    active: Boolean,
    notices: InboxNotices,
    actions: ChatActions,
    picker: TargetPicker,
    scope: String?,
    onScope: (String?) -> Unit,
    onUnpair: (DeviceUi) -> Unit,
    onSettings: () -> Unit,
    selected: Route? = null,
) {
    val devices = state.devices
    // The computers send their changes. A new visit asks again for the agents.
    LaunchedEffect(active) {
        if (!active) return@LaunchedEffect
        for (d in devices) {
            if (d.paired && d.online && !isDemo(d.id) && d.herdrSupported) HerdrSync.request(FluxCore, d.id)
        }
    }
    val approval by Approvals.current.collectAsStateWithLifecycle()
    val log = rememberChatLog()
    var query by rememberSaveable { mutableStateOf("") }
    var searching by rememberSaveable { mutableStateOf(false) }
    val shownApproval = approval ?: if (demoShown()) DebugInbox.approval() else null
    val list = remember(devices, shownApproval, log, query, scope) {
        chatList(devices, shownApproval, log, listClock, System.currentTimeMillis(), query).inScope(scope)
    }
    val paired = devices.any { it.paired }
    // The + key starts an agent or a terminal on a computer that lets this phone control herdr.
    val newAgent = {
        val t = target(null, devices) { it.herdr?.anyRunning == true && it.herdr.control }
        if (t is org.omarchy.flux.core.Target.None && t.device == null) {
            FluxCore.toast("No computer lets this phone start an agent. To turn on Agent control, open Flux on a computer and use the Access card.")
        } else {
            picker.run(t, "Start an agent on") { actions.open(Route(it.id, NEW_PANE_PAGE)) }
        }
    }
    Column(Modifier.fillMaxSize().imePadding()) {
        Box(Modifier.statusBarsPadding()) {
            ChatsTopBar(
                devices, scope, onScope, onUnpair, paired, searching,
                onSearch = {
                    searching = !searching
                    if (!searching) query = ""
                },
                onSettings = onSettings, onNew = newAgent,
            )
        }
        if (!paired) {
            Column(
                Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter).padding(top = 12.dp, bottom = 16.dp),
            ) { PairGuide(state, actions) }
            return@Column
        }
        if (searching) SearchField(query, { query = it }, Modifier.padding(start = 10.dp, end = 10.dp, top = 2.dp, bottom = 8.dp))
        val context = LocalContext.current
        // The cards of Needs you name their computer when 2 computers have agents, also when 1 is not reachable.
        val withAgents = devices.count { it.paired && it.herdr?.anyRunning == true }
        val many = devices.count { it.paired && it.online && it.herdr?.anyRunning == true } > 1
        // A search looks in all sessions, so the strips and the session filter apply only with no search.
        val strips = if (query.isBlank()) stripComputers(devices).filter { scope == null || it.id == scope } else emptyList()
        val agentRows = if (query.isBlank()) agentsOfPickedSessions(list.agents, devices) { HerdrSessionPrefs.picked(context, it) } else list.agents
        // With no search, a list with nothing that needs the user says so.
        val showEmpty = query.isBlank() && list.needs.isEmpty()
        LazyColumn(
            Modifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(start = 10.dp, end = 10.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            item(key = "notices") {
                // The rows of the computers show which computers are not reachable. With none online, the notice tells the next step.
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { ChatNotices(notices, actions, offline = notices.reach.noneOnline) }
            }
            if (list.needs.isNotEmpty()) {
                item(key = "h-needs") { SectionHead("Needs you", "${list.needs.size}", Tn.red, first = true) }
                items(list.needs, key = { it.key }) { r -> NeedsRow(r, devices.firstOrNull { it.id == (r as? AgentRow)?.deviceId }, withAgents > 1, actions) }
            } else if (showEmpty) {
                item(key = "needs-empty") {
                    Box(Modifier.padding(top = 8.dp, bottom = 4.dp)) { NeedsEmpty(needsEmptyLine(list.agents.filter { it.reachable && it.agent.status == AgentStatus.Working })) }
                }
            }
            if (agentRows.isNotEmpty() || strips.isNotEmpty()) {
                // With 1 computer, the heading names it. With more, each row names its computer.
                val on = agentRows.map { it.computer }.distinct().singleOrNull()
                item(key = "h-agents") { SectionHead("Agents", if (on != null) "on $on" else null, Tn.sub, first = list.needs.isEmpty() && !showEmpty) }
                // A computer with 2 or more herdr sessions shows the session strip. The strip filters the Agents group of that computer.
                items(strips, key = { "strip-${it.id}" }) { d ->
                    SessionStrip(d, Modifier.padding(horizontal = 4.dp, vertical = 2.dp), label = if (strips.size > 1) d.name else null)
                }
                items(agentRows, key = { it.key }) { r -> AgentChatRow(r, many, context, actions, selected) }
            }
            if (list.computers.isNotEmpty()) {
                item(key = "h-computers") { SectionHead("Computers", null, Tn.sub, first = list.needs.isEmpty() && !showEmpty && agentRows.isEmpty() && strips.isEmpty()) }
                items(list.computers, key = { it.key }) { r -> ComputerChatRow(r, context, actions, selected) }
            }
            if (list.isEmpty && query.isNotBlank()) {
                item(key = "none") {
                    T("No chat holds \"${query.trim()}\".", Modifier.fillMaxWidth().padding(top = 24.dp), size = 13, color = Tn.sub, align = TextAlign.Center)
                }
            }
        }
    }
}

/** A key of the top bar: 48 dp, with an icon of 24 dp. [fill] gives the accent, as the + key has. */
@Composable
private fun BarKey(@androidx.annotation.DrawableRes icon: Int, label: String, fill: Boolean = false, onClick: () -> Unit) {
    Box(
        Modifier.size(48.dp).clip(CircleShape).background(if (fill) Tn.blue else Color.Transparent)
            .clickable(onClickLabel = label, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { Sym(icon, tint = if (fill) Tn.onAccent else Tn.text, size = 24.dp) }
}

/**
 * The top bar of Chats: the title, the scope chip, the search key, the
 * Settings key, and the + key. Before the first pairing, only the title and
 * the Settings key show.
 */
@Composable
private fun ChatsTopBar(
    devices: List<DeviceUi>,
    scope: String?,
    onScope: (String?) -> Unit,
    onUnpair: (DeviceUi) -> Unit,
    paired: Boolean,
    searching: Boolean,
    onSearch: () -> Unit,
    onSettings: () -> Unit,
    onNew: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(start = 14.dp, end = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        T(
            "Chats",
            Modifier.padding(end = 6.dp).semantics { heading() },
            size = 20, weight = FontWeight.SemiBold, maxLines = 1,
        )
        if (paired) {
            ScopeChip(devices, scope, onScope, Modifier.weight(1f), compact = true, onUnpair = onUnpair)
        } else {
            Box(Modifier.weight(1f))
        }
        if (paired) BarKey(if (searching) Ic.close else Ic.search, if (searching) "Close the search" else "Search", onClick = onSearch)
        BarKey(Ic.settings, "Settings", onClick = onSettings)
        if (paired) BarKey(Ic.add, "New agent or terminal", fill = true, onClick = onNew)
    }
}

/** The search field of the list: 44 dp high, on `tile` with a `line` border, with Clear while it holds text. */
@Composable
private fun SearchField(value: String, onValue: (String) -> Unit, modifier: Modifier) {
    val shape = RoundedCornerShape(22.dp)
    var focused by remember { mutableStateOf(false) }
    BasicTextField(
        value = value,
        onValueChange = onValue,
        modifier = modifier.fillMaxWidth().semantics { contentDescription = "Search agents, computers, files" }
            .onFocusChanged { focused = it.isFocused },
        textStyle = TextStyle(color = Tn.text, fontSize = 14.sp),
        cursorBrush = SolidColor(Tn.blue),
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        decorationBox = { inner ->
            Row(
                Modifier.fillMaxWidth().heightIn(min = 44.dp).clip(shape).background(Tn.tile).border(1.dp, if (focused) Tn.blue else Tn.line, shape)
                    .padding(start = 14.dp, end = if (value.isEmpty()) 14.dp else 2.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Sym(Ic.search, tint = Tn.sub, size = 20.dp)
                Box(Modifier.weight(1f)) {
                    if (value.isEmpty()) T("Search agents, computers, files", Modifier.clearAndSetSemantics {}, size = 14, color = Tn.sub, maxLines = 1)
                    inner()
                }
                if (value.isNotEmpty()) {
                    Box(
                        Modifier.size(40.dp).clip(CircleShape).clickable(onClickLabel = "Clear the search", role = Role.Button) { onValue("") }
                            .semantics { contentDescription = "Clear the search" },
                        contentAlignment = Alignment.Center,
                    ) { Sym(Ic.close, tint = Tn.sub, size = 20.dp) }
                }
            }
        },
    )
}

/** The heading of a group of chats: the [title], and [trailing] in mono and [color] at the end, such as a count. */
@Composable
private fun SectionHead(title: String, trailing: String?, color: Color, first: Boolean) {
    Row(
        Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = if (first) 8.dp else 12.dp, bottom = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        T(title, Modifier.weight(1f).semantics { heading() }, size = 14, weight = FontWeight.Medium)
        if (!trailing.isNullOrEmpty()) T(trailing, size = 11, color = color, family = Mono, maxLines = 1)
    }
}

/** A row of the Needs you group: an approval or a pair request as a card, or an agent that waits for input. */
@Composable
private fun NeedsRow(r: ChatRow, device: DeviceUi?, many: Boolean, actions: ChatActions) {
    when (r) {
        is ApprovalRow -> ApprovalCard(r.request, r.at, actions, list = true)
        is PairRow -> PairCard(r.deviceId, r.computer, r.at, actions, list = true)
        is AgentRow -> AgentNeedsCard(r, device, many, actions)
        is ComputerRow -> Unit
    }
}

/**
 * The frame of a chat row: the [avatar], the [title] in 15 sp 600, the
 * [line] under it, and the [time] in mono at the end. A row that needs the
 * user ([ask]) takes `tile` and a red border. [dim] shows a computer that
 * is not reachable at 55%. A [selected] row takes `accent-tile`. TalkBack
 * reads the row as 1 item.
 */
@Composable
private fun ChatRowFrame(
    avatar: @Composable () -> Unit,
    title: String,
    line: @Composable () -> Unit,
    time: String,
    description: String,
    onClick: () -> Unit,
    ask: Boolean = false,
    dim: Boolean = false,
    selected: Boolean = false,
    timeTicker: (@Composable () -> Unit)? = null,
    action: (@Composable () -> Unit)? = null,
) {
    val shape = RoundedCornerShape(12.dp)
    // The [action] sits beside the tap area, so that it stays at full strength when the row is dim.
    Row(
        Modifier.fillMaxWidth().clip(shape)
            .then(if (selected) Modifier.background(Tn.accentTile) else if (ask) Modifier.background(Tn.tile) else Modifier)
            .then(if (ask) Modifier.border(1.dp, Tn.red, shape) else Modifier)
            .semantics { this.selected = selected },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier.weight(1f).alpha(if (dim) DimAlpha else 1f)
                .clickable(onClickLabel = "Open the chat", role = Role.Button, onClick = onClick)
                .clearAndSetSemantics { contentDescription = description }
                .padding(start = 10.dp, end = if (action == null) 8.dp else 4.dp, top = if (ask) 10.dp else 8.dp, bottom = if (ask) 10.dp else 8.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            avatar()
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                T(title, size = 15, weight = FontWeight.SemiBold, maxLines = 1)
                line()
            }
            if (timeTicker != null) timeTicker() else if (time.isNotEmpty()) T(time, size = 11, color = Tn.sub, family = Mono, maxLines = 1)
        }
        if (action != null) Box(Modifier.padding(end = 8.dp)) { action() }
    }
}

/** **Wake** at the end of the row of a computer that is not reachable and can wake. It sends the Wake-on-LAN packet of Computers. */
@Composable
private fun WakeKey(d: DeviceUi) {
    val shape = RoundedCornerShape(16.dp)
    Box(
        Modifier.heightIn(min = 48.dp).clip(shape)
            .clickable(onClickLabel = "Wake ${d.name}", role = Role.Button) { FluxCore.wake(d.id) }
            .padding(vertical = 6.dp).clip(shape).background(Tn.line)
            .padding(horizontal = 18.dp, vertical = 10.dp)
            .semantics { contentDescription = "Wake ${d.name}" },
        contentAlignment = Alignment.Center,
    ) { T("Wake", size = 14, weight = FontWeight.Medium, maxLines = 1) }
}

/** The color of the status word and the dot of an agent. Idle and unknown take the second ink. */
@Composable
private fun agentColor(s: AgentStatus): Color = when (s) {
    AgentStatus.Blocked -> Tn.red
    AgentStatus.Working -> Tn.blue
    AgentStatus.Done -> Tn.green
    else -> Tn.sub
}

/** The source of an agent: the agent and its project, and the computer when [many] computers have agents. */
private fun agentSource(r: AgentRow, many: Boolean): String =
    listOf(r.agent.agent, r.agent.project.ifEmpty { r.agent.workspace }, if (many) r.computer else "").filter { it.isNotBlank() }.joinToString(" · ")

/**
 * An agent: its task, its status word in the status color with the agent
 * and the project in mono, and the time at the end. An agent that waits
 * shows how long it waits, an agent that works shows how long it works,
 * and another agent shows the time of its status.
 */
@Composable
private fun AgentChatRow(r: AgentRow, many: Boolean, context: Context, actions: ChatActions, selected: Route?) {
    val a = r.agent
    val s = a.status
    val blocked = s == AgentStatus.Blocked
    val color = agentColor(s)
    // The project shows in the line under the title, so an agent with no task shows its pane.
    val title = a.title.ifEmpty { a.pane }
    val source = agentSource(r, many)
    // A row of a computer that is not reachable shows when Flux last saw it, in place of the state word.
    val word = LinkNote.rowLine(r.reachable, r.since) { timeText(context, it) } ?: statusLabel(s)
    val sub = Tn.sub
    ChatRowFrame(
        avatar = {
            ChatAvatar(
                Ic.agent,
                tint = if (s == AgentStatus.Idle || s == AgentStatus.Unknown) Tn.sub else Tn.blue,
                fill = if (blocked) Tn.accentTile else Tn.tile,
                edge = if (blocked) null else Tn.line,
                badge = when (s) {
                    AgentStatus.Blocked -> Tn.red
                    AgentStatus.Done -> Tn.green
                    AgentStatus.Working -> null
                    else -> Tn.dim
                },
                spinner = s == AgentStatus.Working,
                ground = if (blocked) Tn.tile else Tn.bg,
            )
        },
        title = title,
        line = {
            val text = remember(word, source, color, sub) {
                buildAnnotatedString {
                    withStyle(SpanStyle(color = if (r.reachable) color else sub, fontWeight = FontWeight.Medium)) { append(word) }
                    if (source.isNotEmpty()) withStyle(SpanStyle(color = sub, fontFamily = Mono)) { append(" · $source") }
                }
            }
            BasicText(text, style = TextStyle(fontSize = 12.sp), maxLines = 1, overflow = TextOverflow.Ellipsis)
        },
        time = when {
            !r.reachable -> ""
            s == AgentStatus.Blocked || s == AgentStatus.Working -> ""
            else -> shortTime(context, r.at)
        },
        // The waiting time and the working time stop while the computer is not reachable.
        timeTicker = when {
            !r.reachable -> null
            s == AgentStatus.Blocked -> ({ Ticking(r.at, 30_000L) { agoShort(it) } })
            s == AgentStatus.Working -> if (r.at > 0) ({ Ticking(r.at, 1_000L) { clockText(it) } }) else null
            else -> null
        },
        description = listOf(title, word, source).filter { it.isNotEmpty() }.joinToString(", "),
        ask = blocked,
        dim = !r.reachable,
        selected = selected == Route(r.deviceId, "$AGENT_PAGE${a.pane}"),
        onClick = { actions.open(Route(r.deviceId, "$AGENT_PAGE${a.pane}")) },
    )
}

/** A time that moves: [text] of the time since [since], each [stepMs], in mono at the end of a row. */
@Composable
private fun Ticking(since: Long, stepMs: Long, text: (Long) -> String) {
    val now by rememberTicker(stepMs)
    T(text((now - since).coerceAtLeast(0)), size = 11, color = Tn.sub, family = Mono, maxLines = 1)
}

/** How long something waits, in short: "now", "3m", "2h", or "4d". */
private fun agoShort(ms: Long): String {
    val min = ms / 60_000
    return when {
        min < 1 -> "now"
        min < 60 -> "${min}m"
        min < 24 * 60 -> "${min / 60}h"
        else -> "${min / (24 * 60)}d"
    }
}

/** The time of [at] for a row: the time of day today, else the short date. */
private fun shortTime(context: Context, at: Long): String {
    if (at <= 0) return ""
    if (dayOf(at) == dayOf(System.currentTimeMillis())) return timeText(context, at)
    return java.text.DateFormat.getDateInstance(java.text.DateFormat.SHORT).format(java.util.Date(at))
}

/**
 * A computer: its name, the newest entry of its chat, and the time of that
 * entry. A computer that is not reachable shows at 55% with
 * `Not reachable since HH:MM`. Without entries, the line shows the link and battery.
 */
@Composable
private fun ComputerChatRow(r: ComputerRow, context: Context, actions: ChatActions, selected: Route?) {
    val d = r.device
    val line = when {
        !d.online -> LinkNote.rowLine(false, d.lastSeen) { timeText(context, it) }.orEmpty()
        r.last != null -> entryPreview(r.last)
        else -> computerContext(d).replaceFirstChar { it.uppercase() }
    }
    ChatRowFrame(
        avatar = { ChatAvatar(deviceIcon(d.type), Tn.text, badge = if (d.online) Tn.green else null) },
        title = d.name,
        line = { T(line, size = 13, color = Tn.sub, maxLines = 1) },
        time = if (!d.online && r.last == null) "" else shortTime(context, r.at),
        description = listOf(d.name, linkText(d), line).distinct().joinToString(", "),
        dim = !d.online,
        action = if (showsWake(d)) ({ WakeKey(d) }) else null,
        selected = selected?.deviceId == d.id && (selected.page == CHAT_PAGE || selected.page == CHAT_TRAY_PAGE),
        onClick = { actions.open(Route(d.id, CHAT_PAGE)) },
    )
}

/** The newest entry of a chat in 1 line, such as "You: Dinner at 7" or "invoice-0042.pdf". */
internal fun entryPreview(e: SendEntry): String {
    val text = e.text.replace('\n', ' ')
    return when {
        e.kind == SendKind.Approved -> "Approved ${e.text}"
        e.kind == SendKind.Denied -> "Denied ${e.text}"
        e.incoming && e.kind == SendKind.File -> if (e.state == TransferState.Running) "Receiving $text" else text
        e.incoming && e.kind == SendKind.ClipImage -> "Clipboard: an image"
        e.incoming -> "Clipboard: $text"
        e.kind == SendKind.ClipImage -> "You: an image"
        e.kind == SendKind.File && e.state == TransferState.Running -> "You: sending $text"
        e.kind == SendKind.File && e.state == TransferState.Failed -> "You: not sent, $text"
        else -> "You: $text"
    }
}
