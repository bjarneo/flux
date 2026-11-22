package org.omarchy.flux.ui

import android.app.Activity
import android.media.projection.MediaProjectionManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.core.Target
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.hasFeature
import org.omarchy.flux.core.target
import org.omarchy.flux.screen.ScreenMirrorService
import org.omarchy.flux.screen.ScreenSession

/**
 * The Remote destination: the tools that act on the computer and the
 * streams of this phone. It holds no agents. They live in Chats. The dock shows the player of the computer. A tool shows when a
 * computer in scope has the feature, and it is dimmed while no such
 * computer is online. With more than 1 computer online, a tap asks for the
 * computer.
 */
@Composable
fun RemoteScreen(
    state: UiState,
    scope: String?,
    onScope: (String?) -> Unit,
    onUnpair: (DeviceUi) -> Unit,
    picker: TargetPicker,
    onOpen: (Route) -> Unit,
    onPair: () -> Unit,
) {
    val context = LocalContext.current
    // The Extend screen tool names this device.
    val kind = if (LocalConfiguration.current.smallestScreenWidthDp >= 600) "tablet" else "phone"
    val devices = state.devices
    val any = target(scope, devices)
    val one = (any as? Target.One)?.device
    // Before the first pairing, all tools show, dimmed, so that the destination shows what it holds.
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

    val scoped = devices.filter { it.paired && it.online && (scope == null || it.id == scope) }
    // The dock plays the computer in scope, or the first computer that plays.
    val player = scoped.filter { it.player != null }.let { l -> l.firstOrNull { it.player?.playing == true } ?: l.firstOrNull() }

    Column(Modifier.fillMaxSize()) {
        Box(Modifier.statusBarsPadding()) {
            ScreenHeader("Remote", onlineText(devices)) { ScopeChip(devices, scope, onScope, compact = true, onUnpair = onUnpair) }
        }
        DockLayout(
            Modifier.weight(1f).fillMaxWidth(),
            thread = { bottom ->
                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                        .padding(start = 10.dp, end = 10.dp, top = 6.dp, bottom = maxOf(bottom, 28.dp)),
                    verticalArrangement = Arrangement.spacedBy(TileGap),
                ) {
                    if (none) TargetLine(any, devices, "Acts on", onPair)
                    ListHeader("Tools")
                    val tools = buildList {
                        if (shows { it.shortcutsSupported }) {
                            val s = one?.shortcuts
                            val sub = if (s?.loaded == true && s.active > 0) {
                                val n = s.workspaces.firstOrNull { it.id == s.active }?.windows ?: 0
                                "Workspace ${s.active} · $n ${if (n == 1) "window" else "windows"}"
                            } else {
                                "Workspaces, windows, and key bindings"
                            }
                            add(ControlTool(Ic.grid, "Omarchy panel", sub, canRun { it.shortcutsSupported }) {
                                open({ it.shortcutsSupported }, "Open the Omarchy panel of", OMARCHY_PAGE)
                            })
                        }
                        if (shows { it.inputSupported }) {
                            // Remote input can type in any window of the computer, so it asks for the phone lock first.
                            val sub = if (one != null && one.remoteInput != true) "Off on ${one.name}" else "Pointer, keys, and slides"
                            add(ControlTool(Ic.touchApp, "Touchpad", sub, canRun { it.inputSupported }) {
                                open({ it.inputSupported }, "Use the touchpad of", "touchpad", "Use the touchpad" to "use the touchpad")
                            })
                        }
                        if (shows { it.desktopSupported }) {
                            // The screen of the computer can show private content, so it also asks for the phone lock first.
                            val sub = when {
                                one == null -> "See and use the screen"
                                one.remoteDesktop != true -> "Off on ${one.name}"
                                one.remoteInput != true -> "View only"
                                else -> "See and use the screen"
                            }
                            add(ControlTool(Ic.desktop, "Remote desktop", sub, canRun { it.desktopSupported }) {
                                open({ it.desktopSupported }, "Show the screen of", "desktop", "Show the computer screen" to "show the computer screen")
                            })
                        }
                        if (shows { it.extendSupported }) {
                            // The computer adds a monitor that this phone or tablet shows. It uses the switch and the phone lock of the remote desktop.
                            val can = { d: DeviceUi -> d.extendSupported }
                            val sub = if (one != null && one.remoteDesktop != true) "Off on ${one.name}" else "Use this $kind as a second monitor"
                            add(ControlTool(Ic.devices, "Extend screen", sub, canRun(can)) {
                                open(can, "Extend the screen of", EXTEND_PAGE, "Extend the computer screen" to "extend the computer screen")
                            })
                        }
                        add(ControlTool(Ic.terminal, "Commands", "Run a command", any !is Target.None) { open({ true }, "Run the commands of", "commands") })
                        // The dock opens the media, so the tool shows only while no player shows there.
                        if (player == null) {
                            add(ControlTool(Ic.music, "Media", "Play, pause, and volume", any !is Target.None) { open({ true }, "Open the media of", "media") })
                        }
                    }
                    GridRows(tools, 2) { k, m -> GridTool(k.icon, k.label, k.sub, k.enabled, m, k.onClick) }
                    ListHeader("Stream")
                    val on = any !is Target.None
                    val mirroring = screen.active
                    val streams = listOf(
                        ControlTool(Ic.mic, "Mic", null, on) { open({ true }, "Stream the mic to", MIC_PAGE) },
                        ControlTool(Ic.videocamOutline, "Webcam", null, on) { open({ true }, "Stream the camera to", WEBCAM_PAGE) },
                        if (mirroring) {
                            ControlTool(Ic.stopScreenShare, "Stop mirror", null, true) { ScreenSession.stop() }
                        } else {
                            ControlTool(Ic.screenShare, "Mirror", null, on) {
                                picker.run(target(scope, devices), "Mirror this phone to") { d ->
                                    mirrorFor = d.id
                                    askCapture.launch(context.getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent())
                                }
                            }
                        },
                    )
                    GridRows(streams, 3) { k, m -> SmallTool(k.icon, k.label, k.enabled, m, k.onClick) }
                }
            },
            dock = { shape -> if (player != null) MediaDock(player, shape) { onOpen(Route(player.id, "media")) } },
        )
    }
}

