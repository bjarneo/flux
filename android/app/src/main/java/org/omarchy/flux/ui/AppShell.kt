package org.omarchy.flux.ui

import android.content.Intent
import androidx.activity.compose.PredictiveBackHandler
import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.EnterExitState
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.ExperimentalTransitionApi
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.SeekableTransitionState
import androidx.compose.animation.core.Transition
import androidx.compose.animation.core.createChildTransition
import androidx.compose.animation.core.rememberTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
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
import androidx.compose.ui.graphics.takeOrElse
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.launch
import org.omarchy.flux.camera.CameraMode
import org.omarchy.flux.camera.CameraScreen
import org.omarchy.flux.core.ApproveRequest
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.InboxArrangement
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.inScope
import org.omarchy.flux.core.inboxReach
import org.omarchy.flux.core.needsYou
import org.omarchy.flux.mic.MicScreen
import org.omarchy.flux.webcam.WebcamScreen

/** Keeps the order that the user gave the Inbox across a recreation: the pinned key, then the deferred keys. */
private val ArrangementSaver = listSaver<InboxArrangement, String>(
    save = { listOf(it.pinned.orEmpty()) + it.deferred },
    restore = { InboxArrangement(pinned = it.firstOrNull()?.ifEmpty { null }, deferred = it.drop(1)) },
)

/**
 * The app structure: the destinations with the scope chip at the top and
 * the navigation bar at the bottom, and the feature screens above a
 * destination. A wide window shows a navigation rail at the side. The
 * destinations change with a fade through, and a feature screen moves in
 * and out on the horizontal axis with the bars of the destination. System
 * Back follows the predictive back gesture. The Remove animations setting
 * turns the motion off.
 */
