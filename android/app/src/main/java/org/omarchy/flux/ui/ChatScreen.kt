package org.omarchy.flux.ui

import android.app.DownloadManager
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.util.Calendar
import kotlinx.coroutines.flow.drop
import org.omarchy.flux.BuildConfig
import org.omarchy.flux.R
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.ApprovalItem
import org.omarchy.flux.core.Approvals
import org.omarchy.flux.core.ApproveRequest
import org.omarchy.flux.core.ChatEventItem
import org.omarchy.flux.core.ChatItem
import org.omarchy.flux.core.ChatLogItem
import org.omarchy.flux.core.DebugDemo
import org.omarchy.flux.core.DebugFirstRun
import org.omarchy.flux.core.DebugInbox
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.InboxFeed
import org.omarchy.flux.core.InboxItem
import org.omarchy.flux.core.PairItem
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.core.SEND_TEXT_MAX
import org.omarchy.flux.core.SeenClock
import org.omarchy.flux.core.SendEntry
import org.omarchy.flux.core.SendKind
import org.omarchy.flux.core.SendLog
import org.omarchy.flux.core.Share
import org.omarchy.flux.core.TransferState
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.chatItems
import org.omarchy.flux.core.inboxItems
import org.omarchy.flux.voice.Dictation
import org.omarchy.flux.voice.DictationText
import org.omarchy.flux.voice.VoiceField
import org.omarchy.flux.voice.rememberVoiceTyping

/**
 * The agents, the approval, and the pair requests of all computers. A
 * debug build with the demo adds the sample approval of [DebugInbox].
 */
@Composable
fun rememberChatEvents(state: UiState): List<InboxItem> {
    val approval by Approvals.current.collectAsStateWithLifecycle()
    return remember(state.devices, approval, demoShown()) {
        inboxItems(state.devices, approval ?: if (demoShown()) DebugInbox.approval() else null)
    }
}

/** True when a debug build shows the samples of the demo. The first run and the pairing success state show none. */
internal fun demoShown(): Boolean = BuildConfig.DEBUG && DebugDemo.on && DebugFirstRun.mode == DebugFirstRun.Mode.Off

/** The chat log, with the sample entries of a debug build with the demo, oldest first. */
@Composable
internal fun rememberChatLog(): List<SendEntry> {
    val logged by SendLog.entries.collectAsStateWithLifecycle()
    val demo = demoShown()
    return remember(logged, demo) { (if (demo) DebugInbox.sends() + logged else logged).sortedBy { it.at } }
}

/**
 * What the chats and their notices do: open screens, the approval screen,
 * and the pair sheet, pair a computer, show all computers, and ask for the
 * notifications. [pair] starts the pairing that this phone sends, as in
 * Computers. [control] opens Control with the computer in scope.
 */
class ChatActions(
    val open: (Route) -> Unit,
    val approve: (ApproveRequest) -> Unit,
    val showPair: (String) -> Unit,
    val pair: (DeviceUi) -> Unit,
    val showAll: () -> Unit,
    val allowNotifications: () -> Unit,
    val hideNotifications: () -> Unit,
    val go: (Tab) -> Unit = {},
    val control: (String) -> Unit = {},
)

/** The first time that the chat showed each item whose start is not known. It lives as long as the app process. */
private val seenClock = SeenClock()

/**
 * The chat of 1 computer: what happens between this phone and the
 * computer, with the newest at the bottom. The computer writes on the
 * left: approvals, received files, and clips. What this phone sent shows on
 * the right. An approval shows Approve and Deny in the thread. The dock
 * under it shows the clipboard of this phone with Send, and the composer.
 * The + key of the composer opens the tray with the recent photos and the
 * tools. [active] is false while the screen moves, so that it reads
 * nothing new then. [notices] tell what the thread cannot show. With
 * [tray], the tray is open at the start.
 */
@Composable
fun ComputerChatScreen(
    state: UiState,
    d: DeviceUi,
    all: List<InboxItem>,
    active: Boolean,
    notices: InboxNotices,
    actions: ChatActions,
    onBack: () -> Unit,
    tray: Boolean = false,
) {
    val log = rememberChatLog()
    val entries = remember(log, d.id) { log.filter { it.deviceId == d.id } }
    val events = remember(all, d.id) { all.filter { it is ApprovalItem && d.id in it.deviceIds } }
    // All computers keep their times, so that a new item on another computer does not move an item.
    val seen = remember(all) { seenClock.update(all.map { it.key }, System.currentTimeMillis()) }
    val chat = remember(entries, events, seen) { chatItems(entries, events, { _, _ -> null }, seen) }
    val running = entries.filter { it.kind == SendKind.File && it.state == TransferState.Running }
    var trayOpen by rememberSaveable(d.id) { mutableStateOf(tray) }
    BackHandler(enabled = trayOpen) { trayOpen = false }

    Column(Modifier.fillMaxSize().imePadding()) {
        ChatTopBar(
            title = d.name,
            context = computerContext(d),
            onBack = onBack,
            avatar = { ChatAvatar(deviceIcon(d.type), Tn.text, size = 36.dp, badge = if (d.online) Tn.green else null) },
        ) { ComputerMenu(d, actions) }
        ProgressLine {
            if (running.isNotEmpty()) {
                val size = running.sumOf { it.size }
                LineFill(if (size > 0) running.sumOf { it.done }.toFloat() / size else 0f, Tn.blue)
            }
        }
        DockLayout(
            Modifier.weight(1f).fillMaxWidth(),
            thread = { bottom -> ChatThread(chat, bottom, notices, actions) },
            dock = { shape ->
                ChatDock(
                    shape, d, entries, actions,
                    trayOpen = trayOpen,
                    onTray = { trayOpen = it },
                )
            },
        )
    }
}

