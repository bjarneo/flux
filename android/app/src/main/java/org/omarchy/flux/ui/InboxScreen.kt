package org.omarchy.flux.ui

import android.app.DownloadManager
import android.content.Intent
import android.text.format.DateUtils
import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.Crossfade
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.togetherWith
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
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
    val tools: SendTools,
    val showAll: () -> Unit,
    val allowNotifications: () -> Unit,
    val hideNotifications: () -> Unit,
)

/** The least height of the status line above the master: the height of its Retry button. */
private val StatusMin = 48.dp

/** The widest choice and action row of the master, so that a row stays easy to read in a wide window. */
private val ActionWidth = 600.dp

/** The part of the width that the master column takes in a wide window. */
private const val MASTER_WIDTH = 0.6f

/** Below this height, the master column of a wide window is compact, for example on a phone in landscape. */
private val CompactMaster = 460.dp

/** The space under the master tile in a wide window. */
private val SplitBottom = 8.dp

/**
 * The Inbox: 1 list of what happens on the computers in scope. The first
 * item is the master tile with its whole action. The other items wait in
 * the stack. A swipe on the master moves it to the end of the stack, and a
 * tap on a stack tile moves that tile to the master. On a phone in
 * portrait, the master takes about 55% of the height, and the stack has 2
 * columns under it. A [wide] window shows the Hyprland master layout: the
 * master in a column at about 60% of the width and of full height, and the
 * stack in a column on the right. [items] are in the order of the user.
 * [notices] tell what the Inbox cannot show. [active] is false while the
 * screen moves, so that it reads nothing new then.
 */
@Composable
fun InboxScreen(
    state: UiState,
    items: List<InboxItem>,
    active: Boolean,
    notices: InboxNotices,
    actions: InboxActions,
    wide: Boolean,
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
    if (wide) {
        SplitInbox(state, items, active, notices, actions, onSwipe, onPromote)
    } else {
        StackedInbox(state, items, active, notices, actions, onSwipe, onPromote)
    }
}

/**
 * The Inbox of a phone in portrait: the status line, the master, and the
 * stack in 2 columns under it, all in 1 grid. The tiles move to their new
 * places in [MOTION_MS].
 */
@Composable
private fun StackedInbox(
    state: UiState,
    items: List<InboxItem>,
    active: Boolean,
    notices: InboxNotices,
    actions: InboxActions,
    onSwipe: (String) -> Unit,
    onPromote: (String) -> Unit,
) {
    val reduce = LocalReduceMotion.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        // The master takes about 55% of the height under the status line, so that 2 rows of the stack show above the navigation bar.
        val masterMin = ((maxHeight - StatusMin - TileGap) * 0.55f).coerceAtLeast(0.dp)
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
                    fit = MasterFit(push = true, compact = false),
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

/**
 * The Inbox of a wide window, as the master layout of Hyprland: the master
 * at the left in a column of full height, and the status line and the stack
 * in a column on the right. The choices sit directly under the prompt. A
 * new master moves in from the stack side, and the stack tiles move to
 * their new places, each in [MOTION_MS].
 */
@Composable
private fun SplitInbox(
    state: UiState,
    items: List<InboxItem>,
    active: Boolean,
    notices: InboxNotices,
    actions: InboxActions,
    onSwipe: (String) -> Unit,
    onPromote: (String) -> Unit,
) {
    val reduce = LocalReduceMotion.current
    val canSwipe = items.size > 1
    Row(Modifier.fillMaxSize().padding(horizontal = TiledGutter), horizontalArrangement = Arrangement.spacedBy(TileGap)) {
        BoxWithConstraints(Modifier.weight(MASTER_WIDTH).fillMaxHeight()) {
            val fit = MasterFit(push = false, compact = maxHeight < CompactMaster)
            val height = (maxHeight - SplitBottom).coerceAtLeast(0.dp)
            AnimatedContent(
                targetState = items.first(),
                modifier = Modifier.fillMaxSize(),
                transitionSpec = { promoteMotion(reduce) },
                label = "master",
                contentKey = { it.key },
            ) { master ->
                // A master that is higher than the window scrolls. It fills the height of the window at least.
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = SplitBottom)) {
                    MasterTile(
                        master, state.devices, active, actions,
                        canSwipe = canSwipe,
                        onSwipe = { onSwipe(master.key) },
                        fit = fit,
                        modifier = Modifier.fillMaxWidth().heightIn(min = height),
                    )
                }
            }
        }
        LazyColumn(
            Modifier.weight(1f - MASTER_WIDTH).fillMaxHeight(),
            contentPadding = PaddingValues(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(TileGap),
        ) {
            item(key = "status") { InboxStatus(items.needsYou(), notices, actions) }
            items(items.drop(1), key = { it.key }, contentType = { "stack" }) { item ->
                StackTile(
                    item,
                    Modifier.animateItem(fadeInSpec = shellMotion(reduce), placementSpec = shellMotion(reduce), fadeOutSpec = shellMotion(reduce)),
                ) { onPromote(item.key) }
            }
        }
    }
}

