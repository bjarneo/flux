package org.omarchy.flux.ui

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.DrawableRes
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import org.omarchy.flux.core.CaptureKind
import org.omarchy.flux.core.CaptureWatch
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.core.Share
import org.omarchy.flux.core.UiState
import org.omarchy.flux.screen.ScreenMirrorService
import org.omarchy.flux.screen.ScreenSession
import org.omarchy.flux.service.FluxNotificationListener

private fun typeLabel(d: DeviceUi): String = if (d.isFlux) "Omarchy" else d.type.replaceFirstChar { it.uppercase() }

// ───────────────────────── Devices ─────────────────────────

/**
 * The device list. Paired computers and computers that are available to
 * pair share 1 grid. A long press on a paired computer unpairs it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TiledDevicesScreen(
    state: UiState,
    onOpen: (DeviceUi) -> Unit,
    onPair: (DeviceUi) -> Unit,
    onUnpair: (DeviceUi) -> Unit,
) {
    val paired = state.devices.filter { it.paired }
    val available = state.devices.filter { !it.paired && it.online }
    var refreshing by remember { mutableStateOf(false) }
    LaunchedEffect(refreshing) {
        if (refreshing) {
            FluxCore.rediscover()
            delay(1500)
            refreshing = false
        }
    }
    PullToRefreshBox(isRefreshing = refreshing, onRefresh = { refreshing = true }, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter)) {
            Row(
                Modifier.fillMaxWidth().padding(start = 6.dp, end = 2.dp, top = 10.dp, bottom = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FluxMark(24.dp, fg = Tn.text, accent = Tn.blue)
                T("Flux", Modifier.weight(1f).padding(start = 2.dp), size = 22, weight = FontWeight.SemiBold, letterSpacing = -0.4f)
                Row(
                    Modifier.height(32.dp).clip(RoundedCornerShape(8.dp)).background(Tn.tile)
                        .clickable(onClickLabel = "Search again") { refreshing = true }.padding(horizontal = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Sym(Ic.refresh, size = 16.dp, tint = Tn.sub)
                    T(if (refreshing) "Searching…" else "Refresh", size = 12, color = Tn.sub)
                }
                AppMenu()
            }
            Tile(Modifier.fillMaxWidth(), border = activeBorder(), padding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    TileLabel("This phone", Modifier.weight(1f), color = Tn.cyan)
                    Sym(Ic.phone, tint = Tn.cyan, size = 20.dp)
                }
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    T(state.phoneName, size = 26, weight = FontWeight.SemiBold, letterSpacing = -0.5f, maxLines = 1)
                    T(
                        if (state.onWifi) "Visible to computers on this Wi-Fi" else "Not on Wi-Fi. Connect to the network of the computer.",
                        size = 13, color = if (state.onWifi) Tn.sub else Tn.yellow,
                    )
                }
            }

            SectionLabel("Paired computers")
            if (paired.isEmpty()) {
                T("Pair a computer below. Paired computers connect by themselves.", Modifier.padding(horizontal = 4.dp), size = 13, color = Tn.sub)
            }
            // Paired computers and available ones share the 2-column grid.
            val cells: List<@Composable (Modifier) -> Unit> =
                paired.map { d -> @Composable { m: Modifier -> PairedTile(d, m, onOpen = { onOpen(d) }, onUnpair = { onUnpair(d) }) } } +
                    available.map { d -> @Composable { m: Modifier -> AvailableTile(d, m) { onPair(d) } } }
            Column(Modifier.padding(top = if (paired.isEmpty()) 12.dp else 0.dp), verticalArrangement = Arrangement.spacedBy(TileGap)) {
                for (row in cells.chunked(2)) {
                    TileRow(112.dp) {
                        for (cell in row) cell(Modifier.weight(1f).fillMaxHeight())
                        if (row.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
            if (available.isEmpty()) {
                Tile(
                    Modifier.fillMaxWidth().padding(top = TileGap), onClick = { refreshing = true },
                    accent = Tn.yellow, container = Color.Transparent,
                    padding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = Tn.yellow)
                        TileLabel("Looking for computers", color = Tn.yellow)
                    }
                    T("Open Flux on the computer, and use the same Wi-Fi network as this phone.", size = 13, color = Tn.sub)
                }
            }
            Spacer(Modifier.height(96.dp))
        }
    }
}

/** The menu of the device list. */
@Composable
private fun AppMenu() {
    var open by remember { mutableStateOf(false) }
    Box {
        SquareButton(Ic.more, "More options", { open = true }, size = 32.dp)
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text("Turn off Flux") },
                leadingIcon = { Sym(Ic.power) },
                onClick = {
                    open = false
                    FluxCore.setEnabled(false)
                },
            )
        }
    }
}