/** The line under the name of a computer: its link and battery, or when it was last seen. */
internal fun computerContext(d: DeviceUi): String = when {
    d.online && d.battery != null -> "connected · ${d.battery}%" + if (d.charging) ", charging" else ""
    d.online -> "connected"
    else -> "not reachable"
}

/**
 * The menu of the chat of a computer: Control with the computer in scope,
 * its terminals when the computer allows them, and a new agent or terminal.
 */
@Composable
private fun ComputerMenu(d: DeviceUi, actions: ChatActions) {
    var open by remember { mutableStateOf(false) }
    val herdr = d.herdr
    Box {
        Box(
            Modifier.size(48.dp).clip(CircleShape)
                .clickable(onClickLabel = "More actions", role = Role.Button) { open = true }
                .semantics { contentDescription = "More actions" },
            contentAlignment = Alignment.Center,
        ) { Sym(Ic.more, tint = Tn.text, size = 24.dp) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            val items = listOfNotNull(
                Triple("Control", Ic.tune) { actions.control(d.id) },
                if (d.herdrSupported && herdr?.terminals == true) Triple("Terminals", Ic.terminal) { actions.open(Route(d.id, AGENTS_PAGE)) } else null,
                if (d.online && herdr?.anyRunning == true && herdr.control) Triple("New agent or terminal", Ic.add) { actions.open(Route(d.id, NEW_PANE_PAGE)) } else null,
            )
            for ((label, icon, action) in items) {
                DropdownMenuItem(text = { Text(label) }, leadingIcon = { Sym(icon) }, onClick = {
                    open = false
                    action()
                })
            }
        }
    }
}

// ───────────────────────── Top bar ─────────────────────────

/**
 * The top bar of a chat: a 48 dp back icon, the [avatar], the [title] in
 * 16 sp 600, and the [context] line in mono 11 sp. [actions] draw at the
 * end.
 */
@Composable
internal fun ChatTopBar(title: String, context: String, onBack: () -> Unit, avatar: @Composable () -> Unit, actions: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(start = 2.dp, end = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(48.dp).clip(CircleShape).clickable(onClickLabel = "Back", role = Role.Button, onClick = onBack)
                .semantics { contentDescription = "Back" },
            contentAlignment = Alignment.Center,
        ) { Sym(Ic.back, tint = Tn.text, size = 24.dp) }
        Box(Modifier.clearAndSetSemantics {}) { avatar() }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(title, Modifier.semantics { heading() }, size = 16, weight = FontWeight.SemiBold, maxLines = 1)
            if (context.isNotEmpty()) LineText(context, size = 11f, lineHeight = MONO_LINE, color = Tn.sub, family = Mono, maxLines = 1)
        }
        actions()
    }
}

/**
 * The picture of a chat: an [icon] in [tint] on a square with round
 * corners. [fill] is the color of the square, and [edge] its border or
 * null. [badge] is the color of the dot at the bottom right, or null.
 * [spinner] draws a ring that turns in the place of the dot, for an agent
 * that works. [ground] is the color around the dot.
 */
@Composable
internal fun ChatAvatar(
    @DrawableRes icon: Int,
    tint: Color,
    size: Dp = 44.dp,
    fill: Color = Tn.tile,
    edge: Color? = Tn.line,
    badge: Color? = null,
    spinner: Boolean = false,
    ground: Color = Tn.bg,
) {
    val shape = RoundedCornerShape(if (size >= 44.dp) 12.dp else 10.dp)
    val dot = if (size >= 44.dp) 12.dp else 11.dp
    Box(Modifier.size(size)) {
        Box(
            Modifier.fillMaxSize().clip(shape).background(fill).then(if (edge != null) Modifier.border(1.dp, edge, shape) else Modifier),
            contentAlignment = Alignment.Center,
        ) { Sym(icon, tint = tint, size = if (size >= 44.dp) 22.dp else 20.dp) }
        when {
            spinner -> Box(
                Modifier.align(Alignment.BottomEnd).offset(4.dp, 4.dp).size(14.dp).clip(CircleShape).background(ground),
                contentAlignment = Alignment.Center,
            ) { RingSpinner(10.dp, color = Tn.blue) }
            badge != null -> Box(
                Modifier.align(Alignment.BottomEnd).offset(3.dp, 3.dp).size(dot).clip(CircleShape).background(ground).padding(2.dp)
                    .clip(CircleShape).background(badge),
            )
        }
    }
}

// ───────────────────────── Thread ─────────────────────────

/**
 * The entries of the chat with the day over each new day, the newest at
 * the bottom, and the notices under them. The view follows the end. When
 * the user scrolls up, the view stays there, unless this phone sent the
 * new entry. [bottom] is the space under the last entry.
 */