/** A tool of a grid of Control. */
private class ControlTool(val icon: Int, val label: String, val sub: String?, val enabled: Boolean, val onClick: () -> Unit)

// ───────────────────────── Media ─────────────────────────

/**
 * The player of the computer [d] in the dock: the line of the position at
 * the top, the album art, the title, the player and the time, Play or
 * Pause, and Next. A tap on the title opens the media screen.
 */
@Composable
private fun MediaDock(d: DeviceUi, shape: DockShape, onOpen: () -> Unit) {
    val p = d.player ?: return
    val position = rememberPlayerPosition(p)
    Column(Modifier.fillMaxWidth().dockFrame(shape)) {
        Box(Modifier.fillMaxWidth().height(2.dp).background(Tn.line)) {
            if (p.length > 0) LineFill(position.toFloat() / p.length, Tn.green)
        }
        Row(
            Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                Modifier.weight(1f).clip(RoundedCornerShape(8.dp)).clickable(onClickLabel = "Open the media", role = Role.Button, onClick = onOpen),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ArtThumb(p.artUrl, 44.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    T(p.title.ifEmpty { "Unknown title" }, size = 14, weight = FontWeight.SemiBold, maxLines = 1)
                    val time = if (p.length > 0) " · ${clock(position)} / ${clock(p.length)}" else ""
                    T(p.name + time, size = 11, color = Tn.sub, family = Mono, maxLines = 1)
                }
            }
            RoundKey(if (p.playing) Ic.pause else Ic.play, if (p.playing) "Pause" else "Play", Tn.green, Tn.onAccent, 26.dp) {
                Plugins.mediaAction(FluxCore, d.id, "PlayPause")
            }
            RoundKey(Ic.next, "Next", Tn.line, Tn.text, 24.dp, enabled = p.canGoNext) { Plugins.mediaAction(FluxCore, d.id, "Next") }
        }
    }
}

/** A round key of 48 dp with an icon. */
@Composable
private fun RoundKey(
    icon: Int,
    description: String,
    fill: androidx.compose.ui.graphics.Color,
    ink: androidx.compose.ui.graphics.Color,
    iconSize: Dp,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        Modifier.size(48.dp).alpha(if (enabled) 1f else DimAlpha).clip(CircleShape).background(fill)
            .clickable(enabled = enabled, onClickLabel = description, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { Sym(icon, tint = ink, size = iconSize) }
}

/** The album art at [url] in a rounded square, or a music note while there is none. */
@Composable
internal fun ArtThumb(url: String, size: Dp, radius: Dp = 8.dp, iconSize: Dp = 22.dp) {
    val art by rememberAlbumArt(url)
    val shape = RoundedCornerShape(radius)
    Box(Modifier.size(size).clip(shape).background(Tn.tileHi), contentAlignment = Alignment.Center) {
        val image = art
        if (image != null) {
            Image(image, null, Modifier.size(size), contentScale = ContentScale.Crop)
        } else {
            Sym(Ic.music, tint = Tn.sub, size = iconSize)
        }
    }
}