@Composable
private fun PairedTile(d: DeviceUi, modifier: Modifier, onOpen: () -> Unit, onUnpair: () -> Unit) {
    val status = when {
        !d.online -> "Not reachable"
        d.battery != null -> "${d.battery}%" + if (d.charging) " · charging" else ""
        else -> "Connected"
    }
    Tile(
        modifier, onClick = onOpen, onLongClick = onUnpair,
        border = BorderStroke(1.dp, if (d.online) Tn.line else Tn.tile), enabled = d.online,
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Sym(deviceIcon(d.type), tint = if (d.online) Tn.blue else Tn.dim, size = 22.dp)
            Spacer(Modifier.weight(1f))
            Dot(if (d.online) Tn.green else Tn.dim)
        }
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            T(d.name, size = 15, weight = FontWeight.SemiBold, maxLines = 1)
            T(status, size = 12, color = Tn.sub, maxLines = 1)
        }
    }
}

@Composable
private fun AvailableTile(d: DeviceUi, modifier: Modifier, onPair: () -> Unit) {
    Tile(modifier.dashedBorder(Tn.yellow), onClick = onPair, accent = Tn.yellow, container = Color.Transparent, border = null) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Sym(Ic.add, tint = Tn.yellow, size = 22.dp)
            Spacer(Modifier.weight(1f))
            T("AVAILABLE", size = 10, color = Tn.yellow, weight = FontWeight.Medium, family = Mono, letterSpacing = 0.8f)
        }
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            T(d.name, size = 15, weight = FontWeight.SemiBold, maxLines = 1)
            T("Tap to pair", size = 12, color = Tn.yellow)
        }
    }
}

// ───────────────────────── Pairing ─────────────────────────

/** The pairing sheet: the verification key, 1 box per character. Back and a tap on the scrim cancel. */
@Composable
fun TiledPairSheet(name: String, key: String, waiting: Boolean, onCancel: () -> Unit, onPair: () -> Unit) {
    BackHandler(onBack = onCancel)
    Box(
        Modifier.fillMaxSize().background(Color(0x990A0A0F))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onCancel),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                .background(Tn.tile)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { },
        ) {
            Box(Modifier.fillMaxWidth().height(2.dp).background(Tn.yellow))
            Column(
                Modifier.navigationBarsPadding().padding(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    TileLabel("Pair", color = Tn.yellow)
                    T(name, size = 22, weight = FontWeight.SemiBold, letterSpacing = -0.4f, maxLines = 1)
                    T(if (waiting) "Confirm the same code on $name." else "Check that $name shows the same code.", size = 13, color = Tn.sub)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    for (c in key.padEnd(8, '…')) {
                        Box(
                            Modifier.weight(1f).height(44.dp).clip(RoundedCornerShape(6.dp)).background(Tn.bg)
                                .border(1.dp, Tn.lineHi, RoundedCornerShape(6.dp)),
                            contentAlignment = Alignment.Center,
                        ) { T(c.toString(), size = 20, color = Tn.yellow, weight = FontWeight.Medium, family = Mono) }
                    }
                }
                Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                    Box(
                        Modifier.weight(1f).height(48.dp).clip(RoundedCornerShape(10.dp)).background(Tn.line).clickable(onClick = onCancel),
                        contentAlignment = Alignment.Center,
                    ) { T("Cancel", size = 14, weight = FontWeight.SemiBold) }
                    Box(
                        Modifier.weight(2f).height(48.dp).clip(RoundedCornerShape(10.dp)).background(Tn.yellow)
                            .clickable(enabled = !waiting, onClick = onPair),
                        contentAlignment = Alignment.Center,
                    ) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            if (waiting) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Tn.bg)
                            T(if (waiting) "Waiting" else "Pair", size = 14, color = Tn.bg, weight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        }
    }
}

// ───────────────────────── Device home ─────────────────────────

private data class SyncItem(@DrawableRes val icon: Int, val title: String, val on: Boolean, val onClick: () -> Unit)

/**
 * The device home: a tiled grid of the actions, then the sync settings.
 * The grid has 6 columns and rows of [TileUnit].
 */
