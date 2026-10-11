package org.omarchy.flux.ui

import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Shortcuts
import org.omarchy.flux.core.ShortcutsState
import org.omarchy.flux.core.WindowInfo
import org.omarchy.flux.protocol.Packet

/**
 * The Omarchy panel of 1 computer: the workspaces as pills, the windows of
 * the active workspace, and the pinned shortcuts, with the keys for the
 * focused window in the dock. The computer runs each action in Hyprland.
 * The panel sends input, so it asks for the phone lock first, like the
 * touchpad.
 */
@Composable
fun OmarchyScreen(d: DeviceUi, onBack: () -> Unit) {
    val ready = d.online && d.shortcutsSupported && d.remoteInput == true
    val unlocked = rememberRemoteUnlock(ready, "Use the Omarchy panel", "use the Omarchy panel", onBack, sample = isDemo(d.id))
    val s = d.shortcuts
    Column(Modifier.fillMaxSize()) {
        ScreenHeader("Omarchy panel", listOfNotNull(d.name, s?.active?.takeIf { it > 0 }?.let { "workspace $it" }).joinToString(" · "), onBack)
        when {
            !d.online -> Box(Modifier.padding(horizontal = TiledGutter)) { NotReachable(d, "The workspaces and the shortcuts") }
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
            else -> OmarchyBody(d, Modifier.weight(1f))
        }
    }
}

/** The workspaces, the windows, the shortcuts, and the dock of the window keys. */
@Composable
private fun OmarchyBody(d: DeviceUi, modifier: Modifier) {
    val haptic = LocalHapticFeedback.current
    val send = rememberShortcutsLink(d)
    val pins = rememberShortcutPins()
    var all by rememberSaveable { mutableStateOf(false) }
    val s = d.shortcuts
    Column(modifier.fillMaxWidth()) {
        WorkspaceStrip(s, onGo = { send(Shortcuts.workspace(it)) }) { id ->
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            send(Shortcuts.moveToWorkspace(id))
            FluxCore.toast("Moved the window to workspace $id")
        }
        ProgressLine()
        val windows = s?.activeWindows.orEmpty()
        DockLayout(
            Modifier.weight(1f).fillMaxWidth(),
            thread = { bottom ->
                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start = 10.dp, end = 10.dp, top = 6.dp, bottom = maxOf(bottom, 28.dp)),
                    verticalArrangement = Arrangement.spacedBy(TileGap),
                ) {
                    when {
                        s?.error != null -> T(s.error, Modifier.padding(horizontal = 4.dp, vertical = 8.dp), size = 13, color = Tn.red)
                        s?.loaded != true -> LineSkeleton("Reading the workspaces of ${d.name}", Modifier.padding(4.dp), lines = listOf(0.7f, 0.5f))
                    }
                    val count = if (s?.windows != null) windows.size else s?.workspaces?.firstOrNull { it.id == s.active }?.windows ?: 0
                    ListHeader("Windows", if (s?.loaded == true) "$count ${if (count == 1) "window" else "windows"}" else null)
                    when {
                        s?.loaded == true && s.windows == null -> Note("Update Flux on ${d.name} to see its windows here.")
                        s?.loaded == true && windows.isEmpty() -> Note("No windows on this workspace.")
                    }
                    for (w in windows) WindowCard(w) { if (!w.focused) send(Shortcuts.focusWindow(w.address)) }
                    ListHeader("Launch") {
                        TextAction("All shortcuts", { all = true }, size = 13, height = 18.dp, pad = 2.dp)
                    }
                    val pinned = Shortcuts.pinned(s?.shortcuts.orEmpty(), pins.pins)
                    if (s?.loaded == true && pinned.isEmpty()) Note("Pin shortcuts with the star in All shortcuts.")
                    GridRows(pinned, 2) { k, m -> LaunchTile(k.description, Shortcuts.keysLabel(k.keys), m) { send(Shortcuts.run(k)) } }
                }
            },
            dock = { shape -> WindowDock(windows.firstOrNull { it.focused }, shape, send) },
        )
    }
    if (all) {
        ShortcutSheet(
            s?.shortcuts.orEmpty(), pins.pins,
            onRun = {
                all = false
                send(Shortcuts.run(it))
            },
            onPin = pins::toggle,
            onDismiss = { all = false },
        )
    }
}