/**
 * The motion of a new master in a wide window: it moves in from the side
 * of the stack and fades in, while the old master fades out. Each part
 * takes [MOTION_MS] or less.
 */
private fun promoteMotion(reduce: Boolean): ContentTransform {
    if (reduce) return EnterTransition.None togetherWith ExitTransition.None
    val ease = FastOutSlowInEasing
    return (slideInHorizontally(tween(MOTION_MS, easing = ease)) { it / 6 } + fadeIn(tween(MOTION_MS, easing = ease))) togetherWith
        fadeOut(tween(MOTION_MS / 2, easing = ease))
}

/** The count of the items that need the user, as a sentence. */
private fun needsText(count: Int): String = if (count == 1) "1 item needs you" else "$count items need you"

/**
 * The status line above the master: how many items need the user, then
 * the computers in scope that are not reachable, with Retry at the end. It
 * is 1 row. The other notices follow under it.
 */
@Composable
private fun InboxStatus(needs: Int, notices: InboxNotices, actions: InboxActions) {
    val offline = offlineShows(notices)
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = if (offline) StatusMin else 32.dp).padding(start = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // The mark aligns with the first line of the text.
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (needs > 0 || offline) {
                    Box(Modifier.padding(top = 5.dp)) { if (needs > 0) Dot(Tn.red) else LinkDot(false) }
                }
                val text = buildAnnotatedString {
                    withStyle(SpanStyle(fontSize = 14.sp)) {
                        if (needs > 0) {
                            withStyle(SpanStyle(color = Tn.text, fontWeight = FontWeight.SemiBold)) { append(needsText(needs)) }
                        } else {
                            append(nothingText(notices))
                        }
                    }
                    if (offline) append(". " + offlineLine(notices))
                }
                BasicText(text, style = TextStyle(color = Tn.sub, fontSize = 13.sp, lineHeight = 18.sp))
            }
            if (offline) FluxButton("Retry", { FluxCore.rediscover() }, kind = ButtonKind.Text)
        }
        InboxNoticeList(notices, actions, offline = false)
    }
}

/** What the large tile of an empty Inbox shows. */
private sealed interface EmptyMode {
    /** No computer is paired: the pairing guide. */
    data object Guide : EmptyMode

    /** A new pairing: the success state of the computer [name]. */
    data class Paired(val name: String) : EmptyMode

    /** No computer in scope is online yet, and the links can still connect. */
    data object Connecting : EmptyMode

    /** No computer in scope is reachable. */
    data object Offline : EmptyMode

    /** Nothing needs the user. */
    data object Clear : EmptyMode
}

/**
 * The Inbox with no items: what shows here, and the 2 most used actions.
 * Before the first pairing, it shows the pairing guide. After a new
 * pairing, it shows the success state for a short time. While the links
 * connect after a start, it shows that Flux connects. When no computer in
 * scope is reachable after that, it says so and offers Retry, so that an
 * empty Inbox is not a false all-clear. The large tile changes with a
 * crossfade.
 */
