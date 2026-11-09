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
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.add
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
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
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.launch
import org.omarchy.flux.camera.CameraMode
import org.omarchy.flux.camera.CameraScreen
import org.omarchy.flux.core.ApproveRequest
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.inboxReach
import org.omarchy.flux.core.needsYou
import org.omarchy.flux.mic.MicScreen
import org.omarchy.flux.stream.LiveStreams
import org.omarchy.flux.webcam.WebcamScreen
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.getValue

/**
 * The app structure: the destinations with the navigation bar at the
 * bottom, and the feature screens above a destination, such as the chat of
 * 1 computer or 1 agent. A wide window shows a navigation rail at the side.
 * A swipe moves between the destinations, and a tap on the bar moves to
 * one. A feature screen moves in and out on the horizontal axis with the
 * bars of the destination. System Back follows the predictive back
 * gesture. The Remove animations setting turns the motion off.
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

    // The agents, the approval, and the pair requests of all computers. The badge counts what needs the user.
    val all = rememberChatEvents(state)
    val needs = all.needsYou()
    val live by LiveStreams.live.collectAsStateWithLifecycle()
    // The notices of the list of chats are about all computers. The chat of 1 computer has the notices of that computer.
    fun notices(computer: String?): InboxNotices {
        val reach = inboxReach(computer, state.devices)
        return InboxNotices(
            reach = reach,
            onWifi = state.onWifi,
            scopeName = state.devices.firstOrNull { it.paired && it.id == computer }?.name,
            elsewhere = 0,
            notify = if (computer == null) notify else NotifyAsk.None,
            // The success state of a new pairing shows in the chat of that computer.
            paired = state.devices.firstOrNull { it.paired && it.id == welcome && (computer == null || it.id == computer) }?.name,
            // A sample computer of the demo never connects, so it does not wait. The debug page @connecting is the exception.
            connecting = state.connecting && reach.offline.any { !isDemo(it.id) || org.omarchy.flux.core.DebugInbox.connecting },
            streams = live.filter { computer == null || it.deviceId == computer }
                .map { s -> StreamNotice(s, state.devices.firstOrNull { it.id == s.deviceId }?.name ?: "the computer") },
        )
    }
    val picker = rememberTargetPicker()

    // A tablet in landscape shows the chat of a computer or an agent at the side of the list of chats.
    val split = wide && !rememberShortWindow()
    val dest = nav.dest
    val seek = remember { SeekableTransitionState(dest) }
    val screens = rememberTransition(seek, label = "screens")
    // 2 parts of 1 transition: the feature screen on top, or null for a destination, and the destination under it.
    // In a split window, the chat above Chats is part of the destination.
    val layers = screens.createChildTransition(label = "layers") { d -> (d as? Dest.Detail)?.takeUnless { split && sideChat(it) } }
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

    // In a split window, a chat from Chats takes the place of the chat at the side.
    // A chat from another destination opens above that destination, so Back goes there.
    fun open(r: Route) = go(
        if (split && isChatPage(r) && current.tab == Tab.Chat && (current.stack.isEmpty() || sideChat(current.dest))) Nav(Tab.Chat, listOf(r)) else current.push(r),
    )
    val toComputers = { go(Nav(Tab.Computers)) }
    val toSync = { open(Route(null, SYNC_PAGE)) }
    val toAbout = { open(Route(null, ABOUT_PAGE)) }
    val toSsh = { open(Route(null, SSH_PAGE)) }
    // The same intent as Approvals.show: the screen opens in its own task, and Android reuses a screen that waits there.
    val approve: (ApproveRequest) -> Unit = { r ->
        if (isDemo(r.computerId)) {
            FluxCore.toast("This is a sample request")
        } else {
            context.startActivity(Intent(context, ApproveActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }
    val actions = ChatActions(
        open = ::open, approve = approve, showPair = onShowPair, pair = onPair,
        showAll = { onScope(null) }, allowNotifications = onNotify, hideNotifications = onNotifyHide,
        go = { t -> go(current.select(t)) },
        control = { id ->
            onScope(id)
            go(Nav(Tab.Control))
        },
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
                    DetailScreen(detail.route, state, current = { current }, go = { go(it) }) { d, pop ->
                        ComputerChatScreen(state, d, all, settled, notices(d.id), actions, onBack = pop, tray = detail.route.page == CHAT_TRAY_PAGE)
                    }
                }
            } else {
                // The destinations lie side by side, so a swipe moves between them. Each draws its own header.
                val pager = rememberPagerState(initialPage = nav.tab.ordinal) { Tab.entries.size }
                // A tap on the bar, Back, or a link moves the pager to the destination.
                LaunchedEffect(nav.tab) {
                    val to = nav.tab.ordinal
                    if (pager.targetPage != to) if (reduce) pager.scrollToPage(to) else pager.animateScrollToPage(to)
                }
                // A swipe selects the destination where the pager stops.
                LaunchedEffect(pager) {
                    snapshotFlow { pager.settledPage }.collect { page ->
                        val t = Tab.entries[page]
                        val root = current.stack.isEmpty() || (split && sideChat(current.dest))
                        if (root && current.tab != t) go(current.select(t))
                    }
                }
                // The bars are part of the destination, so that the back gesture shows the destination as it is after Back.
                // The bar follows the destination nearest the middle.
                val shown = Tab.entries[pager.currentPage]
                ShellFrame(wide, shown, needs, select) {
                    HorizontalPager(pager, Modifier.fillMaxSize(), key = { Tab.entries[it] }) { page ->
                        val tab = Tab.entries[page]
                        // Only the destination where the pager stops reads its data.
                        val active = settled && pager.settledPage == page
                        Box(Modifier.fillMaxSize().semantics { paneTitle = tab.label }) {
                            when (tab) {
                                Tab.Chat -> if (split) {
                                    val side = (current.dest as? Dest.Detail)?.takeIf(::sideChat)?.route
                                    ChatsSplit(side, list = { ChatsScreen(state, active, notices(null), actions, picker, selected = side) }) { r ->
                                        val d = state.devices.firstOrNull { it.id == r.deviceId } ?: return@ChatsSplit
                                        val close = { go(Nav(Tab.Chat)) }
                                        key(r) {
                                            if (r.page.startsWith(AGENT_PAGE)) {
                                                TiledAgentScreen(d, r.page.removePrefix(AGENT_PAGE), close)
                                            } else {
                                                ComputerChatScreen(state, d, all, active, notices(d.id), actions, onBack = close, tray = r.page == CHAT_TRAY_PAGE)
                                            }
                                        }
                                    }
                                } else {
                                    ChatsScreen(state, active, notices(null), actions, picker)
                                }
                                Tab.Control -> ControlScreen(state, scope, onScope, picker, onOpen = ::open, onPair = toComputers)
                                Tab.Computers -> ComputersScreen(state, scope, onScope, onPair, onUnpair, onSync = toSync, onSsh = toSsh, onAbout = toAbout)
                            }
                        }
                    }
                }
            }
        }
        TargetPickerDialog(picker)
    }
}

/** True for the chat of a computer or an agent. */
private fun isChatPage(r: Route): Boolean =
    r.deviceId != null && (r.page == CHAT_PAGE || r.page == CHAT_TRAY_PAGE || r.page.startsWith(AGENT_PAGE))

