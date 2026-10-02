package org.omarchy.flux.ui

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.SurfaceTexture
import android.os.SystemClock
import android.view.Surface
import android.view.TextureView
import androidx.activity.compose.LocalActivity
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.displayCutoutPadding
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlin.math.abs
import kotlin.math.roundToInt
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.RemoteInput
import org.omarchy.flux.desktop.DesktopSession
import org.omarchy.flux.desktop.DesktopViewport
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.voice.Dictation
import org.omarchy.flux.voice.rememberVoiceTyping

/** A finger that stays this long without a motion clicks the right button, or drags when it moves. */
private const val DESKTOP_HOLD_MS = 450L

/** A second tap within this time and distance clicks at the first tap, so that the computer sees a double click. */
private const val DOUBLE_TAP_MS = 400L
private val DoubleTapDistance = 24.dp

/** The controls under the video, or next to it in landscape. */
private enum class Panel { Omarchy, Keys }

/**
 * The screen of the computer on the phone. The computer streams the
 * screen while remote_desktop is on. The touches click, drag, and scroll
 * on the computer while remote_input is on. The phone turns to landscape
 * while the stream shows. The Omarchy panel moves between workspaces and
 * windows, and the keys and the mic type on the computer.
 */
@Composable
fun DesktopScreen(d: DeviceUi, onBack: () -> Unit) {
    val status by DesktopSession.status.collectAsState()
    // The screen shows and takes input only after the phone lock, see rememberRemoteUnlock.
    val unlocked = rememberRemoteUnlock(
        d.online && d.desktopSupported && d.remoteDesktop == true,
        "Show the computer screen", "show the computer screen", onBack, sample = isDemo(d.id),
    )
    val ready = d.online && d.desktopSupported && d.remoteDesktop == true && unlocked
    val control = d.remoteInput == true
    var panel by rememberSaveable { mutableStateOf<Panel?>(null) }
    // The monitor that the user selected. A restart of the stream keeps it.
    var monitor by rememberSaveable(d.id) { mutableStateOf<String?>(null) }
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    if (ready) Landscape(landscape)
    // In landscape, a rail at the side holds the buttons, so that the video has the full height.
    val wide = ready && landscape
    val shown = panel.takeIf { control }
    // Dictation types its words on the computer. A dictation right after another starts with a space.
    var afterVoice by remember { mutableStateOf(false) }
    val voice = rememberVoiceTyping { spoken ->
        sendInput(d, RemoteInput.text(if (afterVoice) " $spoken" else spoken))
        afterVoice = true
    }
    val dictating = voice.dictation.phase != Dictation.Phase.Idle
    fun sendKey(p: Packet) {
        afterVoice = false
        sendInput(d, p)
    }
    fun toggle(p: Panel) {
        panel = if (panel == p) null else p
    }
    val buttons: @Composable () -> Unit = {
        if (ready && status.deviceId == d.id && status.monitors.size > 1) {
            val next = status.monitors[(status.monitors.indexOf(status.monitor) + 1) % status.monitors.size]
            // The key shows the monitor on screen. A tap shows the next monitor.
            MonitorKey(status.monitor, next) {
                monitor = next
                DesktopSession.start(FluxCore, d.id, next)
            }
        }
        if (ready && control) {
            if (d.shortcutsSupported) PanelButton(Ic.grid, "Omarchy", shown == Panel.Omarchy) { toggle(Panel.Omarchy) }
            PanelButton(Ic.keyboard, "Keys", shown == Panel.Keys) { toggle(Panel.Keys) }
            if (voice.available) {
                // Green marks a live microphone, as the privacy dot of Android does.
                PanelButton(Ic.mic, if (dictating) "Stop dictation" else "Dictate", dictating, Tn.green) {
                    panel = Panel.Keys
                    if (dictating) voice.dictation.stop() else voice.start()
                }
            }
        }
    }
    val gutter = Modifier.padding(horizontal = TiledGutter)
    Column(Modifier.fillMaxSize().then(if (wide) Modifier.displayCutoutPadding() else Modifier).imePadding()) {
        if (!wide) {
            Box(gutter) { TiledTopBar("Remote desktop", onBack, context = d.name) { buttons() } }
        }
        when {
            !d.online -> Box(gutter) { NotReachable(d, "The screen and the controls") }
            !d.desktopSupported -> EmptyState(
                Ic.desktop, "Update Flux on ${d.name}",
                "This version of Flux on ${d.name} does not stream its screen.",
                gutter.padding(top = 48.dp),
            )
            d.remoteDesktop != true -> EmptyState(
                Ic.desktop, "Remote desktop is off",
                "On ${d.name}, set remote_desktop = true in ~/.config/flux/config.toml, then run systemctl --user reload fluxd.",
                gutter.padding(top = 48.dp),
            )
            !unlocked -> EmptyState(Ic.desktop, "Unlock to continue", "Confirm with the phone lock to show ${d.name}.", gutter.padding(top = 48.dp))
            else -> {
                // The video keeps its place in both layouts, so a rotation does not restart the stream.
                Row(Modifier.weight(1f).fillMaxWidth()) {
                    if (wide) {
                        Column(
                            Modifier.fillMaxHeight().padding(8.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            SquareButton(Ic.back, "Back", onBack)
                            Spacer(Modifier.weight(1f))
                            buttons()
                        }
                    }
                    Column(Modifier.weight(1f).fillMaxHeight()) {
                        RemoteDesktop(d, monitor, hint = shown == null && !wide)
                    }
                    if (wide) {
                        when (shown) {
                            Panel.Omarchy -> OmarchyPanel(d, Modifier.width(300.dp).fillMaxHeight().padding(8.dp))
                            Panel.Keys -> KeyPanel(d, ::sendKey, Modifier.width(300.dp).align(Alignment.Bottom).padding(8.dp), voice)
                            null -> Unit
                        }
                    }
                }
                if (!wide) {
                    when (shown) {
                        Panel.Omarchy -> OmarchyPanel(d, gutter.padding(top = TileGap, bottom = 10.dp).heightIn(max = 380.dp))
                        Panel.Keys -> KeyPanel(d, ::sendKey, gutter.padding(top = TileGap, bottom = 10.dp), voice)
                        null -> Unit
                    }
                }
            }
        }
    }
}

/**
 * A button that shows or hides a panel: a 40 dp key that takes taps on
 * 48 dp. It has the [accent] color while [on], and TalkBack reads its state.
 */
@Composable
private fun PanelButton(@DrawableRes icon: Int, description: String, on: Boolean, accent: Color = Tn.blue, onClick: () -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    Box(
        Modifier.minimumInteractiveComponentSize().size(40.dp).clip(shape).background(if (on) Tn.accentTile else Tn.tile)
            .border(1.dp, if (on) accent else Tn.line, shape)
            .toggleable(value = on, role = Role.Switch, onValueChange = { onClick() })
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { Sym(icon, tint = if (on) accent else Tn.sub, size = 20.dp) }
}

/** The monitor that the stream shows, in mono. A tap shows the [next] monitor. */
@Composable
private fun MonitorKey(current: String, next: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    Box(
        Modifier.minimumInteractiveComponentSize().heightIn(min = 40.dp).clip(shape).background(Tn.tile).border(1.dp, Tn.line, shape)
            .clickable(onClickLabel = "Show $next", role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "Monitor $current" }
            .padding(horizontal = 10.dp),
        contentAlignment = Alignment.Center,
    ) { T(current, size = 12, color = Tn.text, family = Mono, weight = FontWeight.Medium) }
}

/**
 * Turns the phone to landscape while the screen shows. In landscape, the
 * system bars hide, and a swipe from the edge shows them for a moment.
 */
@Composable
private fun Landscape(landscape: Boolean) {
    val activity = LocalActivity.current ?: return
    DisposableEffect(activity) {
        val before = activity.requestedOrientation
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_USER_LANDSCAPE
        onDispose { activity.requestedOrientation = before }
    }
    val view = LocalView.current
    DisposableEffect(activity, landscape) {
        val bars = WindowCompat.getInsetsController(activity.window, view)
        if (landscape) {
            bars.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            bars.hide(WindowInsetsCompat.Type.systemBars())
        }
        onDispose { bars.show(WindowInsetsCompat.Type.systemBars()) }
    }
}

private fun sendInput(d: DeviceUi, p: Packet) {
    if (!RemoteInput.send(FluxCore, d.id, p)) FluxCore.toast("${d.name} is not reachable")
}

/**
 * The video of the computer screen, with its gestures. The stream runs
 * while the app shows. [hint] shows the gestures under the video.
 */
@Composable
private fun ColumnScope.RemoteDesktop(d: DeviceUi, monitor: String?, hint: Boolean) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val selected by rememberUpdatedState(monitor)
    DisposableEffect(d.id, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                // After the unlock ends, the page asks for the phone lock again before the stream starts.
                Lifecycle.Event.ON_START -> if (ReplyLock.valid() || isDemo(d.id)) DesktopSession.start(FluxCore, d.id, selected)
                Lifecycle.Event.ON_STOP -> DesktopSession.stop()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            DesktopSession.stop()
        }
    }
    val status by DesktopSession.status.collectAsState()
    val live = status.phase == DesktopSession.Phase.Live && status.deviceId == d.id
    val view = LocalView.current
    DisposableEffect(live) {
        view.keepScreenOn = live
        onDispose { view.keepScreenOn = false }
    }

    val control = d.remoteInput == true
    val haptic = LocalHapticFeedback.current
    var warned by remember { mutableStateOf(false) }
    val send by rememberUpdatedState { p: Packet ->
        if (control) {
            sendInput(d, p)
        } else if (!warned) {
            warned = true
            FluxCore.toast("View only. To control ${d.name}, set remote_input = true on it.")
        }
    }

    var box by remember { mutableStateOf(IntSize.Zero) }
    // The video keeps its place before the size is known, so that its surface is ready for the first frame.
    val videoW = status.width.takeIf { it > 0 } ?: 16
    val videoH = status.height.takeIf { it > 0 } ?: 10
    // A new size starts a new viewport at scale 1, and the gestures start again with it.
    val viewport = remember(box, videoW, videoH) { mutableStateOf(DesktopViewport(box.width.toFloat(), box.height.toFloat(), videoW, videoH)) }
    val vp = viewport.value
    val density = LocalDensity.current
    // The gestures work only on a live video. Over a wait or an error, a tap must not click on the computer.
    val gestures = if (live && status.width > 0) {
        Modifier.desktopGestures(viewport, { viewport.value = it }, { send(it) }) { haptic.performHapticFeedback(HapticFeedbackType.LongPress) }
    } else {
        Modifier
    }
    Box(Modifier.weight(1f).fillMaxWidth().clipToBounds().background(Color.Black).onSizeChanged { box = it }.then(gestures)) {
        if (box != IntSize.Zero) {
            Box(
                Modifier.fillMaxSize().graphicsLayer {
                    transformOrigin = TransformOrigin(0f, 0f)
                    scaleX = vp.scale
                    scaleY = vp.scale
                    translationX = vp.offsetX
                    translationY = vp.offsetY
                },
            ) {
                AndroidView(
                    factory = { ctx -> TextureView(ctx).apply { surfaceTextureListener = SurfaceLink() } },
                    modifier = Modifier.offset { IntOffset(vp.fitLeft.roundToInt(), vp.fitTop.roundToInt()) }
                        .size(with(density) { vp.fitWidth.toDp() }, with(density) { vp.fitHeight.toDp() }),
                )
            }
        }
        StreamState(d, status, Modifier.fillMaxSize())
    }
    if (hint) {
        T(
            if (control) "Tap clicks · hold for the right button · hold, then move to drag\n2 fingers scroll · pinch zooms · 1 finger moves the zoomed view"
            else "View only · pinch zooms · 1 finger moves the zoomed view",
            Modifier.fillMaxWidth().padding(horizontal = TiledGutter, vertical = 8.dp),
            size = 11, color = Tn.sub, align = TextAlign.Center, lineHeight = 1.5f,
        )
    }
}