/** A line of the panel in the second ink, such as an empty list. */
@Composable
private fun Note(text: String) {
    T(text, Modifier.padding(horizontal = 4.dp, vertical = 14.dp), size = 14, color = Tn.sub, lineHeight = 1.35f)
}

/**
 * Workspaces 1 to 10 as pills that scroll to the side. The active one has
 * the accent, and a workspace with windows has a dot. A tap switches to
 * the workspace, and a long press moves the focused window there.
 */
@Composable
private fun WorkspaceStrip(state: ShortcutsState?, onGo: (Int) -> Unit, onMove: (Int) -> Unit) {
    val windows = state?.workspaces.orEmpty().associate { it.id to it.windows }
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = 10.dp, end = 10.dp, bottom = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        for (id in 1..Shortcuts.MAX_WORKSPACE) {
            val active = state?.active == id
            val used = (windows[id] ?: 0) > 0
            val shape = RoundedCornerShape(18.dp)
            Row(
                Modifier.overhang(6.dp).clip(shape)
                    .combinedClickable(
                        role = Role.Tab,
                        onClickLabel = "Switch to workspace $id",
                        onLongClickLabel = "Move the window to workspace $id",
                        onLongClick = { onMove(id) },
                    ) { onGo(id) }
                    .semantics {
                        selected = active
                        stateDescription = if (used) "Has windows" else "Empty"
                    }
                    .padding(vertical = 6.dp).height(36.dp).widthIn(min = 40.dp).clip(shape)
                    .background(if (active) Tn.accentTile else Tn.tile).border(1.dp, if (active) Tn.blue else Tn.line, shape)
                    .padding(horizontal = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                T("$id", size = 13, color = if (active) Tn.text else Tn.sub, weight = FontWeight.SemiBold, family = Mono)
                if (used) Box(Modifier.size(5.dp).clip(CircleShape).background(if (active) Tn.blue else Tn.sub))
            }
        }
    }
}

/** A window of the active workspace: the icon of its app, the app, and the title in mono. The focused window has the accent. */
@Composable
private fun WindowCard(w: WindowInfo, onClick: () -> Unit) {
    val shape = TileShape
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(shape).background(if (w.focused) Tn.accentTile else Tn.tile)
            .border(if (w.focused) 2.dp else 1.dp, if (w.focused) Tn.blue else Tn.line, shape)
            .clickable(onClickLabel = if (w.focused) null else "Focus the window", role = Role.Button, onClick = onClick)
            .semantics { if (w.focused) stateDescription = "Focused" }
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(windowIcon(w.windowClass), tint = if (w.focused) Tn.blue else Tn.sub, size = 22.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(w.app.ifEmpty { "Window" }, size = 14, weight = FontWeight.SemiBold, maxLines = 1)
            if (w.title.isNotEmpty()) T(w.title, size = 11, color = Tn.sub, family = Mono, maxLines = 1)
        }
        if (w.focused) T("Focused", Modifier.clearAndSetSemantics {}, size = 12, color = Tn.blue, weight = FontWeight.Medium)
    }
}