@Composable
private fun ChatThread(chat: List<ChatItem>, bottom: Dp, notices: InboxNotices, actions: ChatActions) {
    val scroll = rememberScrollState()
    var follow by remember { mutableStateOf(true) }
    // Only the end of a scroll changes follow. A scroll by the user to the end follows again.
    LaunchedEffect(scroll) {
        snapshotFlow { scroll.isScrollInProgress }.drop(1).collect { moving ->
            if (!moving) follow = scroll.value >= scroll.maxValue - FOLLOW_SLACK_PX
        }
    }
    // While the view follows, it stays at the end when an entry or the view changes its height.
    LaunchedEffect(scroll) {
        snapshotFlow { scroll.maxValue }.collect { end ->
            if (follow && !scroll.isScrollInProgress && end in 1 until Int.MAX_VALUE) scroll.scrollTo(end)
        }
    }
    // While the view follows, it shows a new entry at the end. What this phone sent shows also after the user scrolled up.
    val last = chat.lastOrNull()
    LaunchedEffect(last?.key) {
        val mine = (last as? ChatLogItem)?.entry?.let { !it.incoming } == true
        if (follow || mine) {
            follow = true
            scroll.scrollTo(scroll.maxValue)
        }
    }
    val context = LocalContext.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize().verticalScroll(scroll).heightIn(min = maxHeight)
                .padding(start = 12.dp, end = 12.dp, top = 14.dp, bottom = bottom),
            verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.Bottom),
        ) {
            if (chat.isEmpty()) {
                T(
                    "Approvals and the files and clips from this computer show here. So do the photos, files, links, and text that you send.",
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp), size = 13, color = Tn.sub, align = TextAlign.Center, lineHeight = 1.4f,
                )
            }
            var day = -1L
            for (c in chat) {
                val d = dayOf(c.at)
                if (c.at > 0 && d != day) {
                    day = d
                    T(dayText(c.at), Modifier.fillMaxWidth().padding(vertical = 2.dp), size = 12, color = Tn.sub, align = TextAlign.Center)
                }
                key(c.key) {
                    when (c) {
                        is ChatLogItem -> LogEntry(c.entry, context)
                        is ChatEventItem -> when (val item = c.item) {
                            is ApprovalItem -> ApprovalCard(item.request, c.at, actions)
                            is PairItem -> PairCard(item.deviceId, item.computer, c.at, actions)
                            else -> Unit
                        }
                    }
                }
            }
            ChatNotices(notices, actions)
        }
    }
}

/**
 * The state of the links under the entries: that Flux connects, and the
 * notices with their next steps. [offline] is false when the screen shows
 * the computers that are not reachable already.
 */
@Composable
internal fun ChatNotices(notices: InboxNotices, actions: ChatActions, offline: Boolean = true) {
    if (notices.connecting && notices.reach.noneOnline) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Spinner(Modifier.size(16.dp), color = Tn.blue)
            T(connectingTitle(notices.reach), size = 13, color = Tn.sub)
        }
    }
    InboxNoticeList(notices, actions, offline = offline)
}

// ───────────────────────── Cards of the computers ─────────────────────────

/** The shape of a card from a computer: round, with a small corner at the bottom left. */
private val InShape = RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp, bottomEnd = 14.dp, bottomStart = 4.dp)

/** The part of the width that a card from a computer takes. A card that needs the user takes the full width. */
private const val IN_WIDTH = 0.88f

/**
 * A card from a computer, on the left: the [mark] and the [state] in
 * [color], the [source] in mono, and the [time] at the end. The [title]
 * and the [body] follow, then [content]. A card that needs the user
 * ([ask]) takes the full width and has a red border of 2 dp. [mono] sets
 * the title in mono, for a file name or a command. [action] is a text
 * action at the bottom. [shape] is the chat shape, or the tile shape in
 * the list of chats. TalkBack reads the top row as 1 line.
 */
@Composable
internal fun InCard(
    mark: @Composable () -> Unit,
    state: String,
    color: Color,
    source: String,
    time: String,
    title: String,
    body: String = "",
    mono: Boolean = false,
    ask: Boolean = false,
    progress: Float? = null,
    action: Pair<String, (() -> Unit)?>? = null,
    titleLines: Int = Int.MAX_VALUE,
    shape: Shape = InShape,
    content: @Composable ColumnScope.() -> Unit = {},
) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        Column(
            Modifier.width(if (ask) maxWidth else maxWidth * IN_WIDTH).clip(shape).background(Tn.tile)
                .border(if (ask) 2.dp else 1.dp, if (ask) Tn.red else Tn.line, shape)
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Row(
                Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = listOf(state, source, time).filter { it.isNotEmpty() }.joinToString(", ") },
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                mark()
                T(state, size = 12, color = color, weight = FontWeight.Medium, maxLines = 1)
                if (source.isNotEmpty()) T("· $source", Modifier.weight(1f), size = 12, color = Tn.sub, family = Mono, maxLines = 1) else Spacer(Modifier.weight(1f))
                T(time, size = 11, color = Tn.sub, family = Mono, maxLines = 1)
            }
            LineText(
                if (mono) breakAll(title) else title, size = 14f, lineHeight = 1.3f, weight = FontWeight.SemiBold,
                family = if (mono) Mono else androidx.compose.ui.text.font.FontFamily.Default, maxLines = titleLines,
            )
            if (body.isNotEmpty()) LineText(body, size = 12f, lineHeight = 1.4f, color = Tn.sub, family = Mono)
            if (progress != null) {
                Box(Modifier.padding(top = 2.dp).fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(Tn.line)) { LineFill(progress, Tn.blue) }
            }
            content()
            if (action != null) {
                val (label, onClick) = action
                // The action reaches 6 dp into the padding of the card, as in the design.
                if (onClick != null) {
                    TextAction(label, onClick, Modifier.overhangBottom(6.dp), size = 13, height = 32.dp, pad = 0.dp)
                } else {
                    Box(Modifier.overhangBottom(6.dp).heightIn(min = 32.dp), contentAlignment = Alignment.CenterStart) {
                        T(label, size = 13, color = Tn.blue, weight = FontWeight.SemiBold, maxLines = 1)
                    }
                }
            }
        }
    }
}