/** The state of the stream over the video: a wait, an error, or a stop. */
@Composable
private fun StreamState(d: DeviceUi, status: DesktopSession.Status, modifier: Modifier) {
    val mine = status.deviceId == d.id
    val waiting = !mine || status.phase == DesktopSession.Phase.Connecting ||
        (status.phase == DesktopSession.Phase.Live && status.width == 0)
    when {
        waiting -> Column(
            modifier,
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        ) {
            Spinner(Modifier.size(28.dp), color = Tn.blue)
            T(if (mine) status.message else "Connecting to ${d.name}…", size = 13, color = Tn.sub)
        }
        status.phase == DesktopSession.Phase.Error || status.phase == DesktopSession.Phase.Idle -> Box(
            modifier.background(Tn.bg).verticalScroll(rememberScrollState()),
            contentAlignment = Alignment.Center,
        ) {
            val problem = if (status.phase == DesktopSession.Phase.Error) desktopProblem(status.message, d.name) else null
            EmptyState(
                Ic.desktop,
                problem?.title ?: "The stream stopped",
                problem?.let { "${it.cause} ${it.step}" } ?: "${status.message.ifEmpty { "The stream stopped" }}. Start the stream again.",
                action = {
                    FluxButton("Start again", { DesktopSession.start(FluxCore, d.id, status.monitor.ifEmpty { null }) }, kind = ButtonKind.Tonal, icon = Ic.refresh)
                },
            )
        }
    }
}

