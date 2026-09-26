package org.omarchy.flux.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.flow.collectLatest
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.PairState
import org.omarchy.flux.core.Ringer
import org.omarchy.flux.core.UiState
import org.omarchy.flux.service.FluxService

class MainActivity : ComponentActivity() {
    /** Debug builds only: the page that the `flux.debug.page` extra asks for. */
    val debugPage = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)

    private val askNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        // The theme is always dark, so the system bars use light icons.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        FluxCore.init(this)
        FluxService.start(this)
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        debugShowWhenLocked(intent)
        setContent { TiledTheme { FluxRoot(this) } }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        debugShowWhenLocked(intent)
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
            FluxCore.publish()
        }
        intent?.getStringExtra("flux.debug.page")?.let { debugPage.value = it }
        if (intent?.getBooleanExtra("flux.debug.showWhenLocked", false) != true) return
        setShowWhenLocked(true)
        setTurnScreenOn(true)
    }

    override fun onResume() {
        super.onResume()
        FluxService.start(this, FluxService.ACTION_REFRESH)
    }
}

/** One entry of the screen stack. [page] is empty for the device home screen. */
private data class Route(val deviceId: String? = null, val page: String = "")

/** A pairing that this phone starts. The dialog shows the key before the request goes out. */
private data class Outgoing(val deviceId: String, val timestamp: Long, val key: String, val sent: Boolean = false)

@Composable
fun FluxRoot(activity: MainActivity) {
    val state by FluxCore.state.collectAsStateWithLifecycle()
    var stack by remember { mutableStateOf(listOf(Route())) }
    val snacks = remember { SnackbarHostState() }
    var outgoing by remember { mutableStateOf<Outgoing?>(null) }
    var unpairing by remember { mutableStateOf<String?>(null) }
    val route = stack.last()
    val device = state.devices.firstOrNull { it.id == route.deviceId }

    // A new message replaces the one on screen.
    LaunchedEffect(Unit) {
        FluxCore.toasts.collectLatest { snacks.showSnackbar(it) }
    }
    // Leave the device screens when the device is gone or no longer paired.
    LaunchedEffect(route, device?.paired) {
        if (route.deviceId != null && (device == null || !device.paired)) stack = listOf(Route())
    }
    // Close the outgoing dialog when the pairing ends.
    val out = outgoing
    val outDevice = state.devices.firstOrNull { it.id == out?.deviceId }
    LaunchedEffect(out, outDevice?.pairState) {
        if (out == null) return@LaunchedEffect
        if (outDevice == null || outDevice.paired || (out.sent && outDevice.pairState == PairState.None)) outgoing = null
    }

    // Debug builds only: open a page of the first paired device from adb.
    val debugPage by activity.debugPage.collectAsStateWithLifecycle()
    var showIcons by remember { mutableStateOf(false) }
    LaunchedEffect(debugPage, state.devices.size) {
        val request = debugPage ?: return@LaunchedEffect
        showIcons = request == "icon"
        // Each page starts from a clean screen.
        FluxCore.setRinging(null)
        outgoing = null
        unpairing = null
        if (showIcons) {
            activity.debugPage.value = null
            return@LaunchedEffect
        }
        if (request == "empty") {
            org.omarchy.flux.core.DebugDemo.on = false
            FluxCore.publish()
            stack = listOf(Route())
            activity.debugPage.value = null
            return@LaunchedEffect
        }
        // "<page>@offline" opens the page of a paired computer that is not reachable.
        val page = request.substringBefore('@')
        val offline = request.endsWith("@offline")
        val d = if (offline) {
            state.devices.firstOrNull { it.paired && !it.online }
        } else {
            state.devices.firstOrNull { it.paired && it.online } ?: state.devices.firstOrNull { it.paired }
        } ?: return@LaunchedEffect
        // The ring page shows the overlay without the alarm sound.
        if (page == "ring") FluxCore.setRinging(d.name)
        // The pair and unpair pages show their dialogs over the device list.
        if (page == "pair") {
            state.devices.firstOrNull { !it.paired && it.online }?.let { outgoing = Outgoing(it.id, 0, "4F21A9C3") }
        }
        if (page == "unpair") unpairing = d.id
        stack = when (page) {
            "devices", "ring", "pair", "unpair" -> listOf(Route())
            "home" -> listOf(Route(), Route(d.id))
            else -> listOf(Route(), Route(d.id), Route(d.id, page))
        }
        activity.debugPage.value = null
    }

    fun push(r: Route) { stack = stack + r }
    fun pop() { if (stack.size > 1) stack = stack.dropLast(1) }
    BackHandler(enabled = stack.size > 1) { pop() }

    Box(Modifier.fillMaxSize().background(Tn.bg)) {
        Box(Modifier.fillMaxSize().systemBarsPadding()) {
            when {
                !state.enabled -> FluxOffScreen()
                device == null -> TiledDevicesScreen(
                    state,
                    onOpen = { push(Route(it.id)) },
                    onPair = {
                        val ts = System.currentTimeMillis() / 1000
                        outgoing = Outgoing(it.id, ts, FluxCore.previewKey(it.id, ts))
                    },
                    onUnpair = { unpairing = it.id },
                )
                route.page == "media" -> TiledMediaScreen(device, ::pop)
                route.page == "mic" -> org.omarchy.flux.mic.MicScreen(device, ::pop)
                route.page == "commands" -> TiledCommandsScreen(device, ::pop)
                route.page == "browse" -> BrowseScreen(device, state.browse, ::pop)
                // Debug builds open a mode with "camera:<mode>".
                route.page.startsWith("camera") -> key(route.page) {
                    org.omarchy.flux.camera.CameraScreen(device, ::pop, org.omarchy.flux.camera.CameraMode.fromKey(route.page.substringAfter(':', "")))
                }
                else -> TiledHomeScreen(device, state, ::pop, onUnpair = { unpairing = device.id }) { page -> push(Route(device.id, page)) }
            }
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
        unpairing?.let { id ->
            val d = state.devices.firstOrNull { it.id == id }
            if (d == null) unpairing = null
            else ConfirmDialog(
                "Unpair ${d.name}?",
                "This phone and ${d.name} stop connecting. You can pair them again later.",
                "Unpair",
                onCancel = { unpairing = null },
                onConfirm = {
                    FluxCore.unpair(id)
                    unpairing = null
                },
                icon = Ic.unlink,
                destructive = true,
            )
        }
        if (showIcons) Box(Modifier.fillMaxSize().background(Tn.bg).systemBarsPadding()) { DebugIconsScreen() }
        SnackbarHost(snacks, Modifier.align(Alignment.BottomCenter).systemBarsPadding().padding(bottom = 16.dp)) { data ->
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
