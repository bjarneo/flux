package org.omarchy.flux.ui

import android.app.Activity
import android.media.projection.MediaProjectionManager
import android.content.res.Configuration
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.heightIn
import org.omarchy.flux.core.LinkNote
import org.omarchy.flux.core.RemoteGroup
import org.omarchy.flux.core.RemoteRow
import org.omarchy.flux.core.RemoteTool
import org.omarchy.flux.core.SpeakerState
import org.omarchy.flux.core.inGroup
import org.omarchy.flux.core.remoteComputer
import org.omarchy.flux.core.remoteRows
import org.omarchy.flux.speaker.SpeakerSession
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
 * streams of this phone, as rows in the groups See, Use, and Share. It
 * holds no agents. They live in Chats. A row shows when a computer in scope
 * has the feature, and it is dimmed while no such computer is online. With
 * more than 1 computer online, a tap asks for the computer. The dock shows
 * the player of the computer. A tablet in landscape shows the groups side
 * by side. In portrait it shows the layout of a phone.
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
    val devices = state.devices
    val any = target(scope, devices)
    // Before the first pairing, all rows show, dimmed, so that the destination shows what it holds.
    val none = devices.none { it.paired }
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
    val speaker by SpeakerSession.status.collectAsState()
    val speakerState = when (speaker.phase) {
        SpeakerSession.Phase.Live -> SpeakerState.Live
        SpeakerSession.Phase.Connecting -> SpeakerState.Connecting
        SpeakerSession.Phase.Error -> SpeakerState.Failed
        SpeakerSession.Phase.Idle -> SpeakerState.Off
    }
    val rows = remoteRows(devices, scope, screen.active, speakerState)

    fun tap(tool: RemoteTool) {
        when (tool) {
            RemoteTool.Panel -> open({ it.shortcutsSupported }, "Open the Omarchy panel of", OMARCHY_PAGE)
            // Remote input can type in any window of the computer, so it asks for the phone lock first.
            RemoteTool.Touchpad -> open({ it.inputSupported }, "Use the touchpad of", "touchpad", "Use the touchpad" to "use the touchpad")
            // The screen of the computer can show private content, so it also asks for the phone lock first.
            RemoteTool.Desktop -> open({ it.desktopSupported }, "Show the screen of", "desktop", "Show the computer screen" to "show the computer screen")
            // The computer adds a monitor that this phone or tablet shows. It uses the switch and the phone lock of the remote desktop.
            RemoteTool.Extend -> open({ it.extendSupported }, "Extend the screen of", EXTEND_PAGE, "Extend the computer screen" to "extend the computer screen")
            RemoteTool.Commands -> open({ true }, "Run the commands of", "commands")
            RemoteTool.Media -> open({ true }, "Open the media of", "media")
            RemoteTool.Mic -> open({ true }, "Stream the mic to", MIC_PAGE)
            RemoteTool.Webcam -> open({ true }, "Stream the camera to", WEBCAM_PAGE)
            RemoteTool.Mirror -> if (screen.active) {
                ScreenSession.stop()
            } else {
                picker.run(target(scope, devices), "Mirror this phone to") { d ->
                    mirrorFor = d.id
                    askCapture.launch(context.getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent())
                }
            }
            // A tap while the audio runs or connects stops it.
            RemoteTool.Speaker -> if (speaker.active) {
                SpeakerSession.stop(FluxCore, notify = true)
            } else {
                picker.run(target(scope, devices) { it.speakerSupported }, "Play the audio of") { d -> SpeakerSession.start(FluxCore, d.id) }
            }
        }
    }

    val scoped = devices.filter { it.paired && it.online && (scope == null || it.id == scope) }
    // The dock plays the computer in scope, or the first computer that plays.
    val player = scoped.filter { it.player != null }.let { l -> l.firstOrNull { it.player?.playing == true } ?: l.firstOrNull() }
    val side = rememberWideWindow()
    val computer = remoteComputer(devices, scope)

    Column(Modifier.fillMaxSize()) {
        Box(Modifier.statusBarsPadding()) {
            ScreenHeader("Remote", onlineText(devices))
        }
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(start = TiledGutter, end = TiledGutter, top = 6.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(TileGap),
        ) {
            if (none) {
                TargetLine(any, devices, "Acts on", onPair)
            } else {
                ComputerRow(computer, devices, scope, onScope, onUnpair)
            }
            val columns = if (!side) 1 else 2
            if (columns == 1) {
                for (g in RemoteGroup.entries) RemoteGroupCard(g, rows, Modifier.fillMaxWidth(), ::tap)
            } else {
                // The columns keep the order See, Use, Share. The last group fills the right column.
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(TileGap)) {
                        RemoteGroupCard(RemoteGroup.See, rows, Modifier.fillMaxWidth(), ::tap)
                        RemoteGroupCard(RemoteGroup.Use, rows, Modifier.fillMaxWidth(), ::tap)
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(TileGap)) {
                        RemoteGroupCard(RemoteGroup.Share, rows, Modifier.fillMaxWidth(), ::tap)
                    }
                }
            }
        }
        if (player != null) {
            val shape = if (side) DockShape.Tile else DockShape.Bottom
            Box(if (side) Modifier.padding(start = TiledGutter, end = TiledGutter, bottom = 8.dp) else Modifier) {
                MediaDock(player, shape) { onOpen(Route(player.id, "media")) }
            }
        }
    }
}

