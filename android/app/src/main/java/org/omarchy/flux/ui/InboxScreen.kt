package org.omarchy.flux.ui

import android.app.DownloadManager
import android.content.Intent
import android.text.format.DateUtils
import androidx.annotation.DrawableRes
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlin.math.abs
import kotlinx.coroutines.delay
import org.omarchy.flux.core.AgentChoice
import org.omarchy.flux.core.AgentItem
import org.omarchy.flux.core.ApprovalItem
import org.omarchy.flux.core.Approvals
import org.omarchy.flux.core.ApproveMessage
import org.omarchy.flux.core.ApproveRequest
import org.omarchy.flux.core.ClipItem
import org.omarchy.flux.core.DebugDemo
import org.omarchy.flux.core.DebugFirstRun
import org.omarchy.flux.core.DebugInbox
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.HerdrOutput
import org.omarchy.flux.core.HerdrSync
import org.omarchy.flux.core.InboxFeed
import org.omarchy.flux.core.InboxItem
import org.omarchy.flux.core.InboxKind
import org.omarchy.flux.core.MediaItem
import org.omarchy.flux.core.PairItem
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.core.TransferItem
import org.omarchy.flux.core.TransferState
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.agentPrompt
import org.omarchy.flux.core.inboxItems
import org.omarchy.flux.core.needsYou

/**
 * The Inbox items of all computers, ranked. Old finished items leave each
 * minute. A debug build with the demo adds the samples of [DebugInbox].
 */
@Composable
fun rememberInboxItems(state: UiState): List<InboxItem> {
    val approval by Approvals.current.collectAsStateWithLifecycle()
    val transfers by InboxFeed.transfers.collectAsStateWithLifecycle()
    val clip by InboxFeed.clip.collectAsStateWithLifecycle()
    val playedAt by InboxFeed.playedAt.collectAsStateWithLifecycle()
    val now by rememberClock()
    // A paused player stays for a time after it played, so the Inbox records the players that play.
    LaunchedEffect(state.devices, now) { InboxFeed.seePlayers(state.devices, now) }
    // The first run and the pairing success state of a debug build show no samples.
    val demo = org.omarchy.flux.BuildConfig.DEBUG && DebugDemo.on && DebugFirstRun.mode == DebugFirstRun.Mode.Off
    return remember(state.devices, approval, transfers, clip, playedAt, now, demo) {
        val a = approval ?: if (demo) DebugInbox.approval() else null
        val t = if (demo) transfers + DebugInbox.transfers() else transfers
        val c = clip ?: if (demo) DebugInbox.clip() else null
        inboxItems(state.devices, a, t, c, now, playedAt)
    }
}

/** The step of [rememberClock], in milliseconds. */
private const val CLOCK_MS = 60_000L

/** The time in milliseconds since the epoch. It changes each minute while the app is in the foreground, and when it comes back. */
@Composable
private fun rememberClock(): State<Long> {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    return produceState(System.currentTimeMillis(), lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                value = System.currentTimeMillis()
                delay(CLOCK_MS)
            }
        }
    }
}

/**
 * What the Inbox items and notices do: open screens, the approval screen,
 * and the pair sheet, pair a computer, show all computers, and ask for the
 * notifications. [pair] starts the pairing that this phone sends, as in
 * Computers.
 */
class InboxActions(
    val open: (Route) -> Unit,
    val approve: (ApproveRequest) -> Unit,
    val showPair: (String) -> Unit,
    val pair: (DeviceUi) -> Unit,
    val computers: () -> Unit,
    val tools: SendTools,
    val showAll: () -> Unit,
    val allowNotifications: () -> Unit,
    val hideNotifications: () -> Unit,
)

/**
 * The Inbox: 1 list of what happens on the computers in scope. The first
 * item is the master tile, at about 55% of the height, with its whole
 * action. The other items wait in a stack of 2 columns. A swipe on the
 * master moves it to the end of the stack, and a tap on a stack tile moves
 * that tile to the master. [items] are in the order of the user. [notices]
 * tell what the Inbox cannot show. [active] is false while the screen
 * moves, so that it reads nothing new then.
 */