/** Lays out the element [by] shorter at the bottom, so that it reaches into the space under it. */
private fun Modifier.overhangBottom(by: Dp): Modifier = layout { m, c ->
    val p = m.measure(c)
    layout(p.width, (p.height - by.roundToPx()).coerceAtLeast(0)) { p.place(0, 0) }
}

/** A button of a card: [primary] has the accent fill, the other the tonal fill. It is [height] high. */
@Composable
private fun CardButton(label: String, modifier: Modifier, primary: Boolean, @DrawableRes icon: Int? = null, height: Dp = 48.dp, onClick: () -> Unit) {
    val ink = if (primary) Tn.onAccent else Tn.text
    Row(
        modifier.heightIn(min = height).clip(RoundedCornerShape(12.dp)).background(if (primary) Tn.blue else Tn.line)
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) Sym(icon, tint = ink, size = 19.dp)
        T(label, size = 14, color = ink, weight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** The time of a chat entry, such as 14:05, in the format of the phone. */
internal fun timeText(context: Context, at: Long): String =
    if (at <= 0) "" else android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(at))

/** "2:14" for [ms] milliseconds, or "1:02:14" from 1 hour. */
internal fun clockText(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

/**
 * A request that waits for the fingerprint, with Deny and Approve. Approve
 * opens the approval screen, which asks for the fingerprint. [list] shows
 * the card in the list of chats: the computer follows the service, the
 * corners are the tile corners, and the buttons are 44 dp high.
 */
@Composable
internal fun ApprovalCard(r: ApproveRequest, at: Long, actions: ChatActions, list: Boolean = false) {
    val context = LocalContext.current
    InCard(
        mark = { PulseDot(Tn.red, 8.dp) },
        state = "Needs approval",
        color = Tn.red,
        source = if (list) "${r.service} · ${r.computerName}" else r.service,
        time = timeText(context, at),
        title = if (r.kind == ApproveRequest.Kind.Approve) "Approve ${r.service} on ${r.host}?" else "Enroll this phone on ${r.host}?",
        body = approvalLine(r),
        ask = true,
        shape = if (list) TileShape else InShape,
    ) {
        Row(Modifier.fillMaxWidth().padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val height = if (list) 44.dp else 48.dp
            CardButton("Deny", Modifier.weight(1f), primary = false, height = height) {
                if (isDemo(r.computerId)) FluxCore.toast("This is a sample request") else Approvals.deny(FluxCore, r)
            }
            CardButton("Approve", Modifier.weight(1.6f), primary = true, icon = R.drawable.ic_fingerprint, height = height) { actions.approve(r) }
        }
    }
}

/** The user and the terminal of a request, such as "user dev · pts/3". */
private fun approvalLine(r: ApproveRequest): String = listOf("user ${r.user}", r.tty).filter { it.isNotBlank() }.joinToString(" · ")

/** A computer that asks to pair, with the key to compare. [list] shows the card in the list of chats. */
@Composable
internal fun PairCard(deviceId: String, computer: String, at: Long, actions: ChatActions, list: Boolean = false) {
    InCard(
        mark = { PulseDot(Tn.red, 8.dp) },
        state = "Pair request",
        color = Tn.red,
        source = "",
        time = timeText(LocalContext.current, at),
        title = "$computer asks to pair",
        body = "Compare the key on both screens.",
        ask = true,
        shape = if (list) TileShape else InShape,
    ) {
        CardButton("Compare the key", Modifier.fillMaxWidth().padding(top = 6.dp), primary = true, height = if (list) 44.dp else 48.dp) { actions.showPair(deviceId) }
    }
}

// ───────────────────────── Log entries ─────────────────────────

/** An entry of the chat log: a card from the computer, or a bubble, a photo, or a file card of this phone. */
@Composable
private fun LogEntry(e: SendEntry, context: Context) {
    when {
        e.kind == SendKind.Approved || e.kind == SendKind.Denied -> ApprovalResult(e, context)
        e.incoming && e.kind == SendKind.File -> ReceivedFile(e, context)
        e.incoming -> ReceivedClip(e, context)
        e.kind == SendKind.File && e.uri.isNotEmpty() && fileIcon(e.text, false) == Ic.image -> SentPhoto(e, sendMeta(context, e))
        e.kind == SendKind.File || e.kind == SendKind.ClipImage -> SentFile(e, sendMeta(context, e))
        else -> SentBubble(e.text, sendMeta(context, e), mono = e.kind != SendKind.Text)
    }
}

/** A file from a computer: its progress while it comes in, then Open. */
@Composable
private fun ReceivedFile(e: SendEntry, context: Context) {
    val pct = "${(e.progress * 100).toInt()}% of ${bytes(e.size)}"
    InCard(
        mark = {
            when (e.state) {
                TransferState.Running -> RingSpinner(11.dp, color = Tn.blue)
                TransferState.Done -> Dot(Tn.green, 8.dp)
                TransferState.Failed -> Dot(Tn.red, 8.dp)
            }
        },
        state = when (e.state) {
            TransferState.Running -> "Receiving"
            TransferState.Done -> "Received"
            TransferState.Failed -> "Not received"
        },
        color = when (e.state) {
            TransferState.Running -> Tn.blue
            TransferState.Done -> Tn.green
            TransferState.Failed -> Tn.red
        },
        source = "file",
        time = timeText(context, e.at),
        title = e.text,
        mono = true,
        body = when (e.state) {
            TransferState.Running -> pct
            TransferState.Done -> if (e.size > 0) "In Downloads · ${bytes(e.size)}" else "In Downloads"
            TransferState.Failed -> "Send it again from ${e.computer}"
        },
        progress = if (e.state == TransferState.Running) e.progress else null,
        action = if (e.state == TransferState.Done) "Open" to { openReceived(context, e) } else null,
    )
}

/** Opens a received file, or Downloads when the chat does not know the file or no app opens it. */
private fun openReceived(context: Context, e: SendEntry) {
    val downloads = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    val view = e.uri.takeIf { it.isNotEmpty() }?.let {
        Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(it), Android.mimeType(e.text) ?: "*/*")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    if (view != null && runCatching { context.startActivity(view) }.isSuccess) return
    runCatching { context.startActivity(downloads) }
}

/** The clip that a computer sent. It is on the clipboard of this phone already, so Copy puts it back after another copy. */
@Composable
private fun ReceivedClip(e: SendEntry, context: Context) {
    var copied by remember { mutableStateOf(false) }
    val image = e.kind == SendKind.ClipImage
    // A text that the log cut is not the whole clip, so it cannot go back on the clipboard.
    val whole = !image && e.text.length < SEND_TEXT_MAX
    InCard(
        mark = { Sym(Ic.paste, tint = Tn.cyan, size = 14.dp) },
        state = "Clipboard",
        color = Tn.cyan,
        source = "from ${e.computer}",
        time = timeText(context, e.at),
        title = if (image) "An image" else e.text,
        mono = !image,
        titleLines = 4,
        action = if (!whole) {
            null
        } else if (copied) {
            "Copied" to null
        } else {
            "Copy" to {
                if (Plugins.putRemoteText(FluxCore, e.computer, e.text)) {
                    copied = true
                    FluxCore.toast("Copied to this phone")
                }
            }
        },
    )
}

/** The answer of this phone to a request. */
@Composable
private fun ApprovalResult(e: SendEntry, context: Context) {
    val r = e.approval
    val ok = e.kind == SendKind.Approved
    val enroll = r?.kind == ApproveRequest.Kind.Enroll
    val host = r?.host.orEmpty()
    InCard(
        mark = { Dot(if (ok) Tn.green else Tn.sub, 8.dp) },
        state = if (enroll && ok) "Enrolled" else if (ok) "Approved" else "Denied",
        color = if (ok) Tn.green else Tn.sub,
        source = e.text,
        time = timeText(context, e.at),
        title = when {
            enroll && ok -> "Enrolled this phone on $host"
            enroll -> "Denied the enrollment on $host"
            else -> (if (ok) "Approved " else "Denied ") + e.text + (r?.user?.let { " for $it" } ?: "")
        },
        body = r?.let(::approvalLine).orEmpty(),
    )
}

/** The shape of text that this phone sent: round, with a small corner at the bottom right. */
private val OutShape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp, bottomEnd = 4.dp, bottomStart = 16.dp)

/** Text, a link, or a clip that went out: a bubble at the right, with [meta] under it. Text is in the body face, and a link or a clip in mono. */
@Composable
private fun SentBubble(text: String, meta: String, mono: Boolean = true) {
    BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
        Column(Modifier.widthIn(max = maxWidth * 0.82f), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            SelectionContainer {
                LineText(
                    if (mono) breakAll(text) else text,
                    Modifier.clip(OutShape).background(Tn.accentTile).border(1.dp, Tn.lineHi, OutShape).padding(horizontal = 14.dp, vertical = 8.dp),
                    size = if (mono) 12.5f else 14f, lineHeight = if (mono) 1.45f else 1.4f, family = if (mono) Mono else androidx.compose.ui.text.font.FontFamily.Default,
                )
            }
            T(meta, size = 11, color = Tn.sub)
        }
    }
}

