package org.omarchy.flux.ui

import android.os.Build
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.net.InetAddress
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.omarchy.flux.BuildConfig
import org.omarchy.flux.R
import org.omarchy.flux.core.ApproveAtOnce
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.ScrollMode
import org.omarchy.flux.core.SshKeys
import org.omarchy.flux.core.ThemeMode
import org.omarchy.flux.core.UiState
import org.omarchy.flux.net.isTailscale

/**
 * The Computers destination: this phone, the paired computers, and the
 * computers that are available to pair. The settings of the app moved to
 * [SettingsScreen]. A tap on a paired computer makes it the scope, and a long press offers
 * Unpair. The dock shows the scan, with Scan again. A pull down scans
 * too.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ComputersScreen(
    state: UiState,
    scope: String?,
    onScope: (String?) -> Unit,
    onPair: (DeviceUi) -> Unit,
    onUnpair: (DeviceUi) -> Unit,
) {
    val paired = state.devices.filter { it.paired }
    val available = state.devices.filter { !it.paired && it.online }
    var refreshing by remember { mutableStateOf(false) }
    LaunchedEffect(refreshing) {
        if (refreshing) {
            FluxCore.scan()
            delay(1500)
            refreshing = false
        }
    }
    val context = onlineText(state.devices).ifEmpty { "No computer is paired" }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.statusBarsPadding()) {
            ScreenHeader("Computers", context) { ScopeChip(state.devices, scope, onScope, compact = true, onUnpair = onUnpair) }
        }
        ProgressLine { if (state.scanning) SlideBar(Tn.yellow, Modifier.fillMaxSize()) }
        DockLayout(
            Modifier.weight(1f).fillMaxWidth(),
            thread = { bottom ->
                PullToRefreshBox(isRefreshing = refreshing, onRefresh = { refreshing = true }, modifier = Modifier.fillMaxSize()) {
                    Column(
                        Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                            .padding(start = 10.dp, end = 10.dp, top = 6.dp, bottom = maxOf(bottom, 28.dp)),
                        verticalArrangement = Arrangement.spacedBy(TileGap),
                    ) {
                        PhoneRow(state)
                        ListHeader("Paired")
                        if (paired.isEmpty()) {
                            T("No computer is paired. Pair one below. A paired computer connects by itself.", Modifier.padding(horizontal = 4.dp), size = 14, color = Tn.sub)
                        }
                        for (d in paired) {
                            ComputerCard(d, state.onWifi, inScope = scope == d.id, onScope = { onScope(if (scope == d.id) null else d.id) }, onUnpair = { onUnpair(d) })
                        }
                        ListHeader("Available")
                        for (d in available) AvailableRow(d) { onPair(d) }
                        if (available.isEmpty() && !state.scanning) {
                            T(
                                if (paired.isEmpty()) "No computers found. Open Flux on the computer, and use the same Wi-Fi network as this phone." else "No other computers found.",
                                Modifier.padding(horizontal = 4.dp), size = 14, color = Tn.sub, lineHeight = 1.35f,
                            )
                        }
                    }
                }
            },
            dock = { shape -> ScanDock(state, available.size, shape) { FluxCore.scan() } },
        )
    }
}

/** This phone: its name, and whether computers can see it. */
@Composable
private fun PhoneRow(state: UiState) {
    Row(
        Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = 10.dp, bottom = 2.dp),
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

/** The link of a computer in words: "Connected · Wi-Fi", "Connected · Tailscale", or "Offline". */
private fun linkLine(d: DeviceUi, onWifi: Boolean): String {
    if (!d.online) return "Offline"
    // Only an address with digits, dots, colons, and hex letters goes to the parser, so that it never looks up a name.
    val tailscale = d.ip.isNotBlank() && d.ip.none { it.isLetter() && it !in 'a'..'f' && it !in 'A'..'F' } &&
        runCatching { isTailscale(InetAddress.getByName(d.ip)) }.getOrDefault(false)
    return when {
        tailscale -> "Connected · Tailscale"
        onWifi -> "Connected · Wi-Fi"
        else -> "Connected"
    }
}

/**
 * A paired computer: its link, its address and battery, and a note while
 * it is offline. A tap makes it the scope, and a tap on the computer in
 * scope shows all computers again. The menu key and a long press open
 * Unpair, and Retry and Wake for a computer that is not reachable.
 * TalkBack offers the same actions.
 */
@Composable
private fun ComputerCard(d: DeviceUi, onWifi: Boolean, inScope: Boolean, onScope: () -> Unit, onUnpair: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth().clip(TileShape).background(Tn.tile)
                .border(if (inScope) 2.dp else 1.dp, if (inScope) Tn.blue else Tn.line, TileShape)
                .combinedClickable(
                    onClickLabel = if (inScope) "Show all computers" else "Show only ${d.name}",
                    role = Role.Button,
                    onLongClickLabel = "Show the actions",
                    onLongClick = { menu = true },
                    onClick = onScope,
                )
                .semantics {
                    if (inScope) stateDescription = "In scope"
                    customActions = listOfNotNull(
                        CustomAccessibilityAction("Unpair ${d.name}") {
                            onUnpair()
                            true
                        },
                        if (d.online) {
                            null
                        } else {
                            CustomAccessibilityAction("Retry") {
                                FluxCore.rediscover()
                                true
                            }
                        },
                        if (d.online || !d.canWake) {
                            null
                        } else {
                            CustomAccessibilityAction("Wake ${d.name}") {
                                FluxCore.wake(d.id)
                                true
                            }
                        },
                    )
                }
                .padding(start = 14.dp, end = 4.dp, top = 12.dp, bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Sym(deviceIcon(d.type), null, Modifier.padding(top = 1.dp), tint = if (d.online) Tn.blue else Tn.sub, size = 24.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    T(d.name, Modifier.weight(1f), size = 16, weight = FontWeight.SemiBold, maxLines = 1)
                    if (inScope) T("In scope", size = 12, color = Tn.blue, weight = FontWeight.Medium)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (d.online) Dot(Tn.green, 8.dp) else RingMark()
                    T(linkLine(d, onWifi), size = 13, color = Tn.sub, maxLines = 1)
                }
                // The address helps with network and Tailscale problems.
                val battery = d.battery?.let { "battery $it%" + if (d.charging) ", charging" else "" }
                val ip = listOfNotNull(d.ip.takeIf { it.isNotBlank() }, battery).joinToString(" · ")
                if (ip.isNotEmpty()) T(ip, size = 12, color = Tn.sub, family = Mono, maxLines = 1)
                if (!d.online) T("Check that Flux runs on ${d.name}, and that both are on the same Wi-Fi.", size = 13, color = Tn.sub, lineHeight = 1.35f)
                if (!d.online && d.canWake) WakeButton(d)
            }
            // The key shows the same actions as the long press. It sits level with the name, and the row keeps its height.
            Box(Modifier.offset(y = (-8).dp)) { ComputerMenuKey(d, onUnpair) }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (!d.online) {
                DropdownMenuItem(text = { Text("Retry") }, leadingIcon = { Sym(Ic.refresh) }, onClick = {
                    menu = false
                    FluxCore.rediscover()
                })
            }
            if (!d.online && d.canWake) {
                DropdownMenuItem(text = { Text("Wake") }, leadingIcon = { Sym(Ic.power) }, onClick = {
                    menu = false
                    FluxCore.wake(d.id)
                })
            }
            DropdownMenuItem(text = { Text("Unpair") }, leadingIcon = { Sym(Ic.unlink) }, onClick = {
                menu = false
                onUnpair()
            })
        }
    }
}