@OptIn(ExperimentalTransitionApi::class)
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
    notify: NotifyAsk,
    onNotify: () -> Unit,
    onNotifyHide: () -> Unit,
    welcome: String? = null,
) {
    val context = LocalContext.current
    val reduce = rememberReduceMotion()
    val wide = rememberWideWindow()
    val current by rememberUpdatedState(nav)
    val go by rememberUpdatedState(onNav)

    // The Inbox: the ranked items in scope, in the order that the user gave them.
    // The badge counts the items of all computers, so that the scope hides nothing that needs the user.
    var arrangement by rememberSaveable(stateSaver = ArrangementSaver) { mutableStateOf(InboxArrangement()) }
    val all = rememberInboxItems(state)
    val items = remember(all, scope) { all.inScope(scope) }
    LaunchedEffect(items) { arrangement = arrangement.sync(items) }
    val arranged = remember(items, arrangement) { arrangement.arrange(items) }
    val needs = all.needsYou()
    val reach = remember(scope, state.devices) { inboxReach(scope, state.devices) }
    val notices = InboxNotices(
        reach = reach,
        onWifi = state.onWifi,
        scopeName = state.devices.firstOrNull { it.paired && it.id == scope }?.name,
        elsewhere = needs - items.needsYou(),
        notify = notify,
        // The success state of a new pairing shows only in the scope of that computer.
        paired = state.devices.firstOrNull { it.paired && it.id == welcome && it.id == scope }?.name,
        // A sample computer of the demo never connects, so it does not wait. The debug page @connecting is the exception.
        connecting = state.connecting && reach.offline.any { !isDemo(it.id) || org.omarchy.flux.core.DebugInbox.connecting },
    )
    val picker = rememberTargetPicker()
    val tools = rememberSendTools(state.devices, scope, picker)

    val dest = nav.dest
    val seek = remember { SeekableTransitionState(dest) }
    val screens = rememberTransition(seek, label = "screens")
    // 2 parts of 1 transition: the feature screen on top, or null for a destination, and the destination under it.
    val layers = screens.createChildTransition(label = "layers") { it as? Dest.Detail }
    val tabs = screens.createChildTransition(label = "tabs") { it.tab }
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
    val toSync = { open(Route(null, SYNC_PAGE)) }
    // The same intent as Approvals.show: the screen opens in its own task, and Android reuses a screen that waits there.
    val approve: (ApproveRequest) -> Unit = { r ->
        if (isDemo(r.computerId)) {
            FluxCore.toast("This is a sample request")
        } else {
            context.startActivity(Intent(context, ApproveActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }
    val actions = InboxActions(
        open = ::open, approve = approve, showPair = onShowPair, pair = onPair, tools = tools,
        showAll = { onScope(null) }, allowNotifications = onNotify, hideNotifications = onNotifyHide,
    )
    val select = { t: Tab -> go(current.select(t)) }

    CompositionLocalProvider(LocalReduceMotion provides reduce) {
        layers.AnimatedContent(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
            transitionSpec = { layerTransform(reduce) },
        ) { detail ->
            // A screen that moves in, or that the back gesture only shows, takes no new reads,
            // so that it does not race the screen that stays on top.
            val settled = transition.settledVisible()
            if (detail != null) {
                Box(Modifier.fillMaxSize().systemBarsPadding()) {
                    DetailScreen(detail.route, state, current = { current }, go = { go(it) })
                }
            } else {
                // The bars are part of the destination, so that the back gesture shows the destination as it is after Back.
                ShellFrame(wide, nav.tab, needs, select, top = { ShellTopBar(state, scope, onScope) }) {
                    tabs.AnimatedContent(Modifier.fillMaxSize(), transitionSpec = { fadeThrough(reduce) }) { tab ->
                        val active = settled && transition.settledVisible()
                        Box(Modifier.fillMaxSize().semantics { paneTitle = tab.label }) {
                            when (tab) {
                                Tab.Inbox -> InboxScreen(
                                    state, arranged, active, notices, actions,
                                    wide = wide,
                                    onSwipe = { arrangement = arrangement.swipe(it) },
                                    onPromote = { arrangement = arrangement.promote(it) },
                                )
                                Tab.Send -> SendScreen(state, scope, picker, tools, onOpen = ::open, onPair = toComputers)
                                Tab.Control -> ControlScreen(state, scope, picker, onOpen = ::open, onPair = toComputers)
                                Tab.Computers -> ComputersScreen(state, scope, onScope, onPair, onUnpair, onSync = toSync)
                            }
                        }
                    }
                }
            }
        }
        TargetPickerDialog(picker)
    }
}

/** True when the screen is on screen and does not move in or out. */
private fun Transition<EnterExitState>.settledVisible(): Boolean =
    currentState == EnterExitState.Visible && targetState == EnterExitState.Visible

/**
 * The frame of a destination: the top bar, the content, and the navigation
 * bar at the bottom. A wide window shows a navigation rail at the side in
 * the place of the navigation bar.
 */
@Composable
private fun ShellFrame(
    wide: Boolean,
    tab: Tab,
    needs: Int,
    onSelect: (Tab) -> Unit,
    top: @Composable () -> Unit,
    content: @Composable () -> Unit,
) {
    if (wide) {
        Row(Modifier.fillMaxSize()) {
            ShellNavRail(tab, needs, onSelect)
            Column(Modifier.weight(1f).fillMaxHeight()) {
                top()
                // No bar holds the bottom inset, so the content keeps clear of the gesture area.
                Box(Modifier.weight(1f).fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom))) {
                    content()
                }
            }
        }
    } else {
        Column(Modifier.fillMaxSize()) {
            top()
            Box(Modifier.weight(1f).fillMaxWidth()) { content() }
            ShellNavBar(tab, needs, onSelect)
        }
    }
}

/**
 * The motion of a feature screen: the horizontal shared axis into and out
 * of the screen, and a fade through when a screen replaces the screen at
 * the same depth. Each part takes 250 ms or less.
 */
private fun AnimatedContentTransitionScope<Dest.Detail?>.layerTransform(reduce: Boolean): ContentTransform {
    if (reduce) return EnterTransition.None togetherWith ExitTransition.None
    val from = initialState?.depth ?: 0
    val to = targetState?.depth ?: 0
    if (from == to) return fadeThrough(false)
    val ease = FastOutSlowInEasing
    val dir = if (to > from) 1 else -1
    return (slideInHorizontally(tween(220, easing = ease)) { dir * it / 8 } + fadeIn(tween(160, delayMillis = 60, easing = ease))) togetherWith
        (slideOutHorizontally(tween(220, easing = ease)) { -dir * it / 8 } + fadeOut(tween(90, easing = ease)))
}

/** The fade through between 2 destinations, in 240 ms. */
private fun fadeThrough(reduce: Boolean): ContentTransform {
    if (reduce) return EnterTransition.None togetherWith ExitTransition.None
    val ease = FastOutSlowInEasing
    return (fadeIn(tween(160, delayMillis = 80, easing = ease)) + scaleIn(tween(160, delayMillis = 80, easing = ease), initialScale = 0.96f)) togetherWith
        fadeOut(tween(80, easing = ease))
}

/**
 * The top bar of the destinations: the Flux mark and the scope chip. In a
 * window of little height, for example a phone in landscape, it has less
 * space above and below the chip.
 */
@Composable
private fun ShellTopBar(state: UiState, scope: String?, onScope: (String?) -> Unit) {
    val short = rememberShortWindow()
    Row(
        Modifier.fillMaxWidth().statusBarsPadding()
            .padding(start = TiledGutter + 6.dp, end = TiledGutter, top = if (short) 0.dp else 6.dp, bottom = if (short) 4.dp else 8.dp),
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

/**
 * The largest font scale of the navigation labels and of the badge. Above
 * it, "Computers" does not fit on 1 line, and the badge covers its icon.
 */
private const val NAV_FONT_SCALE = 1.5f

/** Gives [content] a font scale of [max] at most. Below [max], the text follows the font size of Android. */
@Composable
private fun MaxFontScale(max: Float, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    if (density.fontScale <= max) {
        content()
    } else {
        CompositionLocalProvider(LocalDensity provides Density(density.density, max), content = content)
    }
}

/**
 * The label of a destination: 1 line that grows with the font size up to
 * [NAV_FONT_SCALE]. A label that does not fit then gets smaller.
 */
@Composable
private fun NavLabel(text: String) {
    MaxFontScale(NAV_FONT_SCALE) {
        val style = LocalTextStyle.current
        BasicText(
            text,
            style = style.copy(color = style.color.takeOrElse { LocalContentColor.current }),
            overflow = TextOverflow.Ellipsis,
            maxLines = 1,
            autoSize = TextAutoSize.StepBased(minFontSize = style.fontSize * 0.75f, maxFontSize = style.fontSize, stepSize = 0.5.sp),
        )
    }
}

/** The icon of a destination. The Inbox shows the number of items that need the user. */
@Composable
private fun TabIcon(t: Tab, needs: Int) {
    if (t != Tab.Inbox || needs == 0) {
        Sym(tabIcon(t))
        return
    }
    BadgedBox(
        badge = {
            MaxFontScale(NAV_FONT_SCALE) {
                Badge(Modifier.clearAndSetSemantics { contentDescription = if (needs == 1) "1 item needs you" else "$needs items need you" }) {
                    Text(if (needs > 9) "9+" else "$needs", maxLines = 1)
                }
            }
        },
    ) { Sym(tabIcon(t)) }
}

/** The navigation bar of a compact window. */
@Composable
private fun ShellNavBar(tab: Tab, needs: Int, onSelect: (Tab) -> Unit) {
    NavigationBar {
        for (t in Tab.entries) {
            NavigationBarItem(selected = t == tab, onClick = { onSelect(t) }, icon = { TabIcon(t, needs) }, label = { NavLabel(t.label) })
        }
    }
}

/** The navigation rail of a medium or expanded window. */
@Composable
private fun ShellNavRail(tab: Tab, needs: Int, onSelect: (Tab) -> Unit) {
    NavigationRail {
        for (t in Tab.entries) {
            NavigationRailItem(selected = t == tab, onClick = { onSelect(t) }, icon = { TabIcon(t, needs) }, label = { NavLabel(t.label) })
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
        // The Webcam was a mode of the camera. Debug builds still open it with "camera:webcam".
        page == WEBCAM_PAGE || page == "camera:webcam" -> WebcamScreen(device, pop)
        // Debug builds open a mode with "camera:<mode>".
        page.startsWith("camera") -> key(page) { CameraScreen(device, pop, CameraMode.fromKey(page.substringAfter(':', ""))) }
    }
}
