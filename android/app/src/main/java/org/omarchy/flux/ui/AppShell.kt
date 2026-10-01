package org.omarchy.flux.ui

import android.content.Intent
import androidx.activity.compose.PredictiveBackHandler
import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.EnterExitState
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.SeekableTransitionState
import androidx.compose.animation.core.rememberTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.launch
import org.omarchy.flux.camera.CameraMode
import org.omarchy.flux.camera.CameraScreen
import org.omarchy.flux.core.ApproveRequest
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.InboxArrangement
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.needsYou
import org.omarchy.flux.mic.MicScreen

/** Keeps the order that the user gave the Inbox across a recreation: the pinned key, then the deferred keys. */
private val ArrangementSaver = listSaver<InboxArrangement, String>(
    save = { listOf(it.pinned.orEmpty()) + it.deferred },
    restore = { InboxArrangement(pinned = it.firstOrNull()?.ifEmpty { null }, deferred = it.drop(1)) },
)

/**
 * The app structure: the scope chip at the top, the 4 destinations in a
 * navigation bar at the bottom, and the feature screens above a
 * destination. The destinations change with a fade through, and a feature
 * screen moves in and out on the horizontal axis. System Back follows the
 * predictive back gesture. The Remove animations setting turns the motion
 * off.
 */
@Composable
fun FluxShell(
    state: UiState,
    nav: Nav,
    onNav: (Nav) -> Unit,
    scope: String?,
    onScope: (String?) -> Unit,
    onPair: (DeviceUi) -> Unit,
    onUnpair: (DeviceUi) -> Unit,
    onShowPair: (String) -> Unit,
) {
    val context = LocalContext.current
    val reduce = rememberReduceMotion()
    val current by rememberUpdatedState(nav)
    val go by rememberUpdatedState(onNav)

    // The Inbox: the ranked items in scope, in the order that the user gave them.
    var arrangement by rememberSaveable(stateSaver = ArrangementSaver) { mutableStateOf(InboxArrangement()) }
    val items = rememberInboxItems(state, scope)
    LaunchedEffect(items) { arrangement = arrangement.sync(items) }
    val arranged = remember(items, arrangement) { arrangement.arrange(items) }
    val picker = rememberTargetPicker()
    val tools = rememberSendTools(state.devices, scope, picker)

    val dest = nav.dest
    val seek = remember { SeekableTransitionState<Dest>(dest) }
    val screens = rememberTransition(seek, label = "screens")
    LaunchedEffect(dest, reduce) {
        if (reduce) seek.snapTo(dest) else seek.animateTo(dest)
    }
    // The back gesture moves the transition to the screen under this one. A cancel moves it back.
    val coroutines = rememberCoroutineScope()
    PredictiveBackHandler(enabled = nav.back() != null) { events ->
        val to = current.back() ?: return@PredictiveBackHandler
        val from = current.dest
        try {
            events.collect { e -> if (!reduce) seek.seekTo(e.progress, to.dest) }
            go(to)
        } catch (e: CancellationException) {
            coroutines.launch { if (reduce) seek.snapTo(from) else seek.animateTo(from) }
            throw e
        }
    }

    fun open(r: Route) = go(current.push(r))
    val toComputers = { go(Nav(Tab.Computers)) }
    val approve: (ApproveRequest) -> Unit = { r ->
        if (isDemo(r.computerId)) FluxCore.toast("This is a sample request") else context.startActivity(Intent(context, ApproveActivity::class.java))
    }
    val chrome = nav.dest is Dest.Root

    CompositionLocalProvider(LocalReduceMotion provides reduce) {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal))) {
            AnimatedVisibility(chrome, enter = chromeIn(reduce), exit = chromeOut(reduce)) {
                ShellTopBar(state, scope, onScope)
            }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                screens.AnimatedContent(Modifier.fillMaxSize(), transitionSpec = { navTransform(reduce) }) { d ->
                    // An exiting screen takes no new reads, so that it does not race the new screen.
                    val active = transition.targetState == EnterExitState.Visible
                    when (d) {
                        is Dest.Root -> Box(Modifier.fillMaxSize().semantics { paneTitle = d.tab.label }) {
                            when (d.tab) {
                                Tab.Inbox -> InboxScreen(
                                    state, arranged, active,
                                    InboxActions(open = ::open, approve = approve, showPair = onShowPair, computers = toComputers, tools = tools),
                                    onSwipe = { arrangement = arrangement.swipe(it) },
                                    onPromote = { arrangement = arrangement.promote(it) },
                                )
                                Tab.Send -> SendScreen(state, scope, picker, tools, onOpen = ::open, onSync = { open(Route(null, SYNC_PAGE)) }, onPair = toComputers)
                                Tab.Control -> ControlScreen(state, scope, picker, onOpen = ::open, onPair = toComputers)
                                Tab.Computers -> ComputersScreen(state, scope, onScope, onPair, onUnpair, onSync = { open(Route(null, SYNC_PAGE)) })
                            }
                        }
                        is Dest.Detail -> Box(Modifier.fillMaxSize().systemBarsPadding()) {
                            DetailScreen(d.route, state, current = { current }, go = { go(it) })
                        }
                    }
                }
            }
            AnimatedVisibility(chrome, enter = chromeIn(reduce), exit = chromeOut(reduce)) {
                ShellNavBar(nav.tab, items.needsYou()) { t -> go(current.select(t)) }
            }
        }
        TargetPickerDialog(picker)
    }
}

private fun chromeIn(reduce: Boolean): EnterTransition =
    if (reduce) EnterTransition.None else fadeIn(tween(MOTION_MS, easing = FastOutSlowInEasing)) + expandVertically(tween(MOTION_MS, easing = FastOutSlowInEasing))