/**
 * Wake for a paired computer that is offline and sent its network cards.
 * It sends a Wake-on-LAN magic packet. It is 36 dp high and takes taps on
 * 48 dp.
 */
@Composable
private fun WakeButton(d: DeviceUi) {
    val shape = RoundedCornerShape(18.dp)
    Row(
        Modifier.padding(top = 4.dp).overhang(6.dp).clip(shape)
            .clickable(onClickLabel = "Wake ${d.name}", role = Role.Button) { FluxCore.wake(d.id) }
            .padding(vertical = 6.dp).height(36.dp).clip(shape)
            .background(Tn.tile).border(1.dp, Tn.line, shape)
            .padding(start = 11.dp, end = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(Ic.power, null, tint = Tn.blue, size = 18.dp)
        T("Wake", size = 13, weight = FontWeight.Medium, maxLines = 1)
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

/**
 * The dock of Computers: the scan that runs, or the number of computers to
 * pair and the time of the last scan, with Scan again.
 */
@Composable
private fun ScanDock(state: UiState, available: Int, shape: DockShape, onScan: () -> Unit) {
    val now by rememberTicker(30_000L)
    val scanning = state.scanning
    Row(
        Modifier.fillMaxWidth().dockFrame(shape).padding(start = 12.dp, end = 12.dp, top = 14.dp, bottom = 10.dp)
            .heightIn(min = 44.dp).padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(20.dp), contentAlignment = Alignment.Center) {
            if (scanning) RingSpinner(16.dp, color = Tn.yellow) else Sym(Ic.wifiFind, tint = Tn.sub, size = 20.dp)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(
                when {
                    scanning -> "Looking for computers"
                    available == 0 -> "No computer to pair"
                    available == 1 -> "1 computer to pair"
                    else -> "$available computers to pair"
                },
                size = 14, weight = FontWeight.SemiBold, maxLines = 1,
            )
            T(
                when {
                    scanning -> if (state.onWifi) "on this Wi-Fi" else "on this network"
                    state.lastScan > 0 -> "last scan ${agoText(state.lastScan, now)}"
                    else -> "pull down to scan"
                },
                size = 11, color = Tn.sub, family = Mono, maxLines = 1,
            )
        }
        Box(
            Modifier.height(40.dp).alpha(if (scanning) DimAlpha else 1f).clip(RoundedCornerShape(12.dp)).background(Tn.line)
                .clickable(enabled = !scanning, role = Role.Button, onClick = onScan).padding(horizontal = 14.dp),
            contentAlignment = Alignment.Center,
        ) { T("Scan again", size = 13, weight = FontWeight.SemiBold, maxLines = 1) }
    }
}
