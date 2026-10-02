package org.omarchy.flux.ui

import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.ThemeMode
import org.omarchy.flux.core.UiState

/**
 * The Computers destination: this phone, the paired computers, the
 * computers that are available to pair, and the settings of the app. A tap
 * on a paired computer makes it the scope. A pull down scans again.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ComputersScreen(
    state: UiState,
    scope: String?,
    onScope: (String?) -> Unit,
    onPair: (DeviceUi) -> Unit,
    onUnpair: (DeviceUi) -> Unit,
    onSync: () -> Unit,
) {
    val paired = state.devices.filter { it.paired }
    val available = state.devices.filter { !it.paired && it.online }
    var refreshing by remember { mutableStateOf(false) }
    var turningOff by remember { mutableStateOf(false) }
    LaunchedEffect(refreshing) {
        if (refreshing) {
            FluxCore.scan()
            delay(1500)
            refreshing = false
        }
    }
    PullToRefreshBox(isRefreshing = refreshing, onRefresh = { refreshing = true }, modifier = Modifier.fillMaxSize()) {
        CappedScrollColumn {
            PhoneRow(state)
            SectionLabel("Paired")
            Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
                if (paired.isEmpty()) {
                    T("No computer is paired. Pair one below. A paired computer connects by itself.", Modifier.padding(horizontal = 4.dp), size = 14, color = Tn.sub)
                }
                for (d in paired) {
                    ComputerRow(d, inScope = scope == d.id, onScope = { onScope(if (scope == d.id) null else d.id) }, onUnpair = { onUnpair(d) })
                }
            }
            SectionLabel("Available")
            Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
                for (d in available) AvailableRow(d) { onPair(d) }
                ScanRow(state, none = available.isEmpty(), first = paired.isEmpty()) { refreshing = true }
            }
            SectionLabel("Settings")
            Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
                val (on, total) = syncSummary(state)
                SettingRow(Ic.sync, "Sync", "$on of $total switches on. They apply to every computer.", onClick = onSync)
                ThemeRow(state)
                // The row runs an action and opens no screen, so it has no chevron. A dialog asks first.
                SettingRow(Ic.power, "Turn off Flux", "This phone stops all connections until you turn Flux on again.", chevron = false) { turningOff = true }
            }
        }
    }
    if (turningOff) {
        ConfirmDialog(
            "Turn off Flux?",
            "This phone stops all connections to the computers. Approvals, agent alerts, and the clipboard do not reach this phone until you turn Flux on again.",
            "Turn off",
            onCancel = { turningOff = false },
            onConfirm = {
                turningOff = false
                FluxCore.setEnabled(false)
            },
            icon = Ic.power,
            destructive = true,
        )
    }
}

/** This phone: its name, and whether computers can see it. */
@Composable
private fun PhoneRow(state: UiState) {
    Row(
        Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(Ic.phone, tint = Tn.cyan, size = 22.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(state.phoneName.ifEmpty { "This phone" }, size = 15, weight = FontWeight.SemiBold)
            T(
                if (state.onWifi) "Visible to computers on this Wi-Fi" else "Not on Wi-Fi. Connect to the network of the computer.",
                size = 13, color = if (state.onWifi) Tn.sub else Tn.yellow,
            )
        }
    }
}

/**
 * A paired computer: its link, its battery, and Unpair. A tap makes it the
 * scope, and a tap on the computer in scope shows all computers again.
 */
@Composable
private fun ComputerRow(d: DeviceUi, inScope: Boolean, onScope: () -> Unit, onUnpair: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 72.dp).clip(TileShape).background(Tn.tile)
            .border(if (inScope) 2.dp else 1.dp, if (inScope) Tn.blue else Tn.line, TileShape)
            .clickable(onClickLabel = if (inScope) "Show all computers" else "Show only ${d.name}", role = Role.Button, onClick = onScope)
            .semantics { if (inScope) stateDescription = "In scope" }
            .padding(start = 14.dp, end = 4.dp, top = 10.dp, bottom = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(deviceIcon(d.type), tint = if (d.online) Tn.blue else Tn.sub, size = 24.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            T(d.name, size = 16, weight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                LinkDot(d.online, 7.dp)
                T(linkText(d), size = 13, color = Tn.sub, maxLines = 2)
            }
            // The address helps with network and Tailscale problems.
            if (d.ip.isNotBlank()) T(d.ip, size = 12, color = Tn.sub, family = Mono, maxLines = 1)
            if (!d.online) T("Check that Flux runs on ${d.name}, and that both are on the same Wi-Fi.", size = 13, color = Tn.sub)
            if (inScope) T("In scope", size = 12, color = Tn.blue, weight = FontWeight.Medium)
        }
        if (!d.online) FluxButton("Retry", { FluxCore.rediscover() }, kind = ButtonKind.Text)
        IconButton(onClick = onUnpair) { Sym(Ic.unlink, "Unpair ${d.name}", tint = Tn.sub) }
    }
}