@Composable
fun InboxScreen(
    state: UiState,
    items: List<InboxItem>,
    active: Boolean,
    notices: InboxNotices,
    actions: InboxActions,
    onSwipe: (String) -> Unit,
    onPromote: (String) -> Unit,
) {
    // The computers send their changes. A new visit asks again for the agents and the players.
    LaunchedEffect(active) {
        if (!active) return@LaunchedEffect
        for (d in state.devices) {
            if (!d.paired || !d.online || isDemo(d.id)) continue
            if (d.herdrSupported) HerdrSync.request(FluxCore, d.id)
            Plugins.requestPlayers(FluxCore, d.id)
        }
    }
    if (items.isEmpty()) {
        InboxEmpty(state, notices, actions)
        return
    }
    val reduce = LocalReduceMotion.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val masterMin = maxHeight * 0.55f
        val needs = items.needsYou()
        LazyVerticalGrid(
            columns = GridCells.Fixed(2),
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = TiledGutter, end = TiledGutter, bottom = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(TileGap),
            verticalArrangement = Arrangement.spacedBy(TileGap),
        ) {
            item(key = "status", span = { GridItemSpan(maxLineSpan) }) { InboxStatus(needs, notices, actions) }
            val master = items.first()
            item(key = master.key, span = { GridItemSpan(maxLineSpan) }, contentType = "master") {
                MasterTile(
                    master, state.devices, active, actions,
                    canSwipe = items.size > 1,
                    onSwipe = { onSwipe(master.key) },
                    modifier = Modifier
                        .animateItem(fadeInSpec = shellMotion(reduce), placementSpec = shellMotion(reduce), fadeOutSpec = shellMotion(reduce))
                        .heightIn(min = masterMin),
                )
            }
            items(items.drop(1), key = { it.key }, contentType = { "stack" }) { item ->
                StackTile(
                    item,
                    Modifier.animateItem(fadeInSpec = shellMotion(reduce), placementSpec = shellMotion(reduce), fadeOutSpec = shellMotion(reduce)),
                ) { onPromote(item.key) }
            }
        }
    }
}

/** The lines above the master: how many items need the user, then the notices. */
@Composable
private fun InboxStatus(needs: Int, notices: InboxNotices, actions: InboxActions) {
    Column(Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 2.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (needs > 0) {
                Dot(Tn.red)
                T(if (needs == 1) "1 item needs you" else "$needs items need you", size = 14, weight = FontWeight.SemiBold)
            } else {
                T(nothingText(notices), size = 14, color = Tn.sub)
            }
        }
        InboxNoticeList(notices, actions)
    }
}

/** What the large tile of an empty Inbox shows. */
private sealed interface EmptyMode {
    /** No computer is paired: the pairing guide. */
    data object Guide : EmptyMode

    /** A new pairing: the success state of the computer [name]. */
    data class Paired(val name: String) : EmptyMode

    /** No computer in scope is reachable. */
    data object Offline : EmptyMode

    /** Nothing needs the user. */
    data object Clear : EmptyMode
}

/**
 * The Inbox with no items: what shows here, and the 2 most used actions.
 * Before the first pairing, it shows the pairing guide. After a new
 * pairing, it shows the success state for a short time. When no computer
 * in scope is reachable, it says so and offers Retry, so that an empty
 * Inbox is not a false all-clear. The large tile changes with a crossfade.
 */