@Composable
private fun InboxEmpty(state: UiState, notices: InboxNotices, actions: InboxActions) {
    val paired = state.devices.any { it.paired }
    val offline = paired && notices.reach.noneOnline
    val welcome = notices.paired
    val mode = when {
        !paired -> EmptyMode.Guide
        offline && notices.connecting -> EmptyMode.Connecting
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
                is EmptyMode.Paired -> PairedTile(m.name, notices.notify, actions)
                EmptyMode.Connecting -> EmptyTile {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Spinner(Modifier.size(20.dp), color = Tn.blue)
                        T(connectingTitle(notices.reach), Modifier.weight(1f), size = 22, weight = FontWeight.SemiBold)
                    }
                    T("What waits for you shows here when the connection is ready.", size = 14, color = Tn.sub, lineHeight = 1.35f)
                }
                EmptyMode.Offline -> EmptyTile {
                    Sym(if (state.onWifi) Ic.wifiFind else Ic.wifiOff, tint = Tn.yellow, size = 28.dp)
                    T(offlineTitle(notices.reach), size = 22, weight = FontWeight.SemiBold)
                    T(offlineHint(state.onWifi), size = 14, color = Tn.sub, lineHeight = 1.35f)
                    T("The Inbox shows what waits on a computer only while the computer is reachable.", size = 14, color = Tn.sub, lineHeight = 1.35f)
                    FluxButton("Retry", { FluxCore.rediscover() }, Modifier.padding(top = 4.dp), icon = Ic.refresh)
                }
                EmptyMode.Clear -> EmptyTile {
                    T(nothingText(notices), size = 22, weight = FontWeight.SemiBold)
                    T(
                        "Agents that wait for you, approvals, and pair requests show here first. What plays now, the clipboard, transfers, and the other agents follow.",
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
 * How the master tile fills its place. [push] moves the actions to the
 * bottom of the tile, at thumb height, as on a phone in portrait. Without
 * it, the actions follow the prompt directly. [compact] is for a window of
 * little height, for example a phone in landscape: the tile takes less
 * space, the prompt is shorter, and Reply moves to the top row, so that
 * the choices and Reply show without a scroll.
 */
private data class MasterFit(val push: Boolean, val compact: Boolean) {
    /** The space inside the border of the tile. */
    val padding: Dp get() = if (compact) 12.dp else 16.dp

    /** The space between the lines of the top part. */
    val gap: Dp get() = if (compact) 6.dp else 10.dp

    /** The space between the top part and the actions. */
    val partGap: Dp get() = if (compact) 10.dp else 16.dp

    /** The space between the choices. */
    val choiceGap: Dp get() = if (compact) 6.dp else 8.dp
}

/** The top row of a master: it takes the actions to show at its end, after Later. */
private typealias MasterHeaderSlot = @Composable (trailing: @Composable RowScope.() -> Unit) -> Unit

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
    fit: MasterFit,
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
    val header: MasterHeaderSlot = { trailing -> MasterHeader(item, canSwipe, onSwipe, trailing) }
    Tile(m, border = activeBorder(), padding = PaddingValues(fit.padding), verticalArrangement = Arrangement.spacedBy(fit.partGap, Alignment.Top)) {
        val d = devices.firstOrNull { it.id in item.deviceIds }
        when (item) {
            is AgentItem -> AgentMaster(item, d, active, fit, header, actions)
            is ApprovalItem -> ApprovalMaster(item, fit, header, actions)
            is PairItem -> PairMaster(item, fit, header, actions)
            is TransferItem -> TransferMaster(item, fit, header)
            is ClipItem -> ClipMaster(item, fit, header, actions)
            is MediaItem -> MediaMaster(item, d, fit, header, actions)
        }
    }
}

/**
 * The top row of the master tile: the window title with the state, the
 * computer on its own line under it, and the Later button. [trailing]
 * adds actions after Later. A long title or computer name does not push
 * the buttons out of the row. TalkBack reads the state as the state of the
 * row.
 */
@Composable
private fun MasterHeader(item: InboxItem, canSwipe: Boolean, onSwipe: () -> Unit, trailing: @Composable RowScope.() -> Unit) {
    val state = stateWord(item)
    val spoken = (windowSource(item) + item.computer).joinToString(", ")
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(
            Modifier.weight(1f).clearAndSetSemantics {
                contentDescription = spoken
                stateDescription = state
            },
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            WindowTitle(item, size = 13, split = splitTitle(LocalDensity.current.fontScale))
            T(item.computer, size = 12, color = Tn.sub, family = Mono, maxLines = 1)
        }
        if (canSwipe) FluxButton("Later", onSwipe, kind = ButtonKind.Text)
        trailing()
    }
}

/**
 * The space between the top part and the actions of the master. With
 * [MasterFit.push], it moves the actions to the bottom of the tile, at
 * thumb height. Without it, the actions follow the top part directly.
 */
@Composable
private fun ColumnScope.Push(fit: MasterFit) {
    if (fit.push) Spacer(Modifier.weight(1f))
}

/**
 * True when the prompt of the master is short: in a compact master and from
 * a font scale of 1.15. A short prompt has 3 output lines in place of 4,
 * and drops the question line that the choices ask, see [agentPrompt]. The
 * lines nearest the choices always show in full, because they hold the
 * command that a choice approves. A one-tap choice must never approve a
 * command that the user cannot see. Reply and Open show the full output.
 */
private fun shortPrompt(fontScale: Float, compact: Boolean): Boolean = compact || fontScale >= 1.15f

@Composable
private fun ColumnScope.AgentMaster(item: AgentItem, d: DeviceUi?, active: Boolean, fit: MasterFit, header: MasterHeaderSlot, actions: InboxActions) {
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
    val fontScale = LocalDensity.current.fontScale
    val short = shortPrompt(fontScale, fit.compact)
    val prompt = remember(out?.lines, short) {
        out?.lines?.let { lines -> agentPrompt(lines.map { it.text }, if (short) 3 else 4, dropAsk = short) }.orEmpty()
    }
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
    val replyButton: @Composable () -> Unit = {
        if (blocked && fresh && choices.isEmpty() && item.control) {
            FluxButton("Reply", open)
        } else {
            FluxButton(if (blocked) "Reply" else "Open", open, kind = ButtonKind.Outlined)
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(fit.gap)) {
        // A compact master shows Reply in the top row, so that it shows with the choices.
        header { if (fit.compact) replyButton() }
        T(a.title.ifEmpty { a.project.ifEmpty { pane } }, size = 20, weight = FontWeight.SemiBold, maxLines = if (fit.compact) 1 else if (fontScale >= 1.5f) 2 else 3)
        when {
            !blocked -> T(
                if (item.kind == InboxKind.AgentDone) "The agent is done and waits for the next prompt." else "The agent works. Open it to read the output.",
                size = 14, color = Tn.sub,
            )
            out?.error != null && !out.loading -> T(out.error, size = 13, color = Tn.red)
            !fresh -> PromptSkeleton()
            // The prompt never gets cut on screen, so that the command shows in full.
            prompt.isNotEmpty() -> T(prompt, size = 14, family = Mono, lineHeight = 1.35f)
        }
    }
    Push(fit)
    Column(Modifier.widthIn(max = ActionWidth).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(fit.choiceGap)) {
        for (c in choices) ChoiceRow(c, enabled = item.control && !sending && out !== answered) { answer(c.key) }
        val problem = lockError ?: reply?.error
        if (problem != null) T(problem, size = 13, color = Tn.red)
        if (blocked && !item.control) T("To answer from this phone, set herdr_control = true on ${item.computer}.", size = 13, color = Tn.sub)
        if (sending || !fit.compact) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (sending) {
                    Spinner(Modifier.size(18.dp), color = Tn.blue)
                    T("Sending", size = 13, color = Tn.sub)
                }
                Spacer(Modifier.weight(1f))
                if (!fit.compact) replyButton()
            }
        }
    }
}