/** The icon of a row. */
private fun remoteIcon(tool: RemoteTool): Int = when (tool) {
    RemoteTool.Desktop -> Ic.desktop
    RemoteTool.Extend -> Ic.devices
    RemoteTool.Panel -> Ic.grid
    RemoteTool.Touchpad -> Ic.touchApp
    RemoteTool.Commands -> Ic.terminal
    RemoteTool.Media -> Ic.music
    RemoteTool.Webcam -> Ic.videocamOutline
    RemoteTool.Mic -> Ic.mic
    RemoteTool.Mirror -> Ic.screenShare
    RemoteTool.Speaker -> Ic.speakerPhone
}

/** A group of rows under its title. It draws nothing when the group has no row. */
@Composable
private fun RemoteGroupCard(group: RemoteGroup, rows: List<RemoteRow>, modifier: Modifier, onTap: (RemoteTool) -> Unit) {
    val list = rows.inGroup(group)
    if (list.isEmpty()) return
    Column(modifier) {
        ListHeader(group.title)
        Column(Modifier.padding(top = 4.dp).fillMaxWidth().clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)) {
            list.forEachIndexed { i, r ->
                if (i > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(Tn.line))
                RemoteRowView(r) { onTap(r.tool) }
            }
        }
    }
}

/** A row: the icon, the label, the state line, and a chevron. A row that is not enabled shows dimmed and takes no tap. */
@Composable
private fun RemoteRowView(r: RemoteRow, onClick: () -> Unit) {
    val icon = if (r.label == "Stop mirror") Ic.stopScreenShare else remoteIcon(r.tool)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).alpha(if (r.enabled) 1f else DimAlpha)
            .clickable(enabled = r.enabled, role = Role.Button, onClick = onClick)
            .padding(start = 14.dp, end = 12.dp, top = 8.dp, bottom = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(icon, tint = Tn.blue, size = 22.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(r.label, size = 15, weight = FontWeight.SemiBold)
            if (!r.line.isNullOrEmpty()) T(r.line, size = 12, color = Tn.sub, lineHeight = 1.3f)
        }
        Sym(Ic.chevron, tint = Tn.sub, size = 20.dp)
    }
}

/**
 * The row under the header: the computer and its state. A computer that
 * is reachable says Connected, and a tap opens Computers. A computer that
 * is not reachable says `Not reachable since HH:MM`, with Wake when it can
 * wake. With all computers in scope, the row counts the computers that are
 * online.
 */
@Composable
private fun ComputerRow(d: DeviceUi?, devices: List<DeviceUi>, scope: String?, onScope: (String?) -> Unit, onUnpair: (DeviceUi) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val paired = devices.filter { it.paired }
    if (paired.isEmpty()) return
    val shape = TileShape
    val offline = d != null && !d.online
    val name = d?.name ?: "All computers"
    val line = when {
        d == null -> onlineText(devices)
        d.online -> "Connected"
        else -> LinkNote.rowLine(false, d.lastSeen) { timeText(context, it) }.orEmpty()
    }
    val shown = (if (d != null) listOf(d) else paired).take(4)
    Box {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(shape).background(Tn.tile)
                .border(if (offline) 2.dp else 1.dp, if (offline) Tn.orange else Tn.line, shape)
                .clickable(onClickLabel = "Change the scope", role = Role.DropdownList) { menu = true }
                .semantics(mergeDescendants = true) { }
                .padding(start = 14.dp, end = if (offline && d?.canWake == true) 8.dp else 12.dp, top = 6.dp, bottom = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // One link dot for each computer in scope, up to 4, as the scope chip draws them.
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                for (c in shown) LinkDot(c.online, 8.dp)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(name, size = 15, weight = FontWeight.SemiBold, maxLines = 1)
                if (line.isNotEmpty()) T(line, size = 13, color = Tn.sub, maxLines = 1)
            }
            if (offline && d?.canWake == true) {
                Box(
                    Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp))
                        .clickable(onClickLabel = "Wake ${d.name}", role = Role.Button) { FluxCore.wake(d.id) }
                        .padding(vertical = 6.dp).heightIn(min = 36.dp).clip(RoundedCornerShape(12.dp)).background(Tn.line)
                        .padding(horizontal = 16.dp),
                    contentAlignment = Alignment.Center,
                ) { T("Wake", size = 13, weight = FontWeight.SemiBold, maxLines = 1) }
            } else {
                Sym(Ic.expand, tint = Tn.sub, size = 20.dp)
            }
        }
        ScopeMenu(menu, { menu = false }, devices, scope, onScope, onUnpair)
    }
}

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