@Composable
fun TiledHomeScreen(
    d: DeviceUi,
    state: UiState,
    onBack: () -> Unit,
    onUnpair: () -> Unit,
    onNavigate: (String) -> Unit,
) {
    val context = LocalContext.current
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) Share.sendFiles(FluxCore, d.id, uris)
    }
    // Call alerts need the phone state. The call log and the contacts add
    // the number and the name, and the user can refuse them.
    val askPhone = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted[Manifest.permission.READ_PHONE_STATE] == true) {
            FluxCore.setCallAlerts(true)
        } else {
            FluxCore.toast("Call alerts need phone access. Allow it in the app settings.")
        }
    }
    // The first capture switch that turns on asks for access to photos.
    var asking by remember { mutableStateOf<CaptureKind?>(null) }
    val askPhotos = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val kind = asking ?: return@rememberLauncherForActivityResult
        asking = null
        when {
            CaptureWatch.hasAccess(context) -> FluxCore.setSendCaptures(kind, true)
            // Access to selected photos only does not show new images.
            else -> FluxCore.toast("Allow access to all photos, so that Flux sees new images")
        }
    }
    // The screen mirror asks Android for the capture, then the service runs it.
    val screen by ScreenSession.status.collectAsState()
    val mirroring = screen.active && screen.deviceId == d.id
    val askCapture = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        val data = r.data
        if (r.resultCode == Activity.RESULT_OK && data != null) ScreenMirrorService.start(context, d.id, r.resultCode, data)
    }
    LaunchedEffect(screen) {
        if (screen.phase == ScreenSession.Phase.Error && screen.deviceId == d.id) FluxCore.toast(screen.message)
    }
    fun guarded(action: () -> Unit): () -> Unit = { if (d.online) action() else FluxCore.toast("${d.name} is not reachable") }
    val on = d.online

    fun captureToggle(kind: CaptureKind, current: Boolean) {
        when {
            current && state.mediaAccess -> FluxCore.setSendCaptures(kind, false)
            state.mediaAccess -> FluxCore.setSendCaptures(kind, true)
            else -> {
                asking = kind
                askPhotos.launch(CaptureWatch.permissions())
            }
        }
    }
    val sync = listOf(
        SyncItem(Ic.notifications, "Share notifications", state.shareNotifications && state.notificationAccess) {
            if (!state.notificationAccess) {
                FluxCore.setShareNotifications(true)
                val intent = if (Build.VERSION.SDK_INT >= 30) {
                    Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                        .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, ComponentName(context, FluxNotificationListener::class.java).flattenToString())
                } else {
                    Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
                }
                runCatching { context.startActivity(intent) }
                    .onFailure { runCatching { context.startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")) } }
            } else {
                FluxCore.setShareNotifications(!state.shareNotifications)
            }
        },
        SyncItem(Ic.paste, "Sync clipboard", state.syncClipboard) { FluxCore.setSyncClipboard(!state.syncClipboard) },
        SyncItem(Ic.call, "Call alerts", state.callAlerts && state.callAccess) {
            if (!state.callAccess) {
                askPhone.launch(arrayOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_CONTACTS))
            } else {
                FluxCore.setCallAlerts(!state.callAlerts)
            }
        },
        SyncItem(Ic.dnd, "Sync Do Not Disturb", state.syncDnd && state.dndAccess) {
            if (!state.dndAccess) {
                FluxCore.setSyncDnd(true)
                runCatching { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)) }
            } else {
                FluxCore.setSyncDnd(!state.syncDnd)
            }
        },
        SyncItem(Ic.screenshot, "Send new screenshots", state.sendScreenshots && state.mediaAccess) { captureToggle(CaptureKind.Screenshot, state.sendScreenshots) },
        SyncItem(Ic.gallery, "Send new photos", state.sendPhotos && state.mediaAccess) { captureToggle(CaptureKind.Photo, state.sendPhotos) },
    )

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter)) {
        TiledTopBar("${typeLabel(d)} · ${d.ip}", onBack) { DeviceMenu(d.name, onUnpair) }
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            StatusTile(d)
            TileRow(TileUnit2) {
                Tile(Modifier.weight(1f).fillMaxHeight(), guarded { Plugins.sendClipboard(FluxCore, d.id) }, enabled = on) {
                    Sym(Ic.pasteGo, tint = Tn.blue, size = 26.dp)
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        T("Send clipboard", size = 15, weight = FontWeight.SemiBold, maxLines = 1)
                        T("Paste it on the computer", size = 11, color = Tn.sub, maxLines = 1)
                    }
                }
                Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(TileGap)) {
                    LineTile(Ic.sendFiles, "Send files", Tn.magenta, guarded { pickFiles.launch(arrayOf("*/*")) }, Modifier.weight(1f).fillMaxWidth(), on)
                    LineTile(Ic.camera, "Camera", Tn.cyan, guarded { onNavigate("camera") }, Modifier.weight(1f).fillMaxWidth(), on)
                }
            }
            TileRow(TileUnit2) {
                MediaTile(d, Modifier.weight(4f).fillMaxHeight(), onOpen = guarded { onNavigate("media") })
                Tile(Modifier.weight(2f).fillMaxHeight(), guarded { Plugins.ring(FluxCore, d.id) }, accent = Tn.red, enabled = on, padding = PaddingValues(12.dp)) {
                    Sym(Ic.ring, tint = Tn.red, size = 24.dp)
                    T("Ring PC", size = 13, weight = FontWeight.SemiBold, maxLines = 1)
                }
            }
            TileRow(TileUnit) {
                MiniTile(Ic.mic, "Mic", Tn.orange, guarded { onNavigate("mic") }, Modifier.weight(1f).fillMaxHeight(), on)
                if (mirroring) {
                    MiniTile(Ic.stopScreenShare, "Stop", Tn.cyan, { ScreenSession.stop() }, Modifier.weight(1f).fillMaxHeight(), container = Tn.tileHi)
                } else {
                    MiniTile(Ic.screenShare, "Mirror", Tn.cyan, guarded {
                        askCapture.launch(context.getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent())
                    }, Modifier.weight(1f).fillMaxHeight(), on)
                }
                MiniTile(Ic.terminal, "Commands", Tn.yellow, guarded { onNavigate("commands") }, Modifier.weight(1f).fillMaxHeight(), on)
            }
            LineTile(Ic.folderOpen, "Browse PC", Tn.magenta, guarded { onNavigate("browse") }, Modifier.fillMaxWidth().height(TileUnit), on, trailing = "~/ read-only")
        }

        SectionLabel("Sync")
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            for (row in sync.chunked(2)) {
                TileRow(84.dp) { for (s in row) SyncTile(s, Modifier.weight(1f).fillMaxHeight()) }
            }
        }
        Spacer(Modifier.height(96.dp))
    }
}

