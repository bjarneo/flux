package org.omarchy.flux.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.withResumed
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import org.omarchy.flux.core.ApproveKeys
import org.omarchy.flux.core.ComputerThemes
import org.omarchy.flux.core.DebugFirstRun
import org.omarchy.flux.core.DebugInbox
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.PairState
import org.omarchy.flux.core.RemoteInput
import org.omarchy.flux.core.Ringer
import org.omarchy.flux.core.StreamKind
import org.omarchy.flux.core.StreamRequest
import org.omarchy.flux.core.StreamRequests
import org.omarchy.flux.mic.MicSession
import org.omarchy.flux.service.FluxService
import org.omarchy.flux.webcam.WebcamSession

class MainActivity : ComponentActivity() {
    /** Debug builds only: the page that the `flux.debug.page` extra asks for. */
    val debugPage = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)

    /** The device ID and the pane of the agent that a notification opens. */
    val openAgent = kotlinx.coroutines.flow.MutableStateFlow<Pair<String, String>?>(null)

    /** The page of a stream that the Start action of a stream request notification opens. */
    val openStream = kotlinx.coroutines.flow.MutableStateFlow<StreamOpen?>(null)

    /** What the Inbox shows about the notification permission. See [updateNotifyAsk]. */
    val notifyAsk = kotlinx.coroutines.flow.MutableStateFlow(NotifyAsk.None)

    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { updateNotifyAsk() }

    /** The questions that the app asked. They survive a restart. */
    private val asks by lazy { getSharedPreferences("asks", MODE_PRIVATE) }

    /**
     * True when a window of another app covered this window during the last
     * touch. The pair sheet then refuses the tap, because an overlay can
     * show a false code over the real one.
     */
    @Volatile var touchObscured = false
        private set

    override fun onCreate(savedInstanceState: Bundle?) {
        // The system bars are transparent. TiledTheme sets the color of their icons.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        FluxCore.init(this)
        updateNotifyAsk()
        // The app scans for computers once when it opens, not after a recreation.
        FluxService.start(this, if (savedInstanceState == null) FluxService.ACTION_SCAN else null)
        debugShowWhenLocked(intent)
        takeOpenAgent(intent)
        takeOpenStream(intent)
        // The system splash screen shows the Flux mark until the first frame. The app plays no start animation.
        setContent { TiledTheme { FluxRoot(this) } }
    }

    /**
     * Reads the notification permission. Android shows its dialog before the
     * first request and once more after 1 denial. After that, only the
     * notification settings of Flux can turn the notifications on.
     */
    fun updateNotifyAsk() {
        // With the permission, the notifications can still be off in the settings of Android.
        val granted = Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        notifyAsk.value = when {
            NotificationManagerCompat.from(this).areNotificationsEnabled() || asks.getBoolean(NOTIFY_HIDDEN, false) -> NotifyAsk.None
            !granted && (!asks.getBoolean(NOTIFY_ASKED, false) || shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) -> NotifyAsk.Allow
            else -> NotifyAsk.Settings
        }
    }

    /** Shows the permission dialog of Android, or the notification settings of Flux when Android does not show the dialog. */
    fun allowNotifications() {
        if (notifyAsk.value == NotifyAsk.Allow && Build.VERSION.SDK_INT >= 33) {
            asks.edit { putBoolean(NOTIFY_ASKED, true) }
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        val settings = android.content.Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
        runCatching { startActivity(settings) }
    }

    /**
     * Shows the permission dialog of Android once, after the first pairing.
     * The success state of the Inbox tells why before the dialog shows.
     * Nothing shows when the app asked before, or when Android needs no
     * permission.
     */
    fun askNotificationsAfterPairing() {
        if (Build.VERSION.SDK_INT < 33 || notifyAsk.value != NotifyAsk.Allow || asks.getBoolean(NOTIFY_ASKED, false)) return
        allowNotifications()
    }

    /** Hides the notification question. It does not show again. */
    fun hideNotifyAsk() {
        asks.edit { putBoolean(NOTIFY_HIDDEN, true) }
        notifyAsk.value = NotifyAsk.None
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        debugShowWhenLocked(intent)
        takeOpenAgent(intent)
        takeOpenStream(intent)
    }

    /**
     * Reads the Start action of a stream request notification. The extras
     * go, so that a new activity does not use them again. Another app can
     * start this activity too, so only the one-time key of the notification
     * opens the page and starts the stream. An intent without a valid key
     * changes nothing: it opens no page and removes no notification.
     */
    private fun takeOpenStream(intent: android.content.Intent?) {
        val device = intent?.getStringExtra(EXTRA_STREAM_DEVICE) ?: return
        val kind = StreamKind.fromKey(intent.getStringExtra(EXTRA_STREAM_KIND))
        val key = intent.getStringExtra(EXTRA_STREAM_KEY)
        intent.removeExtra(EXTRA_STREAM_DEVICE)
        intent.removeExtra(EXTRA_STREAM_KIND)
        intent.removeExtra(EXTRA_STREAM_KEY)
        if (intent.action != StreamRequests.ACTION_START || kind == null) return
        if (!StreamRequests.redeem(this, key, device, kind)) return
        openStream.value = StreamOpen(device, kind)
    }

    override fun onStart() {
        super.onStart()
        StreamRequests.setOnScreen(this, true)
    }

    override fun onStop() {
        StreamRequests.setOnScreen(this, false)
        super.onStop()
    }

    /**
     * Reads the agent that a notification opens. The extras go, so that a
     * new activity does not open it again. Another app can start this
     * activity too, so a pane that is not a herdr pane ID is ignored.
     */
    private fun takeOpenAgent(intent: android.content.Intent?) {
        val device = intent?.getStringExtra(EXTRA_DEVICE) ?: return
        val pane = intent.getStringExtra(EXTRA_PANE) ?: return
        intent.removeExtra(EXTRA_DEVICE)
        intent.removeExtra(EXTRA_PANE)
        if (!PANE_ID.matches(pane)) return
        openAgent.value = device to pane
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> touchObscured = Overlays.obscured(ev)
            MotionEvent.ACTION_UP -> touchObscured = touchObscured || Overlays.obscured(ev)
        }
        return super.dispatchTouchEvent(ev)
    }

    companion object {
        /** The intent action of an agent notification. */
        const val ACTION_OPEN_AGENT = "org.omarchy.flux.OPEN_AGENT"

        /** The device ID of the agent that a notification opens. */
        const val EXTRA_DEVICE = "flux.open.device"

        /** The herdr pane of the agent that a notification opens. */
        const val EXTRA_PANE = "flux.open.pane"

        /** The device ID of the computer of a stream request that a notification opens. */
        const val EXTRA_STREAM_DEVICE = "flux.stream.device"

        /** The kind of the stream request, webcam or mic. */
        const val EXTRA_STREAM_KIND = "flux.stream.kind"

        /** The one-time key of the notification, see [StreamRequests.redeem]. */
        const val EXTRA_STREAM_KEY = "flux.stream.key"

        /** The form of a herdr pane ID, such as w1:p2. */
        private val PANE_ID = Regex("^[A-Za-z0-9_.:-]{1,64}$")

        /** True after the first permission dialog for notifications. */
        private const val NOTIFY_ASKED = "notifyAsked"

        /** True after the user hid the notification question. */
        private const val NOTIFY_HIDDEN = "notifyHidden"
    }

    /**
     * Debug builds only: `adb shell am start -n org.omarchy.flux/.ui.MainActivity
     * --ez flux.debug.showWhenLocked true` shows the app over the lock screen,
     * so that screenshots work on a locked test phone.
     */
    private fun debugShowWhenLocked(intent: android.content.Intent?) {
        if (!org.omarchy.flux.BuildConfig.DEBUG) return
        if (intent?.getBooleanExtra("flux.debug.demo", false) == true) {
            org.omarchy.flux.core.DebugDemo.on = true
            org.omarchy.flux.core.DebugDemo.agentOutput =
                intent.getStringExtra("flux.debug.output")
            FluxCore.publish()
        }
        intent?.getStringExtra("flux.debug.theme")?.let { org.omarchy.flux.core.DebugTheme.select(it) }
        intent?.getStringExtra("flux.debug.page")?.let { debugPage.value = it }
        if (intent?.getBooleanExtra("flux.debug.showWhenLocked", false) != true) return
        setShowWhenLocked(true)
        setTurnScreenOn(true)
    }

    override fun onResume() {
        super.onResume()
        FluxService.start(this, FluxService.ACTION_REFRESH)
        // The user can turn the notifications on in the settings of Android, then come back.
        updateNotifyAsk()
    }

    /** On the touchpad screen, the volume keys can change the slides on the computer. */
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (slideKey(keyCode)) {
            if (event.repeatCount == 0) RemoteInput.onVolumeKey(FluxCore, keyCode == KeyEvent.KEYCODE_VOLUME_UP)
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean = slideKey(keyCode) || super.onKeyUp(keyCode, event)

    private fun slideKey(keyCode: Int): Boolean =
        (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) && RemoteInput.volumeKeysDevice != null
}