/** Lines in the place of the question while the output loads. */
@Composable
private fun PromptSkeleton() {
    LineSkeleton("Reading the question", lines = listOf(0.9f, 0.7f, 0.5f))
}

/** A numbered choice of the agent. A tap sends its digit, after the phone lock. */
@Composable
private fun ChoiceRow(c: AgentChoice, enabled: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    Row(
        Modifier.widthIn(max = ActionWidth).fillMaxWidth().heightIn(min = 48.dp).clip(shape)
            .background(if (c.selected) Tn.accentTile else Tn.bg)
            .border(choiceBorder(c.selected), shape)
            .clickable(enabled = enabled, onClickLabel = "Answer ${c.key}", role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        T(c.key, size = 15, color = Tn.blue, weight = FontWeight.Bold, family = Mono)
        T(c.label, Modifier.weight(1f), size = 14)
    }
}

/** The modifier of the 1 action button of a master: the full width, up to [ActionWidth]. */
private val ActionModifier = Modifier.widthIn(max = ActionWidth).fillMaxWidth()

@Composable
private fun ColumnScope.ApprovalMaster(item: ApprovalItem, fit: MasterFit, header: MasterHeaderSlot, actions: InboxActions) {
    val r = item.request
    Column(verticalArrangement = Arrangement.spacedBy(fit.gap)) {
        header {}
        T(
            if (r.kind == ApproveRequest.Kind.Approve) "Approve ${r.service} on ${r.host}?" else "Enroll this phone on ${r.host}?",
            size = 20, weight = FontWeight.SemiBold, maxLines = 3,
        )
        T(ApproveMessage.question(r), size = 14, color = Tn.sub, lineHeight = 1.35f)
        T(listOf("user ${r.user}", r.tty, r.host).filter { it.isNotBlank() }.joinToString(" · "), size = 13, color = Tn.sub, family = Mono, maxLines = 2)
    }
    Push(fit)
    FluxButton("Review", { actions.approve(r) }, ActionModifier, icon = Ic.key)
}

@Composable
private fun ColumnScope.PairMaster(item: PairItem, fit: MasterFit, header: MasterHeaderSlot, actions: InboxActions) {
    Column(verticalArrangement = Arrangement.spacedBy(fit.gap)) {
        header {}
        T(item.computer, size = 20, weight = FontWeight.SemiBold, maxLines = 2)
        T("${item.computer} asks to pair with this phone. Compare the key on both screens.", size = 14, color = Tn.sub, lineHeight = 1.35f)
    }
    Push(fit)
    FluxButton("Compare the key", { actions.showPair(item.deviceId) }, ActionModifier)
}

@Composable
private fun ColumnScope.TransferMaster(item: TransferItem, fit: MasterFit, header: MasterHeaderSlot) {
    val t = item.transfer
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(fit.gap)) {
        header {}
        T(t.name, size = 18, weight = FontWeight.SemiBold, family = Mono, maxLines = 3)
        T(if (t.incoming) "From ${t.computer}" else "To ${t.computer}", size = 14, color = Tn.sub)
        if (t.state == TransferState.Running) {
            LinearProgressIndicator(Modifier.fillMaxWidth(), color = Tn.blue, trackColor = Tn.line)
        }
        if (t.state == TransferState.Failed) {
            T(if (t.incoming) "Send the file again from ${t.computer}." else "Send the file again.", size = 14, color = Tn.sub)
        }
    }
    Push(fit)
    if (t.incoming && t.state == TransferState.Done) {
        FluxButton(
            "Show Downloads",
            { runCatching { context.startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } },
            ActionModifier,
            kind = ButtonKind.Outlined,
        )
    }
}