/** The connection and the battery of the computer. A computer that is not reachable gets help and a retry. */
@Composable
private fun StatusTile(d: DeviceUi) {
    Tile(
        Modifier.fillMaxWidth().height(TileUnit2),
        border = if (d.online) activeBorder() else BorderStroke(1.dp, Tn.line),
        padding = PaddingValues(16.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Dot(if (d.online) Tn.green else Tn.dim, 7.dp)
                TileLabel(if (d.online) "Connected" else "Not reachable", color = if (d.online) Tn.green else Tn.dim)
            }
            if (d.online) {
                d.battery?.let { T("$it%" + if (d.charging) ", charging" else "", size = 12, color = Tn.sub, family = Mono) }
            } else {
                T(
                    "Retry",
                    Modifier.clip(RoundedCornerShape(6.dp)).clickable { FluxCore.rediscover() }.padding(horizontal = 8.dp, vertical = 4.dp),
                    size = 13, color = Tn.blue, weight = FontWeight.SemiBold,
                )
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            T(d.name, size = 28, weight = FontWeight.SemiBold, letterSpacing = -0.5f, maxLines = 1)
            val battery = d.battery
            if (d.online && battery != null) {
                Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).background(Tn.line)) {
                    Box(Modifier.fillMaxWidth(battery.coerceIn(0, 100) / 100f).fillMaxHeight().background(Tn.green))
                }
            } else if (!d.online) {
                T("Check that Flux runs on ${d.name}, and that both are on the same Wi-Fi.", size = 12, color = Tn.sub, maxLines = 2)
            }
        }
    }
}