@Composable
private fun InboxEmpty(state: UiState, notices: InboxNotices, actions: InboxActions) {
    val paired = state.devices.any { it.paired }
    val offline = paired && notices.reach.noneOnline
    val welcome = notices.paired
    val mode = when {
        !paired -> EmptyMode.Guide
        offline -> EmptyMode.Offline
        welcome != null -> EmptyMode.Paired(welcome)
        else -> EmptyMode.Clear
    }
    val fade = shellMotion<Float>(LocalReduceMotion.current) ?: snap()
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter).padding(top = 4.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(TileGap),
    ) {
        Crossfade(mode, animationSpec = fade, label = "empty") { m ->
            when (m) {
                EmptyMode.Guide -> PairGuide(state, actions)
                is EmptyMode.Paired -> PairedTile(m.name)
                EmptyMode.Offline -> EmptyTile {
                    Sym(if (state.onWifi) Ic.wifiFind else Ic.wifiOff, tint = Tn.yellow, size = 28.dp)
                    T(offlineTitle(notices.reach), size = 22, weight = FontWeight.SemiBold)
                    T(offlineHint(state.onWifi), size = 14, color = Tn.sub, lineHeight = 1.35f)
                    T("The Inbox shows what waits on a computer only while the computer is reachable.", size = 14, color = Tn.sub, lineHeight = 1.35f)
                    Button(onClick = { FluxCore.rediscover() }, modifier = Modifier.padding(top = 4.dp).heightIn(min = 48.dp)) {
                        Sym(Ic.refresh, size = 18.dp)
                        Spacer(Modifier.size(8.dp))
                        Text("Retry")
                    }
                }
                EmptyMode.Clear -> EmptyTile {
                    T(nothingText(notices), size = 22, weight = FontWeight.SemiBold)
                    T(
                        "Agents that wait for you, approvals, and pair requests show here first. Transfers, the clipboard, and what plays now follow.",
                        size = 14, color = Tn.sub, lineHeight = 1.35f,
                    )
                }
            }
        }
        if (paired) {
            InboxNoticeList(notices, actions, offline = !offline, paired = mode !is EmptyMode.Paired)
            // With no computer online, the tiles show dimmed, so that the Inbox still teaches them.
            EqualRow {
                ActionTile(
                    Ic.pasteGo, "Send clipboard", Modifier.weight(1f).fillMaxHeight(),
                    sub = "Paste it on the computer", enabled = !offline, onClick = actions.tools.sendClipboard,
                )
                ActionTile(
                    Ic.sendFiles, "Send files", Modifier.weight(1f).fillMaxHeight(),
                    accent = Tn.magenta, sub = "Pick files on this phone", enabled = !offline, onClick = actions.tools.sendFiles,
                )
            }
        }
    }
}

// ───────────────────────── Master ─────────────────────────

/**
 * The master tile, framed with the active border. A swipe to the side, the
 * Later button, or the TalkBack action moves it to the end of the stack.
 */
@Composable
private fun MasterTile(
    item: InboxItem,
    devices: List<DeviceUi>,
    active: Boolean,
    actions: InboxActions,
    canSwipe: Boolean,
    onSwipe: () -> Unit,
    modifier: Modifier,
) {
    val reduce = LocalReduceMotion.current
    var offset by remember(item.key) { mutableFloatStateOf(0f) }
    var width by remember { mutableIntStateOf(1) }
    val drag = rememberDraggableState { offset += it }
    var m = modifier.onSizeChanged { width = it.width.coerceAtLeast(1) }.graphicsLayer {
        translationX = offset
        alpha = 1f - 0.6f * (abs(offset) / width).coerceIn(0f, 1f)
    }
    if (canSwipe) {
        m = m.draggable(
            drag, Orientation.Horizontal,
            onDragStopped = { velocity ->
                val w = width.toFloat()
                if (abs(offset) > w * 0.3f || abs(velocity) > 1500f) {
                    val to = if (offset + velocity * 0.05f >= 0f) w else -w
                    if (!reduce) animate(offset, to, animationSpec = tween(MOTION_MS, easing = FastOutSlowInEasing)) { x, _ -> offset = x }
                    onSwipe()
                } else if (reduce) {
                    offset = 0f
                } else {
                    animate(offset, 0f, animationSpec = tween(MOTION_MS, easing = FastOutSlowInEasing)) { x, _ -> offset = x }
                }
            },
        ).semantics {
            customActions = listOf(
                CustomAccessibilityAction("Show the next item") {
                    onSwipe()
                    true
                },
            )
        }
    }
    val header: @Composable () -> Unit = { MasterHeader(item, canSwipe, onSwipe) }
    Tile(m, border = activeBorder(), padding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.Top)) {
        val d = devices.firstOrNull { it.id in item.deviceIds }
        when (item) {
            is AgentItem -> AgentMaster(item, d, active, header, actions)
            is ApprovalItem -> ApprovalMaster(item, header, actions)
            is PairItem -> PairMaster(item, header, actions)
            is TransferItem -> TransferMaster(item, header)
            is ClipItem -> ClipMaster(item, header, actions)
            is MediaItem -> MediaMaster(item, d, header, actions)
        }
    }
}