/** The shape of a file or a photo that this phone sent. */
private val OutFileShape = RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp, bottomEnd = 4.dp, bottomStart = 14.dp)

/** A file or an image clip that went out: a card of 236 dp at the right with its icon, its name, and [meta], and a bar while it runs. */
@Composable
private fun SentFile(e: SendEntry, meta: String) {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
        Column(
            Modifier.width(236.dp).clip(OutFileShape).background(Tn.accentTile).border(1.dp, Tn.lineHi, OutFileShape).padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Sym(if (e.kind == SendKind.ClipImage) Ic.image else sendFileIcon(e.text), tint = Tn.blue, size = 22.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    T(if (e.kind == SendKind.ClipImage) "Image" else e.text, size = 13, weight = FontWeight.Medium, family = Mono, maxLines = 1)
                    T(meta, size = 12, color = if (e.state == TransferState.Failed) Tn.red else Tn.sub)
                }
                TransferMark(e.state)
            }
            if (e.state == TransferState.Running) {
                Box(Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(Tn.line)) { LineFill(e.progress, Tn.blue) }
            }
        }
    }
}

/** The state of a file that went out: a spinner while it runs, then a check or a cross. */
@Composable
private fun TransferMark(state: TransferState) {
    when (state) {
        TransferState.Running -> RingSpinner(14.dp, color = Tn.blue)
        TransferState.Done -> Sym(Ic.check, "Done", tint = Tn.green, size = 18.dp)
        TransferState.Failed -> Sym(Ic.close, "Failed", tint = Tn.red, size = 18.dp)
    }
}

