package org.omarchy.flux.ui

import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.core.Share
import org.omarchy.flux.core.UiState
import org.omarchy.flux.service.FluxNotificationListener

/** The short code in the round avatar of a device row. */
fun kindCode(type: String): String = when (type) {
    "phone" -> "PH"
    "tablet" -> "TAB"
    "tv" -> "TV"
    else -> "PC"
}

private fun typeLabel(d: DeviceUi): String = when {
    d.isFlux -> "Omarchy"
    else -> d.type.replaceFirstChar { it.uppercase() }
}

@Composable
fun DevicesScreen(
    state: UiState,
    onOpen: (DeviceUi) -> Unit,
    onPair: (DeviceUi) -> Unit,
    onUnpair: (DeviceUi) -> Unit,
) {
    val accent = Palette.accent
    val paired = state.devices.filter { it.paired }
    val available = state.devices.filter { !it.paired && it.online }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Row(
            Modifier.padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            FluxMark(28.dp)
            T("Flux", size = 32)
        }
        Column(
            Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 18.dp).fillMaxWidth()
                .clip(RoundedCornerShape(24.dp)).background(Palette.accentContainer)
                .padding(horizontal = 18.dp, vertical = 16.dp),
        ) {
            T("THIS PHONE", size = 12, color = Palette.onAccentContainer, weight = FontWeight.Medium)
            T(
                "${state.phoneName} · " + if (state.onWifi) "visible on Wi-Fi" else "not on Wi-Fi",
                Modifier.padding(top = 4.dp), size = 16, color = Palette.onAccentContainer,
            )
        }

        SectionHeader("Paired")
        if (paired.isEmpty()) {
            T("No paired computers yet", Modifier.padding(horizontal = 20.dp, vertical = 14.dp), color = Palette.secondary)
        }
        for (d in paired) {
            PressRow(onClick = if (d.online) ({ onOpen(d) }) else null, onLongClick = { onUnpair(d) }) {
                DeviceRowContent(
                    d,
                    subtitle = if (d.online) "Connected" + (d.battery?.let { " · battery $it%" } ?: "") else "Not reachable",
                    trailing = { if (d.online) T("›", color = Palette.secondary) },
                )
            }
        }

        SectionHeader("Available", top = 18)
        if (available.isEmpty()) {
            PressRow(onClick = { FluxCore.rediscover() }) {
                Column(Modifier.padding(horizontal = 20.dp, vertical = 14.dp)) {
                    T("Looking for computers on this network", color = Palette.secondary)
                    T(
                        "Install Flux on the computer. Tap to search again.",
                        Modifier.padding(top = 4.dp), size = 13, color = Palette.hint,
                    )
                }
            }
        }
        for (d in available) {
            DeviceRowContent(
                d,
                subtitle = "${typeLabel(d)} · ${d.ip}",
                trailing = {
                    Box(
                        Modifier.clip(RoundedCornerShape(20.dp)).border(1.dp, Palette.borderStrong, RoundedCornerShape(20.dp))
                            .clickable { onPair(d) }.padding(horizontal = 18.dp, vertical = 9.dp),
                    ) { T("Pair", color = accent, weight = FontWeight.Medium) }
                },
            )
        }
        Spacer(Modifier.height(96.dp))
    }
}

@Composable
private fun DeviceRowContent(d: DeviceUi, subtitle: String, trailing: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Avatar(kindCode(d.type), on = d.paired && d.online)
        Column(Modifier.weight(1f)) {
            T(d.name, size = 16, maxLines = 1)
            T(subtitle, size = 13, color = Palette.secondary, maxLines = 1)
        }
        trailing()
    }
}

private data class TileDef(val glyph: String, val label: String, val action: () -> Unit)

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun HomeScreen(
    d: DeviceUi,
    state: UiState,
    onBack: () -> Unit,
    onNavigate: (String) -> Unit,
) {
    val context = LocalContext.current
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) Share.sendFiles(FluxCore, d.id, uris)
    }
    val offline = { FluxCore.toast("${d.name} is not reachable") }
    fun guarded(action: () -> Unit): () -> Unit = { if (d.online) action() else offline() }
    val tiles = listOf(
        TileDef("⧉", "Send clipboard", guarded { Plugins.sendClipboard(FluxCore, d.id) }),
        TileDef("↑", "Send files", guarded { pickFiles.launch(arrayOf("*/*")) }),
        TileDef("\u2317", "Camera", guarded { onNavigate("camera") }),
        TileDef("♪", "Media", guarded { onNavigate("media") }),
        TileDef("$", "Run commands", guarded { onNavigate("commands") }),
        TileDef("▤", "Browse PC", guarded { onNavigate("browse") }),
        TileDef("◉", "Ring PC", guarded { Plugins.ring(FluxCore, d.id) }),
    )
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        TopBar(d.name, onBack)
        FlowRow(
            Modifier.padding(start = 20.dp, end = 20.dp, top = 4.dp, bottom = 18.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (d.online) Chip("● Connected", filled = true) else Chip("● Not reachable", filled = false)
            d.battery?.let { Chip("Battery $it%" + if (d.charging) " · charging" else "", filled = false) }
            if (state.onWifi) Chip("Wi-Fi", filled = false)
        }
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            for (row in tiles.chunked(2)) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    for (t in row) {
                        Tile(t.glyph, t.label, enabled = d.online, onClick = t.action, modifier = Modifier.weight(1f).alpha(if (d.online) 1f else 0.5f))
                    }
                    // An odd tile count leaves a gap, so that the last tile keeps the column width.
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
        SectionHeader("Sync", top = 20)
        SwitchRow(
            "Share notifications",
            if (state.notificationAccess) "Show on the PC as notifications" else "Tap to allow notification access",
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
        SwitchRow("Sync clipboard", "Both directions, automatically", checked = state.syncClipboard) {
            FluxCore.setSyncClipboard(!state.syncClipboard)
        }
        Spacer(Modifier.height(96.dp))
    }
}