/**
 * The state label and the Later button of the master tile, with the
 * computer on its own line. A long computer name does not push the label
 * or the button out of the row.
 */
@Composable
private fun MasterHeader(item: InboxItem, canSwipe: Boolean, onSwipe: () -> Unit) {
    val color = kindColor(item)
    Column {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Dot(color)
            TileLabel(kindLabel(item), Modifier.weight(1f), color = color)
            if (canSwipe) TextButton(onClick = onSwipe) { Text("Later") }
        }
        T(item.computer, size = 12, color = Tn.sub, family = Mono, maxLines = 1)
    }
}

/** The space between the top and the bottom part of the master, so that the actions sit at thumb height. */
@Composable
private fun ColumnScope.Push() = Spacer(Modifier.weight(1f))

@Composable
private fun ColumnScope.AgentMaster(item: AgentItem, d: DeviceUi?, active: Boolean, header: @Composable () -> Unit, actions: InboxActions) {
    val a = item.agent
    val pane = a.pane
    val blocked = item.kind == InboxKind.AgentInput
    val demo = isDemo(item.deviceId)
    val out = d?.herdrOutput?.takeIf { it.pane == pane }
    // The output gives the question and the choices. The tile reads it again
    // when it shows, because an output from before can hold an older question.
    // The agent screen forgets the output when it closes, so the tile reads it again then too.
    val missing = out == null
    var stale by remember(item.key) { mutableStateOf<HerdrOutput?>(null) }
    var asked by remember(item.key) { mutableStateOf(false) }
    LaunchedEffect(active, item.deviceId, pane, missing) {
        if (!active || !blocked || demo || d?.online != true || (asked && !missing)) return@LaunchedEffect
        stale = out
        asked = true
        HerdrSync.read(FluxCore, item.deviceId, pane)
    }
    // Only an output that came after the read of this tile shows. It is a new object.
    val fresh = out != null && !out.loading && out.error == null && (demo || (asked && out !== stale))
    // After an answer, the choices wait for the next output, so that a second tap does not answer the next question.
    var answered by remember(item.key) { mutableStateOf<HerdrOutput?>(null) }
    val choices = if (blocked && fresh) out.choices else emptyList()
    val prompt = remember(out?.lines) { out?.lines?.let { lines -> agentPrompt(lines.map { it.text }) }.orEmpty() }
    val context = LocalContext.current
    var lockError by remember(item.key) { mutableStateOf<String?>(null) }
    // The number of the last reply before this tile answered. The tile shows only the replies
    // that it sent, so that an old error does not show next to a new question.
    var sentAfter by remember(item.key) { mutableStateOf<Long?>(null) }
    val reply = d?.herdrReply?.takeIf { r -> r.pane == pane && sentAfter.let { it != null && r.seq > it } }
    val sending = reply?.sending == true
    val lastSeq = d?.herdrReply?.seq ?: 0L
    fun answer(key: String) {
        lockError = null
        ReplyLock.run(context, {
            answered = out
            sentAfter = lastSeq
            HerdrSync.sendKeys(FluxCore, item.deviceId, pane, listOf(key))
        }) { lockError = it }
    }
    val open = { actions.open(Route(item.deviceId, "$AGENT_PAGE$pane")) }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        header()
        T(listOf(a.agent, a.project.ifEmpty { a.workspace }).filter { it.isNotEmpty() }.joinToString(" · "), size = 13, color = Tn.sub, family = Mono, maxLines = 1)
        T(a.title.ifEmpty { a.project.ifEmpty { pane } }, size = 20, weight = FontWeight.SemiBold, maxLines = 3)
        when {
            !blocked -> T(
                if (item.kind == InboxKind.AgentDone) "The agent is done and waits for the next prompt." else "The agent works. Open it to read the output.",
                size = 14, color = Tn.sub,
            )
            out?.error != null && !out.loading -> T(out.error, size = 13, color = Tn.red)
            !fresh -> PromptSkeleton()
            prompt.isNotEmpty() -> T(prompt, size = 14, family = Mono, lineHeight = 1.35f, maxLines = 8)
        }
    }
    Push()
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (c in choices) ChoiceRow(c, enabled = item.control && !sending && out !== answered) { answer(c.key) }
        val problem = lockError ?: reply?.error
        if (problem != null) T(problem, size = 13, color = Tn.red)
        if (blocked && !item.control) T("To answer from this phone, set herdr_control = true on ${item.computer}.", size = 13, color = Tn.sub)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (sending) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Tn.blue)
                T("Sending", size = 13, color = Tn.sub)
            }
            Spacer(Modifier.weight(1f))
            if (blocked && fresh && choices.isEmpty() && item.control) {
                Button(onClick = open, modifier = Modifier.heightIn(min = 48.dp)) { Text("Reply") }
            } else {
                OutlinedButton(onClick = open, modifier = Modifier.heightIn(min = 48.dp)) { Text(if (blocked) "Reply" else "Open") }
            }
        }
    }
}