/**
 * A photo that went out: the picture, 220 by 132 dp, at the right, with
 * its name on it and [meta] under it. A bar shows while it runs. Without
 * the picture, the name shows on stripes.
 */
@Composable
private fun SentPhoto(e: SendEntry, meta: String) {
    val picture = rememberThumbnail(e.uri, 440)
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(
            Modifier.size(220.dp, 132.dp).clip(OutFileShape).background(Tn.tile).border(1.dp, Tn.lineHi, OutFileShape)
                .semantics { contentDescription = "Photo ${e.text}" },
        ) {
            if (picture != null) {
                Image(picture, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            } else {
                Stripes(Modifier.fillMaxSize())
            }
            Row(
                Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                T(e.text, Modifier.weight(1f).clip(RoundedCornerShape(4.dp)).background(Tn.bg.copy(alpha = 0.7f)).padding(horizontal = 4.dp), size = 11, color = Tn.sub, family = Mono, maxLines = 1)
                if (e.state != TransferState.Done) TransferMark(e.state)
            }
            if (e.state == TransferState.Running) {
                Box(Modifier.align(Alignment.TopStart).fillMaxWidth().height(3.dp).background(Tn.line)) { LineFill(e.progress, Tn.blue) }
            }
        }
        T(meta, size = 11, color = if (e.state == TransferState.Failed) Tn.red else Tn.sub)
    }
}

/** The icon of a file that went out: an image, or a document. */
@DrawableRes
private fun sendFileIcon(name: String): Int = if (fileIcon(name, false) == Ic.image) Ic.image else Ic.textFile

/** The line under a send, such as "Link · opened in the browser · 13:20". */
private fun sendMeta(context: Context, e: SendEntry): String {
    val time = timeText(context, e.at)
    val pct = "${(e.progress * 100).toInt()}% of ${bytes(e.size)}"
    val photo = fileIcon(e.text, false) == Ic.image
    return when (e.kind) {
        SendKind.Link -> "Link · opened in the browser · $time"
        SendKind.Text -> "Text · on the clipboard · $time"
        SendKind.Scan -> "Scan · saved as a text file · $time"
        SendKind.Clip, SendKind.ClipImage -> "Clipboard · $time"
        SendKind.File -> when (e.state) {
            TransferState.Running -> (if (photo) "Photo · sending" else "Sending") + " · $pct"
            TransferState.Done -> (if (photo) "Photo · sent" else "Sent") + " · $time"
            TransferState.Failed -> "Not sent · $time"
        }
        SendKind.Approved, SendKind.Denied -> time
    }
}

/** The day of [at] as a number, to find the first entry of each day. */
internal fun dayOf(at: Long): Long {
    val c = Calendar.getInstance().apply { timeInMillis = at }
    return c.get(Calendar.YEAR) * 1000L + c.get(Calendar.DAY_OF_YEAR)
}

/** "Today", "Yesterday", or the date of [at]. */
private fun dayText(at: Long): String {
    val now = System.currentTimeMillis()
    return when (dayOf(at)) {
        dayOf(now) -> "Today"
        dayOf(now - 24 * 60 * 60_000L) -> "Yesterday"
        else -> java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(java.util.Date(at))
    }
}

/**
 * Text that breaks at any character, as a link or a command in mono does in
 * the design. A zero-width space goes between 2 characters that are not
 * white space.
 */
internal fun breakAll(text: String): String {
    val b = StringBuilder(text.length * 2)
    var i = 0
    while (i < text.length) {
        val n = Character.charCount(text.codePointAt(i))
        if (i > 0 && !text[i].isWhitespace() && !text[i - 1].isWhitespace()) b.append('​')
        b.append(text, i, i + n)
        i += n
    }
    return b.toString()
}

// ───────────────────────── Dock ─────────────────────────

/**
 * The dock of the chat of a computer: the clipboard of this phone with
 * Send, the composer, and the tray under it while [trayOpen]. The + key of
 * the composer opens and closes the tray. The photos that the tray selects
 * go out with the send key. [entries] tell whether the clip went out
 * already.
 */
@Composable
private fun ChatDock(
    shape: DockShape,
    d: DeviceUi,
    entries: List<SendEntry>,
    actions: ChatActions,
    trayOpen: Boolean,
    onTray: (Boolean) -> Unit,
) {
    val clip = rememberPhoneClip()
    val photos = remember(d.id) { mutableStateListOf<Uri>() }
    val on = d.online
    Column(
        Modifier.fillMaxWidth().dockFrame(shape).padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        ClipRow(clip, entries, enabled = on) { Plugins.sendClipboard(FluxCore, d.id) }
        ChatComposer(
            enabled = on,
            placeholder = "Message ${d.name}",
            trayOpen = trayOpen,
            onTray = onTray,
            selected = photos.size,
            onSend = { text ->
                if (photos.isNotEmpty()) {
                    if (isDemo(d.id)) FluxCore.toast("This is a sample computer") else Share.sendFiles(FluxCore, d.id, photos.toList())
                    photos.clear()
                    onTray(false)
                }
                if (text.isNotEmpty()) {
                    if (isDemo(d.id)) FluxCore.toast("This is a sample computer") else Share.sendText(FluxCore, d.id, text)
                }
            },
        )
        AnimatedVisibility(
            trayOpen,
            enter = expandVertically(expandFrom = Alignment.Top) + fadeIn(),
            exit = shrinkVertically(shrinkTowards = Alignment.Top) + fadeOut(),
        ) {
            ChatTray(d, photos, actions, onClose = { onTray(false) })
        }
    }
}