/** The icon of the app of a window, from its class. */
@DrawableRes
internal fun windowIcon(windowClass: String): Int {
    val c = windowClass.lowercase()
    fun has(vararg names: String) = names.any { it in c }
    return when {
        has("alacritty", "kitty", "ghostty", "foot", "wezterm", "konsole", "terminal") -> Ic.terminal
        has("chrom", "firefox", "brave", "zen", "vivaldi", "librewolf", "edge", "qutebrowser", "browser") -> Ic.web
        has("spotify", "music", "rhythmbox", "amberol") -> Ic.music
        has("obsidian", "typora", "notes", "logseq", "xournal") -> Ic.notes
        has("signal", "telegram", "discord", "slack", "whatsapp", "element", "chat") -> Ic.chat
        has("nautilus", "thunar", "dolphin", "files", "nemo") -> Ic.folderOpen
        has("code", "zed", "cursor", "neovide", "jetbrains", "studio") -> Ic.codeFile
        has("mpv", "vlc", "obs", "celluloid") -> Ic.movie
        has("imv", "gimp", "krita", "pinta", "inkscape") -> Ic.image
        else -> Ic.window
    }
}

/** A pinned shortcut: its description and its keys in mono. */
@Composable
private fun LaunchTile(label: String, keys: String, modifier: Modifier, onClick: () -> Unit) {
    Tile(
        modifier.heightIn(min = 56.dp), onClick, padding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        T(label, size = 14, weight = FontWeight.SemiBold)
        if (keys.isNotEmpty()) T(keys, size = 11, color = Tn.sub, family = Mono)
    }
}

/**
 * The keys for the focused window: the arrows focus the window in that
 * direction, and a long press swaps the window there. Under them, close,
 * full screen, float, and split.
 */
@Composable
private fun WindowDock(focused: WindowInfo?, shape: DockShape, send: (Packet) -> Unit) {
    Column(
        Modifier.fillMaxWidth().dockFrame(shape).padding(start = 12.dp, end = 12.dp, top = 14.dp, bottom = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(Modifier.padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            T("Window", size = 12, color = Tn.sub, weight = FontWeight.Medium)
            val title = focused?.let { listOf(it.app, it.title).filter { p -> p.isNotEmpty() }.joinToString(" · ") } ?: "tap an arrow to focus a window"
            T("· $title", Modifier.weight(1f, fill = false), size = 11, color = Tn.sub, family = Mono, maxLines = 1)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (dir in listOf(Shortcuts.Direction.Left, Shortcuts.Direction.Up, Shortcuts.Direction.Down, Shortcuts.Direction.Right)) {
                val name = dir.name.lowercase()
                DockKey(
                    "Focus the window $name. Hold to move the window $name.", Modifier.weight(1f).height(44.dp), border = Tn.line, radius = 10.dp,
                    onLongClick = { send(Shortcuts.swap(dir)) },
                    onClick = { send(Shortcuts.focus(dir)) },
                ) { Sym(arrowIcon(dir), tint = Tn.text, size = 16.dp) }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for ((label, description, action) in WindowActions) {
                val red = action == Shortcuts.Action.Close
                DockKey(description, Modifier.weight(1f).height(44.dp), border = if (red) Tn.red else Tn.line, radius = 10.dp, onClick = { send(Shortcuts.action(action)) }) {
                    T(label, size = 13, color = if (red) Tn.red else Tn.text, weight = FontWeight.Medium, family = Mono)
                }
            }
        }
    }
}

/** The icon of an arrow key. */
@DrawableRes
private fun arrowIcon(dir: Shortcuts.Direction): Int = when (dir) {
    Shortcuts.Direction.Left -> Ic.back
    Shortcuts.Direction.Up -> Ic.up
    Shortcuts.Direction.Down -> Ic.down
    Shortcuts.Direction.Right -> Ic.forward
}

/** The actions of the dock: the label, the label for TalkBack, and the action. */
private val WindowActions = listOf(
    Triple("close", "Close the window", Shortcuts.Action.Close),
    Triple("full", "Full screen", Shortcuts.Action.Fullscreen),
    Triple("float", "Float or tile the window", Shortcuts.Action.Float),
    Triple("split", "Toggle the split", Shortcuts.Action.Split),
)
