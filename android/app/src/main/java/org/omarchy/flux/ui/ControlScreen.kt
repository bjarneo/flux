package org.omarchy.flux.ui

import android.app.Activity
import android.media.projection.MediaProjectionManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
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
 * The Control destination: the tools that act on the computer in scope.
 * The most used tool, the Omarchy panel, takes the master tile. The other
 * tools stack under it in compact rows, in groups. A tool shows when a
 * computer in scope has the feature, and it is dimmed while no such
 * computer is online. With more than 1 computer online, a tap asks for the
 * computer.
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

    CappedScrollColumn {
        TargetLine(any, devices, "Acts on", onPair)
        Spacer(Modifier.height(TileGap))
        // The Omarchy panel is the master tile. The other tools that act on the computer stack under it.
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            if (shows { it.shortcutsSupported }) {
                MasterTool(Ic.grid, "Omarchy panel", "Workspaces, windows, and key bindings", enabled = canRun { it.shortcutsSupported }) {
                    open({ it.shortcutsSupported }, "Open the Omarchy panel of", OMARCHY_PAGE)
                }
            }
            if (shows { it.inputSupported }) {
                // Remote input can type in any window of the computer, so it asks for the phone lock first.
                ToolRow(
                    Ic.touchpad, "Touchpad and keyboard",
                    if (one != null && one.remoteInput != true) "Off on ${one.name}" else "Pointer, keys, and slides",
                    enabled = canRun { it.inputSupported },
                ) { open({ it.inputSupported }, "Use the touchpad of", "touchpad", "Use the touchpad" to "use the touchpad") }
            }
            if (shows { it.desktopSupported }) {
                // The screen of the computer can show private content, so it also asks for the phone lock first.
                ToolRow(
                    Ic.desktop, "Remote desktop",
                    when {
                        one == null -> "See and use the screen"
                        one.remoteDesktop != true -> "Off on ${one.name}"
                        one.remoteInput != true -> "View only"
                        else -> "See and use the screen"
                    },
                    enabled = canRun { it.desktopSupported },
                ) { open({ it.desktopSupported }, "Show the screen of", "desktop", "Show the computer screen" to "show the computer screen") }
            }
            ToolRow(Ic.terminal, "Commands", "Run the commands of the computer", enabled = any !is Target.None) {
                open({ true }, "Run the commands of", "commands")
            }
            ToolRow(
                Ic.music, "Media", one?.player?.title?.takeIf { it.isNotEmpty() } ?: "Play, pause, and volume", enabled = any !is Target.None,
            ) { open({ true }, "Control the media of", "media") }
        }
        SectionLabel("Stream")
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            ToolRow(Ic.mic, "Mic", "Use this phone as a microphone", enabled = any !is Target.None) {
                open({ true }, "Stream the mic to", MIC_PAGE)
            }
            ToolRow(Ic.videocamOutline, "Webcam", "Use this phone as a webcam", enabled = any !is Target.None) {
                open({ true }, "Stream the camera to", WEBCAM_PAGE)
            }
            if (mirroring) {
                ToolRow(Ic.stopScreenShare, "Stop the mirror", mirrorName?.let { "Shows this phone on $it" }, enabled = true) { ScreenSession.stop() }
            } else {
                ToolRow(Ic.screenShare, "Mirror", "Show this phone screen on the computer", enabled = any !is Target.None) {
                    picker.run(target(scope, devices), "Mirror this phone to") { d ->
                        mirrorFor = d.id
                        askCapture.launch(context.getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent())
                    }
                }
            }
        }
        if (shows { it.herdrSupported }) {
            SectionLabel("Agents")
            val scoped = devices.filter { it.paired && it.online && (scope == null || it.id == scope) }
            val agents = scoped.sumOf { it.herdr?.agents?.size ?: 0 }
            val blocked = scoped.sumOf { d -> d.herdr?.agents?.count { it.status == AgentStatus.Blocked } ?: 0 }
            val terminals = scoped.sumOf { it.herdr?.panes?.size ?: 0 }
            Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
                ToolRow(
                    Ic.agent, "Agents and terminals",
                    listOf(
                        "$agents ${if (agents == 1) "agent" else "agents"}",
                        "$terminals ${if (terminals == 1) "terminal" else "terminals"}",
                    ).joinToString(" · "),
                    enabled = canRun { it.herdrSupported }, badge = blocked,
                ) { open({ it.herdrSupported }, "Show the agents of", AGENTS_PAGE) }
                if (shows { it.herdr?.control == true }) {
                    ToolRow(
                        Ic.add, "New agent or terminal", "Start it in a herdr workspace",
                        enabled = canRun { it.herdr?.let { h -> h.running && h.control } == true },
                    ) { open({ it.herdr?.let { h -> h.running && h.control } == true }, "Start an agent on", NEW_PANE_PAGE) }
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
        TiledTopBar("Omarchy panel", onBack, context = d.name)
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