/**
 * The clipboard of this phone and its Send action, 40 dp high: the icon,
 * where the clip came from, its text on 1 line in mono, and Send. After a
 * send, the action shows Sent.
 */
@Composable
private fun ClipRow(clip: PhoneClip, entries: List<SendEntry>, enabled: Boolean, onClip: () -> Unit) {
    val now by rememberTicker(30_000L)
    val sent = clip.stamp.takeIf { it != 0L }?.let { s -> entries.lastOrNull { it.clipStamp == s } }
    val context = LocalContext.current
    Row(
        Modifier.fillMaxWidth().heightIn(min = 40.dp).clip(RoundedCornerShape(10.dp)).background(Tn.bg).padding(start = 10.dp, end = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(Ic.paste, tint = Tn.cyan, size = 18.dp)
        Column(Modifier.weight(1f).padding(vertical = 4.dp)) {
            val meta = when {
                sent != null -> "Clipboard · sent at ${timeText(context, sent.at)}"
                clip.empty -> "Clipboard on this phone · empty"
                clip.from != null -> "Clipboard from ${clip.from}" + (if (clip.stamp > 0) " · ${agoText(clip.stamp, now)}" else "")
                clip.stamp > 0 -> "Clipboard on this phone · ${agoText(clip.stamp, now)}"
                else -> "Clipboard on this phone"
            }
            T(meta, size = 10, color = Tn.cyan, weight = FontWeight.Medium, maxLines = 1)
            val text = clip.text
            if (text != null) {
                T(text.replace('\n', ' '), Modifier.clearAndSetSemantics { contentDescription = text }, size = 12, family = Mono, maxLines = 1)
            } else {
                T(
                    when {
                        clip.image -> "An image"
                        clip.hidden -> "Hidden, because its app marks it as private"
                        else -> "Copy text or an image on this phone"
                    },
                    size = 12, color = Tn.sub, maxLines = 1,
                )
            }
        }
        val can = enabled && !clip.empty
        Box(
            Modifier.heightIn(min = 32.dp).alpha(if (can) 1f else DimAlpha).clip(RoundedCornerShape(8.dp))
                .clickable(enabled = can, onClickLabel = "Send the clipboard", role = Role.Button) {
                    if (sent != null) FluxCore.toast("The clip is on ${sent.computer} already") else onClip()
                }
                .padding(horizontal = 10.dp),
            contentAlignment = Alignment.Center,
        ) {
            T(if (sent != null) "Sent" else "Send", size = 13, color = if (sent != null) Tn.sub else Tn.blue, weight = FontWeight.SemiBold)
        }
    }
}

/**
 * The composer: the + key, the field, the mic key, and the send key. A web
 * link opens in the browser of the computer, and other text goes to its
 * clipboard. The + key opens the tray, and while the tray is open it is an
 * accent key with a cross that closes it. When the field takes the focus,
 * the tray closes and the + key hides, so the field takes its width, and
 * the field grows to 6 lines. With text, the field shows the key of the
 * large editor. The send key shows the number of [selected] photos. The
 * words of a dictation go in at the cursor.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ChatComposer(
    enabled: Boolean,
    placeholder: String,
    trayOpen: Boolean,
    onTray: (Boolean) -> Unit,
    selected: Int,
    onSend: (String) -> Unit,
) {
    var field by rememberSaveable(stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue()) }
    var focused by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    // The field gives up the focus when the keyboard closes, so the + key comes back.
    val ime = WindowInsets.isImeVisible
    var imeSeen by remember { mutableStateOf(false) }
    LaunchedEffect(ime) {
        if (ime) {
            imeSeen = true
        } else if (imeSeen) {
            imeSeen = false
            focusManager.clearFocus()
        }
    }
    // The tray and the keyboard take the same place, so 1 closes the other.
    LaunchedEffect(focused) { if (focused) onTray(false) }
    LaunchedEffect(trayOpen) { if (trayOpen) focusManager.clearFocus() }
    val voice = rememberVoiceTyping { spoken ->
        val e = DictationText.insert(field.text, field.selection.start, field.selection.end, spoken)
        field = TextFieldValue(e.text, TextRange(e.cursor))
    }
    val can = enabled && (field.text.isNotBlank() || selected > 0)
    val send = {
        if (can) {
            onSend(field.text.trim())
            field = TextFieldValue()
            editing = false
        }
    }
    val shape = RoundedCornerShape(24.dp)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        // The + key also hides while the phone listens, so the panel of the dictation takes the width.
        AnimatedVisibility(
            !focused && voice.dictation.phase == Dictation.Phase.Idle,
            enter = fadeIn() + expandHorizontally(expandFrom = Alignment.Start),
            exit = fadeOut() + shrinkHorizontally(shrinkTowards = Alignment.Start),
        ) {
            val label = if (trayOpen) "Close the photos and tools" else "Photos, files, and tools"
            Box(
                Modifier.padding(end = 8.dp).size(48.dp).clip(CircleShape).background(if (trayOpen) Tn.blue else Tn.line)
                    .clickable(onClickLabel = label, role = Role.Button) { onTray(!trayOpen) }
                    .semantics { contentDescription = label },
                contentAlignment = Alignment.Center,
            ) { Sym(if (trayOpen) Ic.close else Ic.add, tint = if (trayOpen) Tn.onAccent else Tn.text, size = 24.dp) }
        }
        VoiceField(
            voice, Modifier.weight(1f), enabled = enabled, round = true,
            send = {
                val label = when (selected) {
                    0 -> "Send"
                    1 -> "Send 1 photo"
                    else -> "Send $selected photos"
                }
                Box(Modifier.size(48.dp)) {
                    Box(
                        Modifier.fillMaxSize().clip(CircleShape).background(if (can) Tn.blue else Tn.line)
                            .clickable(enabled = can, onClickLabel = label, role = Role.Button, onClick = send)
                            .semantics { contentDescription = label },
                        contentAlignment = Alignment.Center,
                    ) { Sym(Ic.up, tint = if (can) Tn.onAccent else Tn.sub, size = 22.dp) }
                    if (selected > 0) {
                        Box(
                            Modifier.align(Alignment.TopEnd).offset(2.dp, (-2).dp).size(18.dp).clip(CircleShape).background(Tn.text)
                                .clearAndSetSemantics {},
                            contentAlignment = Alignment.Center,
                        ) { T("$selected", size = 11, color = Tn.onAccent, weight = FontWeight.Bold, maxLines = 1) }
                    }
                }
            },
        ) { m ->
            BasicTextField(
                value = field,
                onValueChange = { field = it },
                modifier = m.focusRequester(focus).onFocusChanged { focused = it.isFocused }.semantics { contentDescription = placeholder },
                enabled = enabled,
                textStyle = TextStyle(color = Tn.text, fontSize = 14.sp, lineHeight = 20.sp),
                cursorBrush = SolidColor(Tn.blue),
                maxLines = if (focused) 6 else 4,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { send() }),
                decorationBox = { inner ->
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(shape).background(Tn.bg)
                            .border(1.dp, if (focused) Tn.blue else Tn.lineHi, shape)
                            .padding(start = 16.dp, end = if (field.text.isEmpty()) 16.dp else 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.weight(1f).padding(vertical = 14.dp)) {
                            if (field.text.isEmpty()) T(placeholder, Modifier.clearAndSetSemantics {}, size = 14, color = Tn.sub, maxLines = 1)
                            inner()
                        }
                        // Only the key of the large editor shows, so the text keeps the width. The editor has Clear.
                        if (field.text.isNotEmpty()) ExpandKey({ editing = true })
                    }
                },
            )
        }
    }
    if (editing) {
        FieldEditor(
            title = placeholder,
            value = field,
            onValueChange = { field = it },
            onDismiss = { editing = false },
            placeholder = placeholder,
            keyboard = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
        ) {
            FluxButton("Send", { send() }, enabled = can)
        }
    }
}

// ───────────────────────── Clipboard ─────────────────────────

/**
 * The clipboard of this phone for the dock. [text] is null for an image, a
 * clip that its app marks as private ([hidden]), or an empty clipboard.
 * [from] names the computer when the clip came from Flux. [stamp] is the
 * time that Android set on the clip.
 */
internal data class PhoneClip(
    val text: String? = null,
    val image: Boolean = false,
    val hidden: Boolean = false,
    val stamp: Long = 0,
    val from: String? = null,
) {
    val empty: Boolean get() = text == null && !image && !hidden
}

/** The last clip that the dock read. A clip with the same time comes from here, so that Android shows its paste notice once for each clip. */
private var lastClip: PhoneClip? = null

/**
 * Reads the clipboard of this phone. Android lets the app read it only
 * while the window has focus, so the dock reads it again when the window
 * gets the focus, when the app comes back, and when the clip changes.
 */
@Composable
private fun rememberPhoneClip(): PhoneClip {
    val context = LocalContext.current
    val focused = LocalWindowInfo.current.isWindowFocused
    var clip by remember { mutableStateOf(lastClip ?: PhoneClip()) }
    LaunchedEffect(focused) { if (focused) clip = readClip(context) }
    LifecycleResumeEffect(context) {
        clip = readClip(context)
        onPauseOrDispose { }
    }
    DisposableEffect(context) {
        val cm = context.getSystemService(ClipboardManager::class.java)
        val listener = ClipboardManager.OnPrimaryClipChangedListener { clip = readClip(context) }
        cm?.addPrimaryClipChangedListener(listener)
        onDispose { cm?.removePrimaryClipChangedListener(listener) }
    }
    return clip
}

private fun readClip(context: Context): PhoneClip {
    val cm = context.getSystemService(ClipboardManager::class.java) ?: return PhoneClip()
    val desc = runCatching { cm.primaryClipDescription }.getOrNull() ?: return PhoneClip().also { lastClip = it }
    val stamp = Android.clipTimestamp(context)
    lastClip?.let { if (stamp != 0L && it.stamp == stamp) return it }
    // Flux puts the clip of a computer on the clipboard with its own label.
    val from = InboxFeed.clip.value?.takeIf { !it.sent && desc.label?.toString() == "Flux" }?.computer
    val read = when {
        desc.hasMimeType("image/*") -> PhoneClip(image = true, stamp = stamp, from = from)
        Android.clipboardSensitive(context) -> PhoneClip(hidden = true, stamp = stamp)
        else -> {
            // Without the focus, Android gives no text. The next read gets it.
            val text = Android.clipboardText(context, automatic = true)?.takeIf { it.isNotBlank() } ?: return PhoneClip(stamp = stamp)
            PhoneClip(text = text.trim().take(400), stamp = stamp, from = from)
        }
    }
    lastClip = read
    return read
}