/** True when [d] is a chat right above Chats, which a split window shows at the side of the list. */
private fun sideChat(d: Dest): Boolean = d is Dest.Detail && d.depth == 1 && d.tab == Tab.Chat && isChatPage(d.route)

/** The width of the list of chats in a split window. */
private val ChatsListWidth = 380.dp

/**
 * Chats in a split window: the [list] at the start, a `line` rule, and the
 * chat of [side] in the rest of the width, or a line that tells what to
 * select. [chat] draws the chat of a route.
 */
@Composable
private fun ChatsSplit(side: Route?, list: @Composable () -> Unit, chat: @Composable (Route) -> Unit) {
    Row(Modifier.fillMaxSize()) {
        Box(Modifier.width(ChatsListWidth).fillMaxHeight()) { list() }
        Box(Modifier.width(1.dp).fillMaxHeight().background(Tn.line))
        Box(Modifier.weight(1f).fillMaxHeight().statusBarsPadding()) {
            if (side != null) {
                chat(side)
            } else {
                EmptyState(Ic.chat, "Select a chat", "The chat of a computer or an agent shows here.", Modifier.align(Alignment.Center))
            }
        }
    }
}

/** True when the screen is on screen and does not move in or out. */
private fun Transition<EnterExitState>.settledVisible(): Boolean =
    currentState == EnterExitState.Visible && targetState == EnterExitState.Visible

/**
 * The frame of a destination: the content, and the navigation bar at the
 * bottom. A wide window shows a navigation rail at the side in the place
 * of the navigation bar. The content draws its own header under the
 * status bar.
 */
