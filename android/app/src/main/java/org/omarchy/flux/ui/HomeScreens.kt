package org.omarchy.flux.ui

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.DrawableRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
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

private fun typeLabel(d: DeviceUi): String = when {
    d.isFlux -> "Omarchy"
    else -> d.type.replaceFirstChar { it.uppercase() }
}

/** The status line of a paired device: the connection and the battery. */
private fun statusLine(d: DeviceUi): String = when {
    !d.online -> "Not reachable"
    d.battery != null -> "Connected · battery ${d.battery}%" + if (d.charging) ", charging" else ""
    else -> "Connected"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(
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
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Row(
                Modifier.fillMaxWidth().padding(start = Gutter + 4.dp, end = 8.dp, top = 16.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                FluxMark(28.dp)
                Text("Flux", Modifier.weight(1f), style = MaterialTheme.typography.headlineMedium)
                IconButton(onClick = { refreshing = true }) { Sym(Ic.refresh, "Search again") }
            }
            ThisPhoneCard(state)

            SectionHeader("Paired computers", top = 20.dp)
            if (paired.isEmpty()) {
                Text(
                    "Pair a computer below. Paired computers connect by themselves.",
                    Modifier.padding(horizontal = Gutter, vertical = 8.dp),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            for (d in paired) PairedRow(d, onOpen = { onOpen(d) }, onUnpair = { onUnpair(d) })

            SectionHeader("Available", top = 20.dp) {
                if (available.isEmpty()) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            }
            if (available.isEmpty()) {
                EmptyState(
                    Ic.wifiFind,
                    "Looking for computers",
                    "Open Flux on the computer, and use the same Wi-Fi network as this phone.",
                    action = { TextButton(onClick = { refreshing = true }) { Text("Search again") } },
                )
            }
            for (d in available) {
                ListItem(
                    headlineContent = { Text(d.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    supportingContent = { Text("${typeLabel(d)} · ${d.ip}") },
                    leadingContent = { IconBadge(deviceIcon(d.type)) },
                    trailingContent = { FilledTonalButton(onClick = { onPair(d) }) { Text("Pair") } },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                )
            }
            Spacer(Modifier.height(96.dp))
        }
    }
}

@Composable
private fun ThisPhoneCard(state: UiState) {
    val scheme = MaterialTheme.colorScheme
    Card(
        Modifier.padding(horizontal = Gutter).fillMaxWidth(),
        shape = RoundedCornerShape(28.dp),
        colors = CardDefaults.cardColors(containerColor = scheme.primaryContainer, contentColor = scheme.onPrimaryContainer),
    ) {
        Row(Modifier.padding(20.dp), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
            IconBadge(Ic.phone, container = scheme.primary, content = scheme.onPrimary, size = 48.dp)
            Column(Modifier.weight(1f)) {
                Text("This phone", style = MaterialTheme.typography.labelMedium)
                Text(state.phoneName, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Sym(if (state.onWifi) Ic.wifi else Ic.wifiOff, size = 16.dp)
                    Text(
                        if (state.onWifi) "Visible to computers on this Wi-Fi" else "Not on Wi-Fi. Connect to the network of the computer.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }
    }
}

@Composable
private fun PairedRow(d: DeviceUi, onOpen: () -> Unit, onUnpair: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    ListItem(
        headlineContent = { Text(d.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text(statusLine(d), color = if (d.online) scheme.onSurfaceVariant else scheme.outline) },
        leadingContent = {
            IconBadge(
                deviceIcon(d.type),
                container = if (d.online) scheme.primaryContainer else scheme.surfaceContainerHighest,
                content = if (d.online) scheme.onPrimaryContainer else scheme.onSurfaceVariant,
            )
        },
        trailingContent = { DeviceMenu(d.name, onUnpair) },
        modifier = Modifier.clickable(onClick = onOpen),
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    )
}

/** The overflow menu of a paired device. */
@Composable
fun DeviceMenu(name: String, onUnpair: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) { Sym(Ic.more, "More options for $name") }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text("Unpair") },
                leadingIcon = { Sym(Ic.unlink) },
                onClick = {
                    open = false
                    onUnpair()
                },
            )
        }
    }
}

private data class Action(@DrawableRes val icon: Int, val label: String, val supporting: String, val run: () -> Unit)

@Composable
fun HomeScreen(
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
    fun guarded(action: () -> Unit): () -> Unit = { if (d.online) action() else FluxCore.toast("${d.name} is not reachable") }
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
    val actions = listOf(
        Action(Ic.pasteGo, "Send clipboard", "Paste it on the computer", guarded { Plugins.sendClipboard(FluxCore, d.id) }),
        Action(Ic.sendFiles, "Send files", "To the Downloads folder", guarded { pickFiles.launch(arrayOf("*/*")) }),
        Action(Ic.camera, "Camera", "Scan, photo, or webcam", guarded { onNavigate("camera") }),
        Action(Ic.mic, "Microphone", "Use as a mic on the PC", guarded { onNavigate("mic") }),
        if (mirroring) {
            Action(Ic.stopScreenShare, "Stop mirror", "This screen shows on the PC", { ScreenSession.stop() })
        } else {
            Action(Ic.screenShare, "Mirror screen", "Show this screen on the PC", guarded {
                askCapture.launch(context.getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent())
            })
        },
        Action(Ic.music, "Media", "Control what plays", guarded { onNavigate("media") }),
        Action(Ic.terminal, "Run commands", "Commands you added", guarded { onNavigate("commands") }),
        Action(Ic.folderOpen, "Browse PC", "Open and get files", guarded { onNavigate("browse") }),
        Action(Ic.ring, "Ring PC", "Play a sound to find it", guarded { Plugins.ring(FluxCore, d.id) }),
    )
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        TopBar(d.name, onBack, subtitle = "${typeLabel(d)} · ${d.ip}") { DeviceMenu(d.name, onUnpair) }
        StatusCard(d)
        Column(Modifier.padding(horizontal = Gutter, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            for (row in actions.chunked(2)) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    for (a in row) {
                        ActionTile(a.icon, a.label, a.supporting, enabled = d.online, onClick = a.run, modifier = Modifier.weight(1f), wide = row.size == 1)
                    }
                }
            }
        }
        SectionHeader("Sync", top = 8.dp)
        SwitchRow(
            Ic.notifications,
            "Share notifications",
            if (state.notificationAccess) "Show phone notifications on the computer" else "Tap to allow notification access",
            checked = state.shareNotifications && state.notificationAccess,
        ) {
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
        }
        SwitchRow(Ic.paste, "Sync clipboard", "Copy on one device, paste on the other", checked = state.syncClipboard) {
            FluxCore.setSyncClipboard(!state.syncClipboard)
        }
        SwitchRow(
            Ic.call,
            "Call alerts",
            if (state.callAccess) "Show calls on the computer and pause its media" else "Tap to allow phone access",
            checked = state.callAlerts && state.callAccess,
        ) {
            if (!state.callAccess) {
                askPhone.launch(arrayOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_CONTACTS))
            } else {
                FluxCore.setCallAlerts(!state.callAlerts)
            }
        }
        SwitchRow(
            Ic.dnd,
            "Sync Do Not Disturb",
            if (state.dndAccess) "Turn it on or off on 1 device, and the other follows" else "Tap to allow Do Not Disturb access",
            checked = state.syncDnd && state.dndAccess,
        ) {
            if (!state.dndAccess) {
                FluxCore.setSyncDnd(true)
                runCatching { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)) }
            } else {
                FluxCore.setSyncDnd(!state.syncDnd)
            }
        }
        CaptureSwitches(state)
        Spacer(Modifier.height(96.dp))
    }
}