@Composable
private fun MediaTile(d: DeviceUi, modifier: Modifier, onOpen: () -> Unit) {
    val p = d.player
    val playing = p?.playing == true
    Tile(modifier, onOpen, accent = Tn.green, enabled = d.online, border = BorderStroke(1.dp, if (playing) Tn.green else Tn.line)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Sym(Ic.music, tint = Tn.green, size = 22.dp)
            Spacer(Modifier.weight(1f))
            if (p != null) T(p.name, size = 10, color = Tn.dim, family = Mono, maxLines = 1)
        }
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(p?.title?.ifEmpty { "Unknown title" } ?: "Media", size = 14, weight = FontWeight.SemiBold, maxLines = 1)
                T(p?.artist?.ifEmpty { null } ?: if (p == null) "Control what plays" else "", size = 11, color = Tn.sub, maxLines = 1)
            }
            if (p != null && d.online) {
                Box(
                    Modifier.size(34.dp).clip(CircleShape).background(Tn.green)
                        .clickable { Plugins.mediaAction(FluxCore, d.id, "PlayPause") },
                    contentAlignment = Alignment.Center,
                ) { Sym(if (playing) Ic.pause else Ic.play, if (playing) "Pause" else "Play", tint = Tn.bg, size = 22.dp) }
            }
        }
    }
}

@Composable
private fun SyncTile(s: SyncItem, modifier: Modifier) {
    val fg = if (s.on) Tn.blue else Tn.dim
    Tile(
        modifier, s.onClick,
        container = if (s.on) Tn.tileHi else Tn.offTile,
        border = BorderStroke(1.dp, if (s.on) Tn.blue else Tn.line),
        padding = PaddingValues(12.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Sym(s.icon, tint = fg, size = 20.dp)
            Spacer(Modifier.weight(1f))
            T(if (s.on) "ON" else "OFF", size = 10, color = fg, weight = FontWeight.Medium, family = Mono)
        }
        T(s.title, size = 12, weight = FontWeight.SemiBold, lineHeight = 1.25f, maxLines = 2)
    }
}

// ───────────────────────── Media ─────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TiledMediaScreen(d: DeviceUi, onBack: () -> Unit) {
    val p = d.player
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    // The position that the user drags to, until the drag ends.
    var dragging by remember { mutableStateOf<Float?>(null) }
    LaunchedEffect(d.id) {
        while (true) {
            Plugins.requestPlayers(FluxCore, d.id)
            delay(10_000)
        }
    }
    LaunchedEffect(p?.playing) {
        while (p?.playing == true) {
            now = SystemClock.elapsedRealtime()
            delay(500)
        }
    }
    val position = when {
        p == null -> 0L
        p.playing -> (p.position + (now - p.updatedAt)).coerceIn(0, maxOf(p.length, 0))
        else -> p.position
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter)) {
        TiledTopBar("media · ${d.name}", onBack)
        if (!d.online) {
            NotReachable(d, "The player controls")
            return@Column
        }
        if (p == null) {
            EmptyState(Ic.music, "Nothing is playing", "Play music or a video on ${d.name}. The controls show here.", Modifier.padding(top = 48.dp))
            return@Column
        }
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            if (d.players.size > 1) {
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (name in d.players) {
                        val sel = name == p.name
                        T(
                            name,
                            Modifier.clip(RoundedCornerShape(8.dp)).background(if (sel) Tn.green else Tn.tile)
                                .clickable { Plugins.selectPlayer(FluxCore, d.id, name) }.padding(horizontal = 10.dp, vertical = 6.dp),
                            size = 12, color = if (sel) Tn.bg else Tn.sub, family = Mono, weight = FontWeight.Medium,
                        )
                    }
                }
            }
            Tile(
                Modifier.fillMaxWidth().aspectRatio(1f), border = activeBorder(Tn.green, Tn.cyan),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
            ) {
                Sym(Ic.music, tint = Tn.green, size = 96.dp)
            }
            Tile(Modifier.fillMaxWidth(), border = null, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                T(p.title.ifEmpty { "Unknown title" }, size = 22, weight = FontWeight.SemiBold, letterSpacing = -0.4f, maxLines = 2)
                T(listOf(p.artist, p.name).filter { it.isNotEmpty() }.joinToString(" · "), size = 13, color = Tn.sub, maxLines = 1)
                if (p.length > 0) {
                    // A thin track like the battery bar, with a small thumb while the player can seek.
                    val colors = SliderDefaults.colors(
                        thumbColor = Tn.green, activeTrackColor = Tn.green, inactiveTrackColor = Tn.line,
                        disabledThumbColor = Tn.green, disabledActiveTrackColor = Tn.green, disabledInactiveTrackColor = Tn.line,
                    )
                    val source = remember { MutableInteractionSource() }
                    Slider(
                        value = dragging ?: position.toFloat(),
                        onValueChange = { dragging = it },
                        onValueChangeFinished = {
                            dragging?.let { Plugins.seek(FluxCore, d.id, it.toLong()) }
                            dragging = null
                        },
                        valueRange = 0f..p.length.toFloat(),
                        enabled = p.canSeek,
                        colors = colors,
                        interactionSource = source,
                        thumb = {
                            if (p.canSeek) SliderDefaults.Thumb(source, colors = colors, thumbSize = DpSize(4.dp, 18.dp))
                        },
                        track = {
                            SliderDefaults.Track(
                                it, Modifier.height(4.dp), enabled = p.canSeek, colors = colors,
                                drawStopIndicator = null, thumbTrackGapSize = if (p.canSeek) 4.dp else 0.dp,
                            )
                        },
                    )
                    Row(Modifier.fillMaxWidth()) {
                        T(clock(dragging?.toLong() ?: position), Modifier.weight(1f), size = 11, color = Tn.dim, family = Mono)
                        T(clock(p.length), size = 11, color = Tn.dim, family = Mono)
                    }
                }
            }
            TileRow(64.dp) {
                ControlTile(Ic.previous, "Previous", Modifier.weight(1f)) { Plugins.mediaAction(FluxCore, d.id, "Previous") }
                Tile(
                    Modifier.weight(1f).fillMaxHeight(), { Plugins.mediaAction(FluxCore, d.id, "PlayPause") },
                    container = Tn.green, border = null, padding = PaddingValues(0.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                ) {
                    Sym(if (p.playing) Ic.pause else Ic.play, if (p.playing) "Pause" else "Play", tint = Tn.bg, size = 34.dp)
                }
                ControlTile(Ic.next, "Next", Modifier.weight(1f)) { Plugins.mediaAction(FluxCore, d.id, "Next") }
            }
        }
        Spacer(Modifier.height(48.dp))
    }
}

