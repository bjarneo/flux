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
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
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
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
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
        setContent { FluxTheme { FluxRoot(this) } }
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
    var snack by remember { mutableStateOf<String?>(null) }
    var outgoing by remember { mutableStateOf<Outgoing?>(null) }
    var unpairing by remember { mutableStateOf<String?>(null) }
    val route = stack.last()
    val device = state.devices.firstOrNull { it.id == route.deviceId }

    LaunchedEffect(Unit) {
        FluxCore.toasts.collectLatest {
            snack = it
            delay(2200)
            snack = null
        }
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
        val page = debugPage ?: return@LaunchedEffect
        showIcons = page == "icon"
        if (showIcons) {
            activity.debugPage.value = null
            return@LaunchedEffect
        }
        val d = state.devices.firstOrNull { it.paired && it.online } ?: state.devices.firstOrNull { it.paired } ?: return@LaunchedEffect
        // The ring page shows the overlay without the alarm sound.
        if (page == "ring") FluxCore.setRinging(d.name)
        stack = when (page) {
            "devices", "ring" -> listOf(Route())
            "home" -> listOf(Route(), Route(d.id))
            else -> listOf(Route(), Route(d.id), Route(d.id, page))
        }
        activity.debugPage.value = null
    }

    fun push(r: Route) { stack = stack + r }
    fun pop() { if (stack.size > 1) stack = stack.dropLast(1) }
    BackHandler(enabled = stack.size > 1) { pop() }

    Box(Modifier.fillMaxSize().background(Palette.background)) {
        Box(Modifier.fillMaxSize().systemBarsPadding()) {
            when {
                device == null -> DevicesScreen(
                    state,
                    onOpen = { push(Route(it.id)) },
                    onPair = {
                        val ts = System.currentTimeMillis() / 1000
                        outgoing = Outgoing(it.id, ts, FluxCore.previewKey(it.id, ts))
                    },
                    onUnpair = { unpairing = it.id },
                )
                route.page == "media" -> MediaScreen(device, ::pop)
                route.page == "commands" -> CommandsScreen(device, ::pop)
                route.page == "browse" -> BrowseScreen(device, state.browse, ::pop)
                route.page == "camera" -> org.omarchy.flux.camera.CameraScreen(device, ::pop)
                else -> HomeScreen(device, state, ::pop) { page -> push(Route(device.id, page)) }
            }
        }
        if (out != null && outDevice != null) {
            PairDialog(
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
                PairDialog(d.name, d.pairKey, waiting = false, onCancel = { FluxCore.cancelPair(d.id) }, onPair = { FluxCore.acceptPair(d.id) })
            }
        }
        unpairing?.let { id ->
            val d = state.devices.firstOrNull { it.id == id }
            if (d == null) unpairing = null
            else ConfirmDialog(
                "Unpair ${d.name}?", "The computer can pair again later.", "Unpair",
                onCancel = { unpairing = null },
                onConfirm = {
                    FluxCore.unpair(id)
                    unpairing = null
                },
            )
        }
        if (showIcons) Box(Modifier.fillMaxSize().background(Palette.background).systemBarsPadding()) { DebugIconsScreen() }
        Snack(snack)
        state.ringingFrom?.let { from -> RingOverlay(from) { Ringer.stop(activity) } }
    }
}