/**
 * The switches that send new screenshots and camera photos. The first
 * switch that turns on asks for access to photos.
 */
@Composable
private fun CaptureSwitches(state: UiState) {
    val context = LocalContext.current
    var asking by remember { mutableStateOf<CaptureKind?>(null) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val kind = asking ?: return@rememberLauncherForActivityResult
        asking = null
        when {
            CaptureWatch.hasAccess(context) -> FluxCore.setSendCaptures(kind, true)
            // Access to selected photos only does not show new images.
            else -> FluxCore.toast("Allow access to all photos, so that Flux sees new images")
        }
    }
    fun toggle(kind: CaptureKind, on: Boolean) {
        when {
            on && state.mediaAccess -> FluxCore.setSendCaptures(kind, false)
            state.mediaAccess -> FluxCore.setSendCaptures(kind, true)
            else -> {
                asking = kind
                ask.launch(CaptureWatch.permissions())
            }
        }
    }
    val noAccess = "Tap to allow access to photos"
    SwitchRow(
        Ic.screenshot,
        "Send new screenshots",
        if (state.sendScreenshots && !state.mediaAccess) noAccess else "Each new screenshot goes to the computer",
        checked = state.sendScreenshots && state.mediaAccess,
    ) { toggle(CaptureKind.Screenshot, state.sendScreenshots) }
    SwitchRow(
        Ic.gallery,
        "Send new photos",
        if (state.sendPhotos && !state.mediaAccess) noAccess else "Each new camera photo goes to the computer",
        checked = state.sendPhotos && state.mediaAccess,
    ) { toggle(CaptureKind.Photo, state.sendPhotos) }
}

/** The connection and the battery of the computer. A computer that is not reachable gets help and a retry. */
@Composable
private fun StatusCard(d: DeviceUi) {
    val scheme = MaterialTheme.colorScheme
    Card(
        Modifier.padding(horizontal = Gutter).fillMaxWidth(),
        shape = RoundedCornerShape(28.dp),
        colors = CardDefaults.cardColors(containerColor = scheme.surfaceContainer),
    ) {
        Row(Modifier.padding(20.dp), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
            IconBadge(
                deviceIcon(d.type),
                container = if (d.online) scheme.primary else scheme.surfaceContainerHighest,
                content = if (d.online) scheme.onPrimary else scheme.onSurfaceVariant,
                size = 48.dp,
            )
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(if (d.online) "Connected" else "Not reachable", style = MaterialTheme.typography.titleMedium)
                if (d.online) {
                    d.battery?.let { level ->
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Sym(batteryIcon(level, d.charging), size = 18.dp, tint = scheme.onSurfaceVariant)
                            Text(
                                "$level%" + if (d.charging) ", charging" else "",
                                style = MaterialTheme.typography.bodyMedium,
                                color = scheme.onSurfaceVariant,
                            )
                        }
                    }
                } else {
                    Text(
                        "Check that Flux runs on ${d.name}, and that both are on the same Wi-Fi.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = scheme.onSurfaceVariant,
                    )
                }
            }
            if (!d.online) TextButton(onClick = { FluxCore.rediscover() }) { Text("Retry") }
        }
    }
}