@Composable
private fun ControlTile(@DrawableRes icon: Int, description: String, modifier: Modifier, onClick: () -> Unit) {
    Tile(
        modifier.fillMaxHeight(), onClick, accent = Tn.green, padding = PaddingValues(0.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
    ) {
        Sym(icon, description, size = 28.dp)
    }
}

// ───────────────────────── Commands ─────────────────────────

@Composable
fun TiledCommandsScreen(d: DeviceUi, onBack: () -> Unit) {
    LaunchedEffect(d.id) { Plugins.requestCommands(FluxCore, d.id) }
    // The command that ran last shows a check for a moment.
    var ran by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(ran) {
        if (ran != null) {
            delay(1600)
            ran = null
        }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter)) {
        TiledTopBar("commands · ${d.name}", onBack)
        when {
            !d.online -> NotReachable(d, "The commands")
            !d.commandsLoaded -> Row(Modifier.padding(4.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Tn.yellow)
                T("Loading the commands of ${d.name}", color = Tn.sub)
            }
            d.commands.isEmpty() -> EmptyState(
                Ic.terminal,
                "No commands yet",
                "On ${d.name}, open Flux and add commands in Phone commands. They show here.",
                Modifier.padding(top = 48.dp),
            )
        }
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            for (row in d.commands.chunked(2)) {
                TileRow(112.dp) {
                    for (c in row) {
                        val done = ran == c.key
                        Tile(
                            Modifier.weight(1f).fillMaxHeight(),
                            onClick = {
                                Plugins.runCommand(FluxCore, d.id, c)
                                ran = c.key
                            },
                            accent = Tn.yellow,
                            container = if (done) Tn.tileHi else Tn.tile,
                            border = BorderStroke(1.dp, if (done) Tn.green else Tn.line),
                        ) {
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                Sym(Ic.terminal, tint = Tn.yellow, size = 22.dp)
                                Spacer(Modifier.weight(1f))
                                Sym(if (done) Ic.checkCircle else Ic.play, if (done) "Done" else "Run", tint = if (done) Tn.green else Tn.dim, size = 18.dp)
                            }
                            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                T(c.name, size = 14, weight = FontWeight.SemiBold, maxLines = 1)
                                T(c.command, size = 10, color = Tn.dim, family = Mono, maxLines = 1)
                            }
                        }
                    }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
        Spacer(Modifier.height(96.dp))
    }
}