/** Gives the surface of the video view to [DesktopSession]. */
private class SurfaceLink : TextureView.SurfaceTextureListener {
    private var surface: Surface? = null

    override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) {
        surface = Surface(texture).also { DesktopSession.attach(it) }
    }

    override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) = Unit

    override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
        DesktopSession.attach(null)
        surface?.release()
        surface = null
        return true
    }

    override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = Unit
}

private enum class Touch { Pending, Pan, Held, Drag, Multi, Pinch, Scroll }

/** The last tap: its time, its point on the view, and its position on the video. */
private class Tap(val time: Long, val point: Offset, val position: Pair<Float, Float>)

/**
 * The gestures of the remote desktop. A tap clicks. A finger that holds
 * still clicks the right button, or drags when it then moves. 2 fingers
 * scroll, and a tap with 2 fingers clicks the right button. A pinch zooms,
 * and 1 finger moves the zoomed view. [onHold] runs when a finger holds.
 */
private fun Modifier.desktopGestures(
    viewport: State<DesktopViewport>,
    onViewport: (DesktopViewport) -> Unit,
    send: (Packet) -> Unit,
    onHold: () -> Unit,
): Modifier = pointerInput(viewport) {
    val slop = viewConfiguration.touchSlop
    val doubleTap = DoubleTapDistance.toPx()
    var lastTap: Tap? = null
    awaitEachGesture {
        val first = awaitFirstDown(requireUnconsumed = false)
        val start = first.position
        val holdAt = first.uptimeMillis + DESKTOP_HOLD_MS
        var mode = Touch.Pending
        var last = start
        var ids = listOf(first.id)
        var startCentroid = start
        var startSpan = 0f
        var lastCentroid = start
        var lastSpan = 0f
        fun video(p: Offset, clamp: Boolean = false) = viewport.value.toVideo(p.x, p.y, clamp)

        while (true) {
            val event = if (mode == Touch.Pending) {
                val left = holdAt - SystemClock.uptimeMillis()
                if (left > 0) withTimeoutOrNull(left) { awaitPointerEvent() } else null
            } else {
                awaitPointerEvent()
            }
            if (event == null) {
                // The finger held still: the pointer goes under it.
                mode = Touch.Held
                onHold()
                video(start)?.let { (x, y) -> send(RemoteInput.at(x, y)) }
                continue
            }
            val down = event.changes.filter { it.pressed }
            if (down.isEmpty()) break
            val nowIds = down.map { it.id }
            if (down.size >= 2 && (mode == Touch.Pending || mode == Touch.Pan)) {
                mode = Touch.Multi
                startCentroid = centroid(down)
                startSpan = span(down, startCentroid)
            }
            when (mode) {
                Touch.Pending, Touch.Pan -> {
                    val p = down[0].position
                    if (mode == Touch.Pending && (p - start).getDistance() >= slop) mode = Touch.Pan
                    if (mode == Touch.Pan) onViewport(viewport.value.pan(p.x - last.x, p.y - last.y))
                    if (mode == Touch.Pan) last = p
                }
                Touch.Held, Touch.Drag -> {
                    val p = (down.firstOrNull { it.id == first.id } ?: down[0]).position
                    if (mode == Touch.Held && (p - start).getDistance() >= slop) {
                        mode = Touch.Drag
                        video(start, clamp = true)?.let { (x, y) -> send(RemoteInput.holdAt(true, x, y)) }
                    }
                    if (mode == Touch.Drag && p != last) video(p, clamp = true)?.let { (x, y) -> send(RemoteInput.at(x, y)) }
                    last = p
                }
                Touch.Multi, Touch.Pinch, Touch.Scroll -> if (down.size >= 2) {
                    val c = centroid(down)
                    val s = span(down, c)
                    // A finger that lands or lifts moves the center. The next motion starts from there.
                    if (nowIds == ids) {
                        if (mode == Touch.Multi) {
                            if (abs(s - startSpan) > slop) {
                                mode = Touch.Pinch
                            } else if ((c - startCentroid).getDistance() > slop) {
                                mode = Touch.Scroll
                                // The scroll goes to the window under the fingers.
                                video(startCentroid)?.let { (x, y) -> send(RemoteInput.at(x, y)) }
                            }
                        }
                        val v = viewport.value
                        when (mode) {
                            Touch.Pinch -> onViewport(
                                v.zoom(if (lastSpan > 0f) s / lastSpan else 1f, lastCentroid.x, lastCentroid.y, c.x - lastCentroid.x, c.y - lastCentroid.y),
                            )
                            // Natural scrolling: the content follows the fingers.
                            Touch.Scroll -> send(RemoteInput.scroll(-(c.x - lastCentroid.x) / v.pixel, -(c.y - lastCentroid.y) / v.pixel))
                            else -> Unit
                        }
                    }
                    lastCentroid = c
                    lastSpan = s
                }
            }
            ids = nowIds
            event.changes.forEach { it.consume() }
        }
        when (mode) {
            Touch.Pending -> video(start)?.let { position ->
                val now = SystemClock.uptimeMillis()
                val prev = lastTap
                val at = if (prev != null && now - prev.time < DOUBLE_TAP_MS && (start - prev.point).getDistance() < doubleTap) prev.position else position
                send(RemoteInput.clickAt(RemoteInput.Click.Left, at.first, at.second))
                lastTap = Tap(now, start, at)
            }
            Touch.Held -> video(start)?.let { (x, y) -> send(RemoteInput.clickAt(RemoteInput.Click.Right, x, y)) }
            Touch.Drag -> video(last, clamp = true)?.let { (x, y) -> send(RemoteInput.holdAt(false, x, y)) }
            Touch.Multi -> video(startCentroid)?.let { (x, y) -> send(RemoteInput.clickAt(RemoteInput.Click.Right, x, y)) }
            else -> Unit
        }
    }
}

private fun centroid(down: List<PointerInputChange>): Offset {
    var sum = Offset.Zero
    for (c in down) sum += c.position
    return sum / down.size.toFloat()
}

/** The mean distance of the fingers from their center. */
private fun span(down: List<PointerInputChange>, center: Offset): Float =
    down.sumOf { (it.position - center).getDistance().toDouble() }.toFloat() / down.size