/**
 * Debug builds only: true for a sample computer of [org.omarchy.flux.core.DebugDemo].
 * A real computer can use a device ID that starts with demo-, so a release
 * build never treats a computer as a sample.
 */
internal fun isDemo(id: String?): Boolean =
    org.omarchy.flux.BuildConfig.DEBUG && org.omarchy.flux.core.DebugDemo.on && org.omarchy.flux.core.DebugDemo.isDemo(id) &&
        id in setOf(org.omarchy.flux.core.DebugDemo.PC, org.omarchy.flux.core.DebugDemo.OFFLINE, org.omarchy.flux.core.DebugDemo.NEW)

/** What the Inbox shows about the notification permission. */
enum class NotifyAsk {
    /** The notifications are on, or the user hid the question. */
    None,

    /** Android can show its permission dialog. */
    Allow,

    /** Android does not show its dialog again. The notification settings of Flux can turn the notifications on. */
    Settings,
}

/**
 * The page of a stream that the Start action of a stream request
 * notification opens. The page then starts the stream, see
 * [MainActivity.takeOpenStream].
 */
data class StreamOpen(val deviceId: String, val kind: StreamKind)

/** Keeps the navigation across a recreation of the activity, see [Nav.save]. */
private val NavSaver = listSaver<Nav, String>(save = { it.save() }, restore = { Nav.restore(it) })