/** A computer that runs Flux and is not paired. A tap opens the pairing sheet. The Inbox guide uses it before the first pairing. */
@Composable
internal fun AvailableRow(d: DeviceUi, onPair: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).dashedBorder(Tn.yellow).clip(TileShape)
            .clickable(onClickLabel = "Pair with ${d.name}", role = Role.Button, onClick = onPair)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(Ic.add, tint = Tn.yellow, size = 24.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(d.name, size = 16, weight = FontWeight.SemiBold)
            T("Tap to pair", size = 13, color = Tn.yellow)
        }
    }
}

/**
 * The scan state, help when no computer shows, and Scan again. [hint] is
 * the help under "No computers found", or null for no help. The Inbox guide
 * uses it before the first pairing, with its own hint.
 */
@Composable
internal fun ScanRow(
    state: UiState,
    none: Boolean,
    first: Boolean,
    hint: String? = "Open Flux on the computer, and use the same Wi-Fi network as this phone.",
    onScan: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (state.scanning) {
            Row(Modifier.heightIn(min = 48.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Spinner(Modifier.size(16.dp), color = Tn.yellow)
                T("Looking for computers", size = 14, color = Tn.sub)
            }
            return@Column
        }
        if (none) {
            T(if (first) "No computers found" else "No other computers found", size = 14, weight = FontWeight.SemiBold)
            if (hint != null) T(hint, size = 13, color = Tn.sub)
        }
        FluxButton("Scan again", onScan, Modifier.offset(x = (-12).dp), kind = ButtonKind.Text, icon = Ic.refresh)
    }
}

/** A row that opens a setting, with a chevron, or that runs an action, with no chevron. */
@Composable
private fun SettingRow(@DrawableRes icon: Int, title: String, detail: String, chevron: Boolean = true, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(icon, tint = Tn.blue, size = 22.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(title, size = 15, weight = FontWeight.SemiBold)
            T(detail, size = 13, color = Tn.sub, lineHeight = 1.3f)
        }
        if (chevron) Sym(Ic.chevron, tint = Tn.sub, size = 20.dp)
    }
}

/**
 * The theme of the app, as 1 choice of [ThemeChoices]. The Computer choice
 * names the theme that it draws now and the computer that sent it.
 */
@Composable
private fun ThemeRow(state: UiState) {
    val computerLine = computerThemeLine(state, isSystemInDarkTheme())
    Column(
        Modifier.fillMaxWidth().clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape).padding(vertical = 6.dp),
    ) {
        T(
            "Theme", Modifier.padding(start = 14.dp, end = 14.dp, top = 8.dp, bottom = 4.dp).semantics { heading() },
            size = 15, weight = FontWeight.SemiBold,
        )
        Column(Modifier.selectableGroup()) {
            for ((mode, label, icon) in ThemeChoices) {
                val selected = mode == state.theme
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 56.dp)
                        .selectable(selected = selected, role = Role.RadioButton, onClick = { FluxCore.setTheme(mode) })
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Sym(icon, tint = if (selected) Tn.blue else Tn.sub, size = 22.dp)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        T(label, size = 15, weight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
                        if (mode == ThemeMode.Computer) T(computerLine, size = 13, color = Tn.sub, lineHeight = 1.3f)
                    }
                    // The row takes the tap and gives the state to TalkBack, so the radio button only shows it.
                    RadioButton(selected = selected, onClick = null)
                }
            }
        }
    }
}