@Composable
private fun ColumnScope.ClipMaster(item: ClipItem, fit: MasterFit, header: MasterHeaderSlot, actions: InboxActions) {
    val c = item.clip
    Column(verticalArrangement = Arrangement.spacedBy(fit.gap)) {
        header {}
        T(if (c.sent) "Sent to ${c.computer}" else "From ${c.computer}", size = 18, weight = FontWeight.SemiBold, maxLines = 2)
        T(if (c.image) "An image" else c.preview, size = 14, family = if (c.image) FontFamily.Default else Mono, lineHeight = 1.35f, maxLines = 6)
        if (c.at > 0) T(DateUtils.getRelativeTimeSpanString(c.at, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString(), size = 12, color = Tn.sub)
    }
    Push(fit)
    FluxButton("Send the clipboard", actions.tools.sendClipboard, ActionModifier, kind = ButtonKind.Outlined)
}

@Composable
private fun ColumnScope.MediaMaster(item: MediaItem, d: DeviceUi?, fit: MasterFit, header: MasterHeaderSlot, actions: InboxActions) {
    val p = item.player
    val id = item.deviceId
    Column(verticalArrangement = Arrangement.spacedBy(fit.gap)) {
        // The window title holds the name of the player.
        header {}
        T(p.title.ifEmpty { "Unknown title" }, size = 22, weight = FontWeight.SemiBold, maxLines = 2)
        val by = listOf(p.artist, p.album).filter { it.isNotEmpty() }.joinToString(" · ")
        if (by.isNotEmpty()) T(by, size = 14, color = Tn.sub, maxLines = 2)
    }
    Push(fit)
    Row(ActionModifier, horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        val online = d?.online == true
        RoundIcon(Ic.previous, "Previous", enabled = online && p.canGoPrevious) { Plugins.mediaAction(FluxCore, id, "Previous") }
        RoundIcon(if (p.playing) Ic.pause else Ic.play, if (p.playing) "Pause" else "Play", enabled = online, filled = true) {
            Plugins.mediaAction(FluxCore, id, "PlayPause")
        }
        RoundIcon(Ic.next, "Next", enabled = online && p.canGoNext) { Plugins.mediaAction(FluxCore, id, "Next") }
        Spacer(Modifier.weight(1f))
        FluxButton("Open", { actions.open(Route(id, "media")) }, kind = ButtonKind.Outlined)
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

// ───────────────────────── Window title ─────────────────────────

/**
 * The window title of an item: a dot in the color of the state, the state
 * as a short word in that color, and the source of the item in mono, as
 * Hyprland shows a window. For example: "Needs input · codex · billing".
 * The state comes first, so that a line that is too long cuts only the end
 * of the source, and the state does not depend on the color. An empty
 * source shows no separator.
 *
 * With [split], the state and the source take 1 line each, so that a large
 * font does not wrap the line at a separator. The state then gets smaller
 * to fit its line, and it never gets cut. With [keepLines], the source line
 * shows also when it is empty, so that the tiles of 1 row keep the same
 * height. TalkBack does not read the title. The tile gives the source and
 * the state.
 */
@Composable
private fun WindowTitle(item: InboxItem, size: Int, modifier: Modifier = Modifier, split: Boolean = false, keepLines: Boolean = false) {
    val source = windowSource(item)
    val state = stateWord(item)
    val color = kindColor(item)
    val sub = Tn.sub
    val lineHeight = (size * 1.35f).sp
    val line = with(LocalDensity.current) { lineHeight.toDp() }
    val dot = if (size < 13) 7.dp else 8.dp
    Column(modifier.clearAndSetSemantics {}) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.height(line), contentAlignment = Alignment.Center) { Dot(color, dot) }
            Spacer(Modifier.width(8.dp))
            if (split) {
                T(state, size = size, color = color, weight = FontWeight.Medium, maxLines = 1, fit = true)
            } else {
                val text = remember(source, state, color, sub) {
                    buildAnnotatedString {
                        withStyle(SpanStyle(color = color, fontWeight = FontWeight.Medium)) { append(state) }
                        if (source.isNotEmpty()) withStyle(SpanStyle(color = sub, fontFamily = Mono)) { append(" · " + source.joinToString(" · ")) }
                    }
                }
                BasicText(text, style = TextStyle(fontSize = size.sp, lineHeight = lineHeight), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (split && (source.isNotEmpty() || keepLines)) {
            // The source starts under the state word. A blank keeps the height of the line.
            T(source.joinToString(" · ").ifEmpty { " " }, Modifier.padding(start = dot + 8.dp), size = size, color = sub, family = Mono, maxLines = 1)
        }
    }
}

/** True from a font scale of 1.3, where a narrow tile cannot show the state and the source on 1 line. See [WindowTitle]. */
private fun splitTitle(fontScale: Float): Boolean = fontScale >= 1.3f

/** The source of an item for its window title, without the computer: for example the agent and its project. It can be empty. */
private fun windowSource(item: InboxItem): List<String> = when (item) {
    is AgentItem -> listOf(item.agent.agent, item.agent.project.ifEmpty { item.agent.workspace })
    is ApprovalItem -> listOf(item.request.service)
    is MediaItem -> listOf(item.player.name)
    is PairItem, is TransferItem, is ClipItem -> emptyList()
}.filter { it.isNotBlank() }

// ───────────────────────── Stack ─────────────────────────

/**
 * A tile of the stack: the window title, the title, and 1 line about the
 * computer. Each line takes 1 line at most. From a font scale of 1.3, the
 * window title takes 2 lines in every tile, see [WindowTitle]. So the tiles
 * of 1 row have the same height at each font size. A tap moves the tile to the
 * master tile. A player tile also plays and pauses.
 */
@Composable
private fun StackTile(item: InboxItem, modifier: Modifier, onPromote: () -> Unit) {
    val state = stateWord(item)
    val source = windowSource(item).joinToString(", ")
    Box(
        modifier.fillMaxWidth().heightIn(min = 48.dp).clip(TileShape).background(Tn.tile)
            .border(1.dp, if (item.kind.needsYou) Tn.red else Tn.line, TileShape)
            .clickable(onClickLabel = "Show it first", role = Role.Button, onClick = onPromote)
            .semantics { stateDescription = state }
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        val media = item is MediaItem
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            // TalkBack reads the source here and the state from the tile. The title takes the full width, also next to the play button.
            Box(Modifier.semantics { if (source.isNotEmpty()) contentDescription = source }) {
                WindowTitle(item, size = 12, split = splitTitle(LocalDensity.current.fontScale), keepLines = true)
            }
            // The 2 lines under the title leave space for the play button.
            val room = if (media) Modifier.padding(end = 40.dp) else Modifier
            T(stackTitle(item), room, size = 14, weight = FontWeight.SemiBold, maxLines = 1)
            T(stackLine(item), room, size = 12, color = Tn.sub, maxLines = 1)
        }
        if (item is MediaItem) {
            val playing = item.player.playing
            // The button sits next to the 2 lines and reaches into the padding, so that the tile keeps the height of the other tiles.
            Box(
                Modifier.align(Alignment.BottomEnd).offset(x = 10.dp, y = 8.dp).size(48.dp).clip(CircleShape)
                    .clickable(onClickLabel = if (playing) "Pause" else "Play", role = Role.Button) {
                        Plugins.mediaAction(FluxCore, item.deviceId, "PlayPause")
                    },
                contentAlignment = Alignment.Center,
            ) { Sym(if (playing) Ic.pause else Ic.play, if (playing) "Pause" else "Play", tint = Tn.green, size = 26.dp) }
        }
    }
}

/** The state of an item as a short word in sentence case, for the window title and for TalkBack. */
private fun stateWord(item: InboxItem): String = when (item) {
    is AgentItem -> when (item.kind) {
        InboxKind.AgentInput -> "Needs input"
        InboxKind.AgentDone -> "Done"
        else -> "Working"
    }
    is ApprovalItem -> "Needs approval"
    is PairItem -> "Pair request"
    is TransferItem -> when (item.transfer.state) {
        TransferState.Running -> if (item.transfer.incoming) "Receiving" else "Sending"
        TransferState.Done -> if (item.transfer.incoming) "Received" else "Sent"
        TransferState.Failed -> "Failed"
    }
    is ClipItem -> "Clipboard"
    is MediaItem -> if (item.player.playing) "Playing" else "Paused"
}

/** The color of the state dot and the state word. Red marks only what needs the user and errors. */
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

/** The line under the title of a stack tile. The window title already holds the source and the state. */
private fun stackLine(item: InboxItem): String = when (item) {
    is AgentItem -> item.computer
    is ApprovalItem -> "${item.request.user} on ${item.request.host}"
    is PairItem -> "Compare the key to pair"
    is TransferItem -> if (item.transfer.incoming) "From ${item.computer}" else "To ${item.computer}"
    is ClipItem -> if (item.clip.sent) "Sent to ${item.computer}" else "From ${item.computer}"
    is MediaItem -> listOf(item.player.artist, item.computer).filter { it.isNotEmpty() }.joinToString(" · ")
}