/** Lines in the place of the question while the output loads. */
@Composable
private fun PromptSkeleton() {
    Column(
        Modifier.fillMaxWidth().semantics { contentDescription = "Reading the question" },
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        for (f in listOf(0.9f, 0.7f, 0.5f)) {
            Box(Modifier.fillMaxWidth(f).height(12.dp).clip(RoundedCornerShape(3.dp)).background(Tn.line))
        }
    }
}

/** A numbered choice of the agent. A tap sends its digit, after the phone lock. */
@Composable
private fun ChoiceRow(c: AgentChoice, enabled: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(shape)
            .background(if (c.selected) Tn.tileHi else Tn.bg)
            .border(1.dp, if (c.selected) Tn.blue else Tn.line, shape)
            .clickable(enabled = enabled, onClickLabel = "Answer ${c.key}", role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        T(c.key, size = 15, color = Tn.blue, weight = FontWeight.Bold, family = Mono)
        T(c.label, Modifier.weight(1f), size = 14, maxLines = 3)
    }
}

@Composable
private fun ColumnScope.ApprovalMaster(item: ApprovalItem, header: @Composable () -> Unit, actions: InboxActions) {
    val r = item.request
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        header()
        T(
            if (r.kind == ApproveRequest.Kind.Approve) "Approve ${r.service} on ${r.host}?" else "Enroll this phone on ${r.host}?",
            size = 20, weight = FontWeight.SemiBold, maxLines = 3,
        )
        T(ApproveMessage.question(r), size = 14, color = Tn.sub, lineHeight = 1.35f)
        T(listOf("user ${r.user}", r.tty, r.host).filter { it.isNotBlank() }.joinToString(" · "), size = 13, color = Tn.sub, family = Mono, maxLines = 2)
    }
    Push()
    Button(onClick = { actions.approve(r) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
        Sym(Ic.key, size = 18.dp)
        Spacer(Modifier.size(8.dp))
        Text("Review")
    }
}

