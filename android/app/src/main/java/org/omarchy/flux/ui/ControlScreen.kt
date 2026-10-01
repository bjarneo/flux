package org.omarchy.flux.ui

import android.app.Activity
import android.media.projection.MediaProjectionManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import org.omarchy.flux.core.AgentStatus
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Target
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.hasFeature
import org.omarchy.flux.core.target
import org.omarchy.flux.screen.ScreenMirrorService
import org.omarchy.flux.screen.ScreenSession

/**
 * The Control destination: the tools that act on the computer in scope, in
 * bands of at most 4 tiles. A tile shows when a computer in scope has the
 * feature, and it is dimmed while no such computer is online. With more
 * than 1 computer online, a tap asks for the computer.
 */
@Composable
fun ControlScreen(state: UiState, scope: String?, picker: TargetPicker, onOpen: (Route) -> Unit, onPair: () -> Unit) {
    val context = LocalContext.current
    val devices = state.devices
    val any = target(scope, devices)
    val one = (any as? Target.One)?.device
    // Before the first pairing, all tiles show, dimmed, so that the destination shows what it holds.
    val none = devices.none { it.paired }
    fun shows(can: (DeviceUi) -> Boolean) = none || hasFeature(scope, devices, can)
    fun canRun(can: (DeviceUi) -> Boolean) = target(scope, devices, can) !is Target.None
    fun open(can: (DeviceUi) -> Boolean, title: String, page: String, lock: Pair<String, String>? = null) {
        picker.run(target(scope, devices, can), title) { d ->
            if (lock == null) {
                onOpen(Route(d.id, page))
            } else {
                ReplyLock.run(context, { onOpen(Route(d.id, page)) }, lock.first, lock.second) { FluxCore.toast(it) }
            }
        }
    }

    // The screen mirror asks Android for the capture, then the service runs it.
    val screen by ScreenSession.status.collectAsState()
    val shownFirst = remember { ScreenSession.status.value }
    var mirrorFor by rememberSaveable { mutableStateOf<String?>(null) }
    val askCapture = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        val id = mirrorFor
        mirrorFor = null
        val data = r.data
        if (r.resultCode == Activity.RESULT_OK && data != null && id != null) ScreenMirrorService.start(context, id, r.resultCode, data)
    }
    // Only a new error shows, not an old one on a return to this screen.
    LaunchedEffect(screen) {
        if (screen != shownFirst && screen.phase == ScreenSession.Phase.Error) FluxCore.toast(screen.message)
    }
    val mirroring = screen.active
    val mirrorName = devices.firstOrNull { it.id == screen.deviceId }?.name

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter).padding(bottom = 24.dp)) {
        TargetLine(any, devices, "Acts on", onPair)
        Band("Control") {
            if (shows { it.shortcutsSupported }) {
                ActionTile(
                    Ic.grid, "Omarchy panel", Modifier.fillMaxWidth(),
                    sub = "Workspaces, windows, and key bindings", enabled = canRun { it.shortcutsSupported },
                ) { open({ it.shortcutsSupported }, "Open the Omarchy panel of", OMARCHY_PAGE) }
            }
            if (shows { it.inputSupported } || shows { it.desktopSupported }) EqualRow {
                if (shows { it.inputSupported }) {
                    // Remote input can type in any window of the computer, so it asks for the phone lock first.
                    ActionTile(
                        Ic.touchpad, "Touchpad and keyboard", Modifier.weight(1f).fillMaxHeight(), accent = Tn.green,
                        sub = if (one != null && one.remoteInput != true) "Off on ${one.name}" else "Pointer, keys, and slides",
                        enabled = canRun { it.inputSupported },
                    ) { open({ it.inputSupported }, "Use the touchpad of", "touchpad", "Use the touchpad" to "use the touchpad") }
                }
                if (shows { it.desktopSupported }) {
                    // The screen of the computer can show private content, so it also asks for the phone lock first.
                    ActionTile(
                        Ic.desktop, "Remote desktop", Modifier.weight(1f).fillMaxHeight(),
                        sub = when {
                            one == null -> "See and use the screen"
                            one.remoteDesktop != true -> "Off on ${one.name}"
                            one.remoteInput != true -> "View only"
                            else -> "See and use the screen"
                        },
                        enabled = canRun { it.desktopSupported },
                    ) { open({ it.desktopSupported }, "Show the screen of", "desktop", "Show the computer screen" to "show the computer screen") }
                }
            }
            EqualRow {
                ActionTile(
                    Ic.terminal, "Commands", Modifier.weight(1f).fillMaxHeight(), accent = Tn.yellow,
                    sub = "Run the commands of the computer", enabled = any !is Target.None,
                ) { open({ true }, "Run the commands of", "commands") }
                ActionTile(
                    Ic.music, "Media", Modifier.weight(1f).fillMaxHeight(), accent = Tn.green,
                    sub = one?.player?.title?.takeIf { it.isNotEmpty() } ?: "Play, pause, and volume", enabled = any !is Target.None,
                ) { open({ true }, "Control the media of", "media") }
            }
        }
        Band("Stream") {
            EqualRow {
                ActionTile(
                    Ic.mic, "Mic", Modifier.weight(1f).fillMaxHeight(), accent = Tn.orange,
                    sub = "Use this phone as a microphone", enabled = any !is Target.None,
                ) { open({ true }, "Stream the mic to", "mic") }
                ActionTile(
                    Ic.videocamOutline, "Webcam", Modifier.weight(1f).fillMaxHeight(), accent = Tn.cyan,
                    sub = "Use this phone as a webcam", enabled = any !is Target.None,
                ) { open({ true }, "Stream the camera to", "camera:webcam") }
            }
            EqualRow {
                if (mirroring) {
                    ActionTile(
                        Ic.stopScreenShare, "Stop the mirror", Modifier.weight(1f).fillMaxHeight(), accent = Tn.cyan,
                        sub = mirrorName?.let { "Shows this phone on $it" },
                    ) { ScreenSession.stop() }
                } else {
                    ActionTile(
                        Ic.screenShare, "Mirror", Modifier.weight(1f).fillMaxHeight(), accent = Tn.cyan,
                        sub = "Show this phone screen on the computer", enabled = any !is Target.None,
                    ) {
                        picker.run(target(scope, devices), "Mirror this phone to") { d ->
                            mirrorFor = d.id
                            askCapture.launch(context.getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent())
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
            }
        }
        if (shows { it.herdrSupported }) {
            Band("Agents") {
                val scoped = devices.filter { it.paired && it.online && (scope == null || it.id == scope) }
                val agents = scoped.sumOf { it.herdr?.agents?.size ?: 0 }
                val blocked = scoped.sumOf { d -> d.herdr?.agents?.count { it.status == AgentStatus.Blocked } ?: 0 }
                val terminals = scoped.sumOf { it.herdr?.panes?.size ?: 0 }
                EqualRow {
                    ActionTile(
                        Ic.agent, "Agents and terminals", Modifier.weight(1f).fillMaxHeight(), accent = Tn.magenta,
                        sub = listOf(
                            "$agents ${if (agents == 1) "agent" else "agents"}",
                            "$terminals ${if (terminals == 1) "terminal" else "terminals"}",
                        ).joinToString(" · "),
                        enabled = canRun { it.herdrSupported }, badge = blocked,
                    ) { open({ it.herdrSupported }, "Show the agents of", AGENTS_PAGE) }
                    if (shows { it.herdr?.control == true }) {
                        ActionTile(
                            Ic.add, "New agent or terminal", Modifier.weight(1f).fillMaxHeight(), accent = Tn.magenta,
                            sub = "Start it in a herdr workspace", enabled = canRun { it.herdr?.let { h -> h.running && h.control } == true },
                        ) { open({ it.herdr?.let { h -> h.running && h.control } == true }, "Start an agent on", NEW_PANE_PAGE) }
                    } else {
                        Spacer(Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

/**
 * The Omarchy panel of 1 computer: workspaces, windows, and the key
 * bindings. The computer runs each action in Hyprland. The panel sends
 * input, so it asks for the phone lock first, like the touchpad.
 */
@Composable
fun OmarchyScreen(d: DeviceUi, onBack: () -> Unit) {
    val ready = d.online && d.shortcutsSupported && d.remoteInput == true
    val unlocked = rememberRemoteUnlock(ready, "Use the Omarchy panel", "use the Omarchy panel", onBack, sample = isDemo(d.id))
    Column(Modifier.fillMaxSize().padding(horizontal = TiledGutter)) {
        TiledTopBar("omarchy · ${d.name}", onBack)
        when {
            !d.online -> NotReachable(d, "The workspaces and the shortcuts")
            !d.shortcutsSupported -> EmptyState(
                Ic.grid, "Update Flux on ${d.name}",
                "This version of Flux on ${d.name} does not send its workspaces and key bindings.",
                Modifier.padding(top = 48.dp),
            )
            d.remoteInput != true -> EmptyState(
                Ic.grid, "Remote input is off",
                "On ${d.name}, set remote_input = true in ~/.config/flux/config.toml, then run systemctl --user reload fluxd.",
                Modifier.padding(top = 48.dp),
            )
            !unlocked -> EmptyState(Ic.grid, "Unlock to continue", "Confirm with the phone lock to use the Omarchy panel.", Modifier.padding(top = 48.dp))
            else -> OmarchyPanel(d, Modifier.fillMaxWidth().weight(1f).padding(bottom = 12.dp))
        }
    }
}