/** A pairing that this phone starts. The dialog shows the key before the request goes out. */
private data class Outgoing(val deviceId: String, val timestamp: Long, val key: String, val sent: Boolean = false)

/** The debug pages that need no computer: the destinations, the sync switches, and About Flux. */
private val DestinationPages = setOf("inbox", "send", "control", "computers", "devices", SYNC_PAGE, ABOUT_PAGE)

/** How long the Inbox shows that a new computer is paired, in milliseconds while the app is in the front. */
private const val WELCOME_MS = 6_000L

/** The time between the success state of the first pairing and the notification dialog of Android, in milliseconds. */
private const val NOTIFY_ASK_DELAY_MS = 1_000L

@Composable
fun FluxRoot(activity: MainActivity) {
    val core by FluxCore.state.collectAsStateWithLifecycle()
    // Debug builds with the demo add sample data for the Omarchy panel and the first run. Release builds keep the state as it is.
    val state = remember(core) { if (org.omarchy.flux.BuildConfig.DEBUG) DebugInbox.decorate(DebugFirstRun.decorate(core)) else core }
    var nav by rememberSaveable(stateSaver = NavSaver) { mutableStateOf(Nav()) }
    // The computer in scope, or null for all computers.
    var scope by rememberSaveable { mutableStateOf<String?>(null) }
    val snacks = remember { SnackbarHostState() }
    var outgoing by remember { mutableStateOf<Outgoing?>(null) }
    var unpairing by remember { mutableStateOf<String?>(null) }

    // A new message replaces the one on screen.
    LaunchedEffect(Unit) {
        FluxCore.toasts.collectLatest { snacks.showSnackbar(it) }
    }
    // The Computer theme follows the computer in scope, or the last theme for all computers.
    LaunchedEffect(scope) { ComputerThemes.setScope(scope) }
    // Leave the screens of a computer that is gone or no longer paired, and show all computers again.
    val pairedIds = state.devices.filter { it.paired }.map { it.id }.toSet()
    LaunchedEffect(pairedIds, nav) {
        nav = nav.without { it !in pairedIds }
        if (scope != null && scope !in pairedIds) scope = null
    }
    // Notifications carry the approvals and the agent alerts, so the Inbox asks for them after the first pairing.
    // The sample computers of a debug build do not count, so that screenshots show no question.
    val anyPaired = state.devices.any { it.paired && !isDemo(it.id) }
    val notify by activity.notifyAsk.collectAsStateWithLifecycle()
    val wide = rememberWideWindow()

    // A new pairing opens the Inbox of the new computer, with a short success state on top.
    // The state of the computer can come after the event, so the effect waits for it.
    val newPairing by FluxCore.newPairing.collectAsStateWithLifecycle()
    var welcome by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(newPairing, pairedIds) {
        val id = newPairing ?: return@LaunchedEffect
        if (id !in pairedIds) return@LaunchedEffect
        FluxCore.takeNewPairing(id)
        welcome = id
        scope = id
        nav = Nav()
    }
    // After the first pairing, the success state tells why Flux needs notifications.
    // Android asks 1 second later, so that the user reads the reason before the dialog covers the screen.
    // The success state then shows for a short time. The time starts again after the dialog of Android closes.
    LaunchedEffect(welcome) {
        val id = welcome ?: return@LaunchedEffect
        if (!isDemo(id)) {
            activity.lifecycle.withResumed { }
            delay(NOTIFY_ASK_DELAY_MS)
            activity.lifecycle.withResumed { activity.askNotificationsAfterPairing() }
        }
        activity.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            delay(WELCOME_MS)
            welcome = null
        }
    }
    // Close the outgoing dialog when the pairing ends.
    val out = outgoing
    val outDevice = state.devices.firstOrNull { it.id == out?.deviceId }
    LaunchedEffect(out, outDevice?.pairState) {
        if (out == null) return@LaunchedEffect
        if (outDevice == null || outDevice.paired || (out.sent && outDevice.pairState == PairState.None)) outgoing = null
    }

    // Debug builds only: open a page from adb. See the Test section of docs/android.md.
    val debugPage by activity.debugPage.collectAsStateWithLifecycle()
    var showIcons by remember { mutableStateOf(false) }
    LaunchedEffect(debugPage, state.devices.size) {
        val request = debugPage ?: return@LaunchedEffect
        showIcons = request == "icon"
        // Each page starts from a clean screen.
        FluxCore.setRinging(null)
        StreamRequests.dismissAll(activity)
        outgoing = null
        unpairing = null
        welcome = null
        // With the demo, "firstrun" shows the Inbox before the first pairing, with the sample computer to pair.
        // "paired" pairs that sample computer, so that the Inbox shows the success state of a new pairing.
        val firstRun = when (request) {
            "firstrun" -> DebugFirstRun.Mode.FirstRun
            "paired" -> DebugFirstRun.Mode.Paired
            else -> DebugFirstRun.Mode.Off
        }
        if (firstRun != DebugFirstRun.mode) {
            DebugFirstRun.mode = firstRun
            FluxCore.publish()
        }
        if (firstRun != DebugFirstRun.Mode.Off) {
            nav = Nav()
            scope = null
            if (firstRun == DebugFirstRun.Mode.Paired) FluxCore.notePairing(org.omarchy.flux.core.DebugDemo.NEW)
            activity.debugPage.value = null
            return@LaunchedEffect
        }
        if (showIcons) {
            activity.debugPage.value = null
            return@LaunchedEffect
        }
        if (request == "empty") {
            org.omarchy.flux.core.DebugDemo.on = false
            FluxCore.publish()
            nav = Nav()
            scope = null
            activity.debugPage.value = null
            return@LaunchedEffect
        }
        // "<page>@offline" opens the page of a paired computer that is not reachable.
        // "<page>@connecting" opens the same page while that computer still connects.
        val page = request.substringBefore('@')
        val connecting = request.endsWith("@connecting")
        val offline = connecting || request.endsWith("@offline")
        if (connecting != DebugInbox.connecting) {
            DebugInbox.connecting = connecting
            FluxCore.publish()
        }
        val d = if (offline) {
            state.devices.firstOrNull { it.paired && !it.online }
        } else {
            state.devices.firstOrNull { it.paired && it.online } ?: state.devices.firstOrNull { it.paired }
        }
        val destination = page in DestinationPages
        if (d == null && !destination) return@LaunchedEffect
        // The ring page shows the overlay without the alarm sound.
        if (page == "ring" && d != null) FluxCore.setRinging(d.name)
        // The pair and unpair pages show their dialogs over the Computers destination.
        if (page == "pair") {
            state.devices.firstOrNull { !it.paired && it.online }?.let { outgoing = Outgoing(it.id, 0, "5EE6825F974ED59A") }
        }
        if (page == "unpair" && d != null) unpairing = d.id
        // "ask:<kind>" shows the prompt of a stream request, and "notify:<kind>" shows its notification.
        val ask = page.startsWith(ASK_PAGE)
        if ((ask || page.startsWith(NOTIFY_PAGE)) && d != null) {
            StreamKind.fromKey(page.substringAfter(':'))?.let { StreamRequests.debugShow(activity, d.id, d.name, it, notification = !ask) }
        }
        val (next, pageScope) = Nav.debug(page, d?.id.orEmpty())
        nav = next
        // A destination with @offline or @connecting shows the computer that is not reachable as the scope.
        scope = pageScope ?: if (offline && destination) d?.id else null
        activity.debugPage.value = null
    }

    // A tap on an agent notification opens the screen of the agent. Back goes to the Inbox.
    val openAgent by activity.openAgent.collectAsStateWithLifecycle()
    LaunchedEffect(openAgent, state.devices.size) {
        val (id, pane) = openAgent ?: return@LaunchedEffect
        if (state.devices.none { it.id == id && it.paired }) return@LaunchedEffect
        nav = Nav.agent(id, pane)
        activity.openAgent.value = null
    }

    // A tap on the Start action of a stream request notification opens the page of the stream above the current screen.
    // The key of the notification proves the tap, so the process has the state of the computer already.
    val openStream by activity.openStream.collectAsStateWithLifecycle()
    LaunchedEffect(openStream) {
        val o = openStream ?: return@LaunchedEffect
        activity.openStream.value = null
        // A tap for a computer that is no longer paired does nothing, also after a new pairing.
        if (state.devices.none { it.id == o.deviceId && it.paired }) return@LaunchedEffect
        if (!isDemo(o.deviceId)) StreamRequests.startAfterTap(o.deviceId, o.kind)
        nav = nav.open(Route(o.deviceId, streamPage(o.kind)))
    }
    // The prompt shows the newest open request. After an answer, it shows the next one.
    val streamAsks by StreamRequests.requests.collectAsStateWithLifecycle()

    Box(Modifier.fillMaxSize().background(Tn.bg)) {
        if (!state.enabled) {
            Box(Modifier.fillMaxSize().systemBarsPadding()) { FluxOffScreen() }
        } else {
            FluxShell(
                state, nav, onNav = { nav = it }, scope, onScope = { scope = it },
                onPair = {
                    val ts = System.currentTimeMillis() / 1000
                    outgoing = Outgoing(it.id, ts, FluxCore.previewKey(it.id, ts))
                },
                onUnpair = { unpairing = it.id },
                welcome = welcome,
                // The sheet of an incoming request shows by itself, unless this phone starts another pairing.
                onShowPair = { id ->
                    val o = outgoing
                    if (o != null && o.deviceId != id) FluxCore.toast("Finish or cancel the other pairing first")
                },
                notify = if (anyPaired) notify else NotifyAsk.None,
                onNotify = activity::allowNotifications,
                onNotifyHide = activity::hideNotifyAsk,
            )
        }
        if (out != null && outDevice != null) {
            TiledPairSheet(
                outDevice.name, out.key, waiting = out.sent,
                onCancel = {
                    if (out.sent) FluxCore.cancelPair(out.deviceId)
                    outgoing = null
                },
                onPair = {
                    FluxCore.pair(out.deviceId, out.timestamp)
                    outgoing = out.copy(sent = true)
                },
            )
        } else {
            state.devices.firstOrNull { it.pairState == PairState.Incoming }?.let { d ->
                TiledPairSheet(d.name, d.pairKey, waiting = false, onCancel = { FluxCore.cancelPair(d.id) }, onPair = { FluxCore.acceptPair(d.id) })
            }
        }
        // A stream request waits while a pairing sheet shows.
        val pairShows = (out != null && outDevice != null) || state.devices.any { it.pairState == PairState.Incoming }
        streamAsks.lastOrNull()?.takeIf { state.enabled && !pairShows }?.let { r ->
            // Each request has its own sheet, so that a new request opens a new sheet and waits again before Start takes a tap.
            key(r.deviceId, r.kind) {
                StreamPrompt(r, state.devices.any { it.id == r.deviceId && it.paired }) { nav = nav.open(Route(r.deviceId, streamPage(r.kind))) }
            }
        }
        unpairing?.let { id ->
            val d = state.devices.firstOrNull { it.id == id }
            if (d == null) unpairing = null
            else UnpairDialog(
                d.name,
                onCancel = { unpairing = null },
                onConfirm = {
                    FluxCore.unpair(id)
                    // A new pairing needs a new enrollment. The key file on the computer stays until: sudo flux-cli approve remove
                    ApproveKeys.delete(id)
                    unpairing = null
                },
            )
        }
        if (showIcons) Box(Modifier.fillMaxSize().background(Tn.bg).systemBarsPadding()) { DebugIconsScreen() }
        // The messages show above the navigation bar of a destination. A wide window has a navigation rail at the side.
        val barShown = state.enabled && nav.stack.isEmpty() && !wide
        SnackbarHost(
            snacks,
            Modifier.align(Alignment.BottomCenter).navigationBarsPadding().imePadding().padding(bottom = if (barShown) 88.dp else 16.dp),
        ) { data ->
            val shape = RoundedCornerShape(10.dp)
            T(
                data.visuals.message,
                Modifier.padding(horizontal = 12.dp).fillMaxWidth().clip(shape).background(Tn.tileHi)
                    .border(1.dp, Tn.lineHi, shape).padding(horizontal = 14.dp, vertical = 12.dp),
                size = 13,
            )
        }
        state.ringingFrom?.let { from -> RingOverlay(from) { Ringer.stop(activity) } }
    }
}

/**
 * The prompt of the stream request [r]. A tap on Start opens the page of
 * the stream with [onOpen], and the page starts the stream. A request of a
 * computer that is no longer [paired] ends. The request also ends when the
 * stream of that kind to that computer starts in another way.
 */
@Composable
private fun StreamPrompt(r: StreamRequest, paired: Boolean, onOpen: () -> Unit) {
    val context = LocalContext.current
    val webcam by WebcamSession.status.collectAsStateWithLifecycle()
    val mic by MicSession.status.collectAsStateWithLifecycle()
    val running = remember(r, webcam, mic) { StreamRequests.running(r.deviceId, r.kind) }
    LaunchedEffect(running, paired) {
        if (running || !paired) StreamRequests.dismiss(context, r.deviceId, r.kind)
    }
    if (running || !paired) return
    StreamRequestSheet(
        r,
        onStart = {
            // A request that ended or is too old starts nothing.
            if (StreamRequests.accept(context, r)) {
                if (isDemo(r.deviceId)) FluxCore.toast("This is a sample request") else StreamRequests.startAfterTap(r.deviceId, r.kind)
                onOpen()
            }
        },
        onDismiss = { StreamRequests.dismiss(context, r.deviceId, r.kind) },
    )
}