private fun chromeOut(reduce: Boolean): ExitTransition =
    if (reduce) ExitTransition.None else fadeOut(tween(MOTION_MS, easing = FastOutSlowInEasing)) + shrinkVertically(tween(MOTION_MS, easing = FastOutSlowInEasing))

/**
 * The motion between 2 screens: a fade through between destinations, and
 * the horizontal shared axis into and out of a feature screen. Each part
 * takes 250 ms or less.
 */
private fun AnimatedContentTransitionScope<Dest>.navTransform(reduce: Boolean): ContentTransform {
    if (reduce) return EnterTransition.None togetherWith ExitTransition.None
    val ease = FastOutSlowInEasing
    val deeper = targetState.depth > initialState.depth
    val shallower = targetState.depth < initialState.depth
    return when {
        deeper || shallower -> {
            val dir = if (deeper) 1 else -1
            (slideInHorizontally(tween(220, easing = ease)) { dir * it / 8 } + fadeIn(tween(160, delayMillis = 60, easing = ease))) togetherWith
                (slideOutHorizontally(tween(220, easing = ease)) { -dir * it / 8 } + fadeOut(tween(90, easing = ease)))
        }
        else -> (fadeIn(tween(160, delayMillis = 80, easing = ease)) + scaleIn(tween(160, delayMillis = 80, easing = ease), initialScale = 0.96f)) togetherWith
            fadeOut(tween(80, easing = ease))
    }
}

/** The top bar of the destinations: the Flux mark and the scope chip. */
@Composable
private fun ShellTopBar(state: UiState, scope: String?, onScope: (String?) -> Unit) {
    Row(
        Modifier.fillMaxWidth().statusBarsPadding().padding(start = TiledGutter + 6.dp, end = TiledGutter, top = 6.dp, bottom = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FluxMark(22.dp, fg = Tn.text, accent = Tn.blue)
        ScopeChip(state.devices, scope, onScope, Modifier.weight(1f, fill = false))
    }
}

@DrawableRes
private fun tabIcon(t: Tab): Int = when (t) {
    Tab.Inbox -> Ic.inbox
    Tab.Send -> Ic.send
    Tab.Control -> Ic.tune
    Tab.Computers -> Ic.laptop
}

/** The navigation bar. The Inbox shows the number of items that need the user. */
@Composable
private fun ShellNavBar(tab: Tab, needs: Int, onSelect: (Tab) -> Unit) {
    NavigationBar {
        for (t in Tab.entries) {
            NavigationBarItem(
                selected = t == tab,
                onClick = { onSelect(t) },
                icon = {
                    if (t == Tab.Inbox && needs > 0) {
                        BadgedBox(
                            badge = {
                                Badge(Modifier.clearAndSetSemantics { contentDescription = if (needs == 1) "1 item needs you" else "$needs items need you" }) {
                                    Text(if (needs > 9) "9+" else "$needs")
                                }
                            },
                        ) { Sym(tabIcon(t)) }
                    } else {
                        Sym(tabIcon(t))
                    }
                },
                label = { Text(t.label) },
            )
        }
    }
}

/**
 * A feature screen above a destination. [current] gives the navigation
 * now. Back on a screen pops only that screen, so a screen that leaves
 * late does not pop the screen above it.
 */
@Composable
private fun DetailScreen(route: Route, state: UiState, current: () -> Nav, go: (Nav) -> Unit) {
    val pop = {
        val nav = current()
        if (nav.stack.lastOrNull() == route) nav.back()?.let(go)
    }
    fun push(r: Route) = go(current().push(r))
    val id = route.deviceId
    if (id == null) {
        if (route.page == SYNC_PAGE) SyncScreen(state, pop)
        return
    }
    val device = state.devices.firstOrNull { it.id == id } ?: return
    val page = route.page
    when {
        page == "media" -> TiledMediaScreen(device, pop)
        page == "mic" -> MicScreen(device, pop)
        page == "commands" -> TiledCommandsScreen(device, pop)
        page == AGENTS_PAGE -> TiledAgentsScreen(
            device, pop,
            onOpen = { pane -> push(Route(id, "$AGENT_PAGE$pane")) },
            onOpenTerminal = { pane -> push(Route(id, "$TERMINAL_PAGE$pane")) },
            onNew = { push(Route(id, NEW_PANE_PAGE)) },
        )
        page.startsWith(AGENT_PAGE) -> key(page) { TiledAgentScreen(device, page.removePrefix(AGENT_PAGE), pop) }
        page.startsWith(TERMINAL_PAGE) -> key(page) { TiledTerminalScreen(device, page.removePrefix(TERMINAL_PAGE), pop) }
        // The new pane replaces this page, so Back skips it.
        page == NEW_PANE_PAGE -> TiledNewPaneScreen(device, pop) { what, pane ->
            val nav = current()
            if (nav.stack.lastOrNull() == route) go(nav.replaceTop(Route(id, if (what == "terminal") "$TERMINAL_PAGE$pane" else "$AGENT_PAGE$pane")))
        }
        page == "browse" -> BrowseScreen(device, state.browse, pop)
        page == "touchpad" -> TouchpadScreen(device, pop)
        page == "desktop" -> DesktopScreen(device, pop)
        page == OMARCHY_PAGE -> OmarchyScreen(device, pop)
        // Debug builds open a mode with "camera:<mode>".
        page.startsWith("camera") -> key(page) { CameraScreen(device, pop, CameraMode.fromKey(page.substringAfter(':', ""))) }
    }
}