@Composable
private fun ColumnScope.PairMaster(item: PairItem, header: @Composable () -> Unit, actions: InboxActions) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        header()
        T(item.computer, size = 20, weight = FontWeight.SemiBold, maxLines = 2)
        T("${item.computer} asks to pair with this phone. Compare the key on both screens.", size = 14, color = Tn.sub, lineHeight = 1.35f)
    }
    Push()
    Button(onClick = { actions.showPair(item.deviceId) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Compare the key") }
}

@Composable
private fun ColumnScope.TransferMaster(item: TransferItem, header: @Composable () -> Unit) {
    val t = item.transfer
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        header()
        T(t.name, size = 18, weight = FontWeight.SemiBold, family = Mono, maxLines = 3)
        T(if (t.incoming) "From ${t.computer}" else "To ${t.computer}", size = 14, color = Tn.sub)
        if (t.state == TransferState.Running) {
            LinearProgressIndicator(Modifier.fillMaxWidth(), color = Tn.blue, trackColor = Tn.line)
        }
        if (t.state == TransferState.Failed) {
            T(if (t.incoming) "Send the file again from ${t.computer}." else "Send the file again.", size = 14, color = Tn.sub)
        }
    }
    Push()
    if (t.incoming && t.state == TransferState.Done) {
        OutlinedButton(
            onClick = {
                runCatching { context.startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            },
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        ) { Text("Show Downloads") }
    }
}

@Composable
private fun ColumnScope.ClipMaster(item: ClipItem, header: @Composable () -> Unit, actions: InboxActions) {
    val c = item.clip
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        header()
        T(if (c.sent) "Sent to ${c.computer}" else "From ${c.computer}", size = 18, weight = FontWeight.SemiBold, maxLines = 2)
        T(if (c.image) "An image" else c.preview, size = 14, family = if (c.image) FontFamily.Default else Mono, lineHeight = 1.35f, maxLines = 6)
        if (c.at > 0) T(DateUtils.getRelativeTimeSpanString(c.at, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString(), size = 12, color = Tn.sub)
    }
    Push()
    OutlinedButton(onClick = actions.tools.sendClipboard, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Send the clipboard") }
}

@Composable
private fun ColumnScope.MediaMaster(item: MediaItem, d: DeviceUi?, header: @Composable () -> Unit, actions: InboxActions) {
    val p = item.player
    val id = item.deviceId
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        header()
        T(p.title.ifEmpty { "Unknown title" }, size = 22, weight = FontWeight.SemiBold, maxLines = 2)
        val by = listOf(p.artist, p.album).filter { it.isNotEmpty() }.joinToString(" · ")
        if (by.isNotEmpty()) T(by, size = 14, color = Tn.sub, maxLines = 2)
        T(p.name, size = 12, color = Tn.sub, family = Mono, maxLines = 1)
    }
    Push()
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        val online = d?.online == true
        RoundIcon(Ic.previous, "Previous", enabled = online && p.canGoPrevious) { Plugins.mediaAction(FluxCore, id, "Previous") }
        RoundIcon(if (p.playing) Ic.pause else Ic.play, if (p.playing) "Pause" else "Play", enabled = online, filled = true) {
            Plugins.mediaAction(FluxCore, id, "PlayPause")
        }
        RoundIcon(Ic.next, "Next", enabled = online && p.canGoNext) { Plugins.mediaAction(FluxCore, id, "Next") }
        Spacer(Modifier.weight(1f))
        OutlinedButton(onClick = { actions.open(Route(id, "media")) }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Open") }
    }
}

/** A round icon button of at least 48 dp. [filled] marks the main control. */
@Composable
private fun RoundIcon(@DrawableRes icon: Int, description: String, enabled: Boolean = true, filled: Boolean = false, onClick: () -> Unit) {
    val size = if (filled) 56.dp else 48.dp
    Box(
        Modifier.size(size).clip(CircleShape).background(if (filled) Tn.green else Tn.bg)
            .clickable(enabled = enabled, onClickLabel = description, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Sym(icon, description, tint = if (filled) Tn.onAccent else if (enabled) Tn.text else Tn.sub, size = if (filled) 30.dp else 26.dp)
    }
}

// ───────────────────────── Stack ─────────────────────────

/** A tile of the stack. A tap moves it to the master tile. A player tile also plays and pauses. */
@Composable
private fun StackTile(item: InboxItem, modifier: Modifier, onPromote: () -> Unit) {
    val color = kindColor(item)
    Column(
        modifier.fillMaxWidth().heightIn(min = 112.dp).clip(TileShape).background(Tn.tile)
            .border(1.dp, if (item.kind.needsYou) Tn.red else Tn.line, TileShape)
            .clickable(onClickLabel = "Show it first", role = Role.Button, onClick = onPromote)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            Dot(color, 7.dp)
            TileLabel(kindLabel(item), color = color)
        }
        T(stackTitle(item), size = 14, weight = FontWeight.SemiBold, maxLines = 2)
        Row(verticalAlignment = Alignment.CenterVertically) {
            T(stackLine(item), Modifier.weight(1f), size = 12, color = Tn.sub, maxLines = 2)
            if (item is MediaItem) {
                val playing = item.player.playing
                Box(
                    Modifier.size(48.dp).clip(CircleShape)
                        .clickable(onClickLabel = if (playing) "Pause" else "Play", role = Role.Button) {
                            Plugins.mediaAction(FluxCore, item.deviceId, "PlayPause")
                        },
                    contentAlignment = Alignment.Center,
                ) { Sym(if (playing) Ic.pause else Ic.play, if (playing) "Pause" else "Play", tint = Tn.green, size = 26.dp) }
            }
        }
    }
}

/** The state label of an item. */
private fun kindLabel(item: InboxItem): String = when (item) {
    is AgentItem -> when (item.kind) {
        InboxKind.AgentInput -> "Needs input"
        InboxKind.AgentDone -> "Done"
        else -> "Working"
    }
    is ApprovalItem -> "Approval"
    is PairItem -> "Pair request"
    is TransferItem -> when (item.transfer.state) {
        TransferState.Running -> if (item.transfer.incoming) "Receiving" else "Sending"
        TransferState.Done -> if (item.transfer.incoming) "Received" else "Sent"
        TransferState.Failed -> "Failed"
    }
    is ClipItem -> "Clipboard"
    is MediaItem -> if (item.player.playing) "Now playing" else "Paused"
}

/** The color of the state label. Red marks only what needs the user and errors. */
@Composable
@ReadOnlyComposable
private fun kindColor(item: InboxItem): Color = when {
    item.kind.needsYou -> Tn.red
    item is AgentItem -> if (item.kind == InboxKind.AgentDone) Tn.green else Tn.blue
    item is TransferItem -> when (item.transfer.state) {
        TransferState.Running -> Tn.blue
        TransferState.Done -> Tn.green
        TransferState.Failed -> Tn.red
    }
    item is ClipItem -> Tn.cyan
    item is MediaItem -> if (item.player.playing) Tn.green else Tn.sub
    else -> Tn.sub
}

private fun stackTitle(item: InboxItem): String = when (item) {
    is AgentItem -> item.agent.title.ifEmpty { item.agent.project.ifEmpty { item.agent.pane } }
    is ApprovalItem -> if (item.request.kind == ApproveRequest.Kind.Approve) "Approve ${item.request.service}" else "Enroll this phone"
    is PairItem -> item.computer
    is TransferItem -> item.transfer.name
    is ClipItem -> if (item.clip.image) "An image" else item.clip.preview
    is MediaItem -> item.player.title.ifEmpty { "Unknown title" }
}

private fun stackLine(item: InboxItem): String = when (item) {
    is AgentItem -> listOf(item.agent.agent, item.computer).joinToString(" · ")
    is ApprovalItem -> "${item.request.user} on ${item.request.host}"
    is PairItem -> "Asks to pair"
    is TransferItem -> if (item.transfer.incoming) "From ${item.computer}" else "To ${item.computer}"
    is ClipItem -> if (item.clip.sent) "Sent to ${item.computer}" else "From ${item.computer}"
    is MediaItem -> listOf(item.player.artist, item.computer).filter { it.isNotEmpty() }.joinToString(" · ")
}