@Composable
private fun ShellFrame(
    wide: Boolean,
    tab: Tab,
    needs: Int,
    onSelect: (Tab) -> Unit,
    content: @Composable () -> Unit,
) {
    if (wide) {
        Row(Modifier.fillMaxSize()) {
            ShellNavRail(tab, needs, onSelect)
            // No bar holds the bottom inset, so the content keeps clear of the gesture area.
            Box(Modifier.weight(1f).fillMaxHeight().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom))) {
                content()
            }
        }
    } else {
        Column(Modifier.fillMaxSize()) {
            // The keyboard covers the navigation bar, so a field of the content moves up only by the rest of the keyboard.
            val inset = WindowInsets.navigationBars.add(WindowInsets(bottom = NavBarHeight))
            Box(Modifier.weight(1f).fillMaxWidth().consumeWindowInsets(inset)) {
                content()
            }
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

@DrawableRes
private fun tabIcon(t: Tab): Int = when (t) {
    Tab.Chat -> Ic.chat
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

/** The icon of a destination. The chat shows the number of items that need the user. */
@Composable
private fun TabIcon(t: Tab, needs: Int) {
    if (t != Tab.Chat || needs == 0) {
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

/** The height of the navigation bar of a compact window, without the gesture area. */
private val NavBarHeight = 66.dp

/**
 * The navigation bar of a compact window: 3 destinations, each with an
 * icon in a pill and a label. The pill of the open destination has a fill.
 * Chats shows the number of items that need the user on its pill.
 */
@Composable
private fun ShellNavBar(tab: Tab, needs: Int, onSelect: (Tab) -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .background(Tn.bg)
            .windowInsetsPadding(WindowInsets.navigationBars)
            .heightIn(min = NavBarHeight)
            .padding(top = 6.dp)
            .selectableGroup(),
    ) {
        for (t in Tab.entries) NavBarItem(t, t == tab, if (t == Tab.Chat) needs else 0, Modifier.weight(1f)) { onSelect(t) }
    }
}

/** A destination of [ShellNavBar]. [badge] is the number on the pill, or 0 for none. */
@Composable
private fun NavBarItem(t: Tab, selected: Boolean, badge: Int, modifier: Modifier, onClick: () -> Unit) {
    val ink = if (selected) Tn.text else Tn.sub
    Column(
        modifier.selectable(selected = selected, role = Role.Tab, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(Modifier.size(56.dp, 30.dp)) {
            Box(
                Modifier.fillMaxSize().clip(RoundedCornerShape(15.dp)).background(if (selected) Tn.line else Color.Transparent),
                contentAlignment = Alignment.Center,
            ) { Sym(tabIcon(t), tint = ink, size = 22.dp) }
            if (badge > 0) {
                MaxFontScale(NAV_FONT_SCALE) {
                    Box(
                        Modifier.align(Alignment.TopEnd).offset(x = (-8).dp, y = (-4).dp).heightIn(min = 16.dp).widthIn(min = 16.dp)
                            .clip(RoundedCornerShape(8.dp)).background(Tn.red).padding(horizontal = 4.dp)
                            .clearAndSetSemantics { contentDescription = if (badge == 1) "1 item needs you" else "$badge items need you" },
                        contentAlignment = Alignment.Center,
                    ) {
                        BasicText(
                            if (badge > 9) "9+" else "$badge",
                            style = TextStyle(color = Tn.onAccent, fontSize = 10.sp, fontWeight = FontWeight.Bold, lineHeight = 16.sp),
                            maxLines = 1,
                        )
                    }
                }
            }
        }
        CompositionLocalProvider(
            LocalTextStyle provides TextStyle(color = ink, fontSize = 12.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium),
        ) { NavLabel(t.label) }
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
 * late does not pop the screen above it. [chat] draws the chat of 1
 * computer with the function that pops it.
 */
@Composable
private fun DetailScreen(route: Route, state: UiState, current: () -> Nav, go: (Nav) -> Unit, chat: @Composable (DeviceUi, () -> Unit) -> Unit) {
    val pop = {
        val nav = current()
        if (nav.stack.lastOrNull() == route) nav.back()?.let(go)
    }
    fun push(r: Route) = go(current().push(r))
    val id = route.deviceId
    if (id == null) {
        when (route.page) {
            SYNC_PAGE -> SyncScreen(state, pop)
            ABOUT_PAGE -> AboutScreen(pop)
            SSH_PAGE -> SshKeyScreen(pop)
        }
        return
    }
    val device = state.devices.firstOrNull { it.id == id } ?: return
    val page = route.page
    when {
        page == CHAT_PAGE || page == CHAT_TRAY_PAGE -> key(device.id) { chat(device, pop) }
        page == "media" -> TiledMediaScreen(device, pop)
        page == MIC_PAGE -> MicScreen(device, pop)
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
        page == "touchpad" -> TouchpadScreen(device, state.touchpadScroll, pop)
        page == "desktop" -> DesktopScreen(device, pop)
        page == EXTEND_PAGE -> DesktopScreen(device, pop, extend = true)
        page == OMARCHY_PAGE -> OmarchyScreen(device, pop)
        // The Webcam was a mode of the camera. Debug builds still open it with "camera:webcam".
        page == WEBCAM_PAGE || page == "camera:webcam" -> WebcamScreen(device, pop)
        // Debug builds open a mode with "camera:<mode>".
        page.startsWith("camera") -> key(page) { CameraScreen(device, pop, CameraMode.fromKey(page.substringAfter(':', ""))) }
    }
}
