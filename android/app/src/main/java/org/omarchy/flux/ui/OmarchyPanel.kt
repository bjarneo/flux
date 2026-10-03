package org.omarchy.flux.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.RemoteInput
import org.omarchy.flux.core.Shortcut
import org.omarchy.flux.core.Shortcuts
import org.omarchy.flux.core.ShortcutsState
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.voice.DictationText
import org.omarchy.flux.voice.VoiceField
import org.omarchy.flux.voice.rememberVoiceTyping

/** The panel reads the workspaces again at this interval, because the computer can change them too. */
private const val REFRESH_MS = 3_000L

/** The least height of a key of the panel. A key grows with the font size. */
private val KeyHeight = 48.dp

/**
 * The Omarchy panel: move between workspaces and windows, and start the
 * shortcuts of the computer. The computer runs each action in Hyprland, so
 * the Omarchy key bindings work also where keys from the phone do not.
 */
@Composable
fun OmarchyPanel(d: DeviceUi, modifier: Modifier = Modifier) {
    val haptic = LocalHapticFeedback.current
    fun send(p: Packet) {
        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
        if (!RemoteInput.send(FluxCore, d.id, p)) FluxCore.toast("${d.name} is not reachable")
    }
    // The list comes once. The workspaces come again while the panel is visible.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(d.id) {
        RemoteInput.send(FluxCore, d.id, Shortcuts.request())
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                delay(REFRESH_MS)
                RemoteInput.send(FluxCore, d.id, Shortcuts.refresh())
            }
        }
    }
    val state = d.shortcuts
    var all by rememberSaveable { mutableStateOf(false) }
    var pins by remember { mutableStateOf(FluxCore.settings.pinnedShortcuts ?: Shortcuts.DEFAULT_PINS) }
    fun togglePin(s: Shortcut) {
        pins = if (s.description in pins) pins - s.description else pins + s.description
        FluxCore.settings.pinnedShortcuts = pins
    }

    Column(modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(TileGap)) {
        when {
            !d.shortcutsSupported -> T("Update Flux on ${d.name} to move around Omarchy from here.", size = 13, color = Tn.sub)
            state?.error != null -> T(state.error, size = 13, color = Tn.red)
            state?.loaded != true -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Spinner(Modifier.size(14.dp), color = Tn.blue)
                T("Reading the shortcuts of ${d.name}", size = 13, color = Tn.sub)
            }
        }
        TileLabel("Workspaces · hold to move the window")
        Workspaces(state, onGo = { send(Shortcuts.workspace(it)) }) { id ->
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            send(Shortcuts.moveToWorkspace(id))
            FluxCore.toast("Moved the window to workspace $id")
        }

        var move by rememberSaveable { mutableStateOf(false) }
        TileLabel(if (move) "Window · the arrows move it" else "Window · the arrows focus")
        Row(horizontalArrangement = Arrangement.spacedBy(TileGap)) {
            DirectionPad(move, Modifier.weight(1f), onToggle = { move = !move }) { dir ->
                send(if (move) Shortcuts.swap(dir) else Shortcuts.focus(dir))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(TileGap)) {
                Row(horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                    ActionKey("close", "Close the window", Modifier.weight(1f), destructive = true) { send(Shortcuts.action(Shortcuts.Action.Close)) }
                    ActionKey("full", "Full screen", Modifier.weight(1f)) { send(Shortcuts.action(Shortcuts.Action.Fullscreen)) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                    ActionKey("float", "Float or tile the window", Modifier.weight(1f)) { send(Shortcuts.action(Shortcuts.Action.Float)) }
                    ActionKey("split", "Toggle the split", Modifier.weight(1f)) { send(Shortcuts.action(Shortcuts.Action.Split)) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                    ActionKey("next", "Focus the next window", Modifier.weight(1f)) { send(Shortcuts.action(Shortcuts.Action.NextWindow)) }
                    ActionKey("scratch", "Toggle the scratchpad", Modifier.weight(1f)) { send(Shortcuts.action(Shortcuts.Action.Scratchpad)) }
                }
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            TileLabel("Launch", Modifier.weight(1f))
            FluxButton("All shortcuts", { all = true }, kind = ButtonKind.Text)
        }
        val pinned = Shortcuts.pinned(state?.shortcuts.orEmpty(), pins)
        if (state?.loaded == true && pinned.isEmpty()) {
            T("Pin shortcuts with the star in All shortcuts.", size = 13, color = Tn.sub)
        }
        for (row in pinned.chunked(2)) {
            TileRow(52.dp, gap = 6.dp) {
                for (s in row) LaunchKey(s, Modifier.weight(1f).fillMaxHeight()) { send(Shortcuts.run(s)) }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
    if (all) {
        ShortcutSheet(
            state?.shortcuts.orEmpty(), pins,
            onRun = {
                all = false
                send(Shortcuts.run(it))
            },
            onPin = ::togglePin,
            onDismiss = { all = false },
        )
    }
}

/** Workspaces 1 to 10 in 2 rows. The active one is filled, and a workspace with windows has a dot. */
@Composable
private fun Workspaces(state: ShortcutsState?, onGo: (Int) -> Unit, onMove: (Int) -> Unit) {
    val windows = state?.workspaces.orEmpty().associate { it.id to it.windows }
    Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
        for (row in (1..Shortcuts.MAX_WORKSPACE).chunked(5)) {
            Row(horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                for (id in row) {
                    val active = state?.active == id
                    val used = (windows[id] ?: 0) > 0
                    val shape = RoundedCornerShape(8.dp)
                    Box(
                        Modifier.weight(1f).heightIn(min = KeyHeight).clip(shape)
                            .background(if (active) Tn.blue else Tn.tile)
                            .border(1.dp, if (active) Tn.blue else Tn.line, shape)
                            .combinedClickable(
                                role = Role.Button,
                                onClickLabel = "Switch to workspace $id",
                                onLongClickLabel = "Move the window to workspace $id",
                                onLongClick = { onMove(id) },
                            ) { onGo(id) },
                        contentAlignment = Alignment.Center,
                    ) {
                        KeyLabel(
                            "$id",
                            when {
                                active -> Tn.onAccent
                                used -> Tn.text
                                else -> Tn.sub
                            },
                            size = 14,
                        )
                        if (used && !active) {
                            Box(Modifier.align(Alignment.BottomCenter).padding(bottom = 4.dp).size(4.dp).clip(CircleShape).background(Tn.blue))
                        }
                    }
                }
            }
        }
    }
}

/**
 * The arrows for the windows: they focus a window, or with [move] they
 * swap the window. The key in the middle switches between the 2, and
 * TalkBack reads it as a switch.
 */
@Composable
private fun DirectionPad(move: Boolean, modifier: Modifier, onToggle: () -> Unit, onDirection: (Shortcuts.Direction) -> Unit) {
    val accent = Tn.blue
    Column(modifier, verticalArrangement = Arrangement.spacedBy(TileGap)) {
        Row(horizontalArrangement = Arrangement.spacedBy(TileGap)) {
            Spacer(Modifier.weight(1f))
            ArrowKey(Shortcuts.Direction.Up, accent, move, Modifier.weight(1f), onDirection)
            Spacer(Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(TileGap)) {
            ArrowKey(Shortcuts.Direction.Left, accent, move, Modifier.weight(1f), onDirection)
            val shape = RoundedCornerShape(8.dp)
            Box(
                Modifier.weight(1f).heightIn(min = KeyHeight).clip(shape).background(Tn.accentTile).border(1.dp, accent, shape)
                    .toggleable(value = move, role = Role.Switch, onValueChange = { onToggle() })
                    .clearAndSetSemantics { contentDescription = "The arrows move the window" }
                    .padding(horizontal = 4.dp),
                contentAlignment = Alignment.Center,
            ) { KeyLabel(if (move) "move" else "focus", accent, size = 11) }
            ArrowKey(Shortcuts.Direction.Right, accent, move, Modifier.weight(1f), onDirection)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(TileGap)) {
            Spacer(Modifier.weight(1f))
            ArrowKey(Shortcuts.Direction.Down, accent, move, Modifier.weight(1f), onDirection)
            Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
private fun ArrowKey(dir: Shortcuts.Direction, accent: Color, move: Boolean, modifier: Modifier, onDirection: (Shortcuts.Direction) -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    val description = (if (move) "Move the window " else "Focus the window ") + dir.name.lowercase()
    Box(
        modifier.heightIn(min = KeyHeight).clip(shape).background(Tn.tile).border(1.dp, Tn.line, shape)
            .clickable(onClickLabel = description, role = Role.Button) { onDirection(dir) }
            .clearAndSetSemantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { KeyLabel(dir.label, accent, size = 15, family = FontFamily.Default) }
}

/** A window action, with a mono label. A [destructive] action has a red label and border. TalkBack reads [description]. */
@Composable
private fun ActionKey(label: String, description: String, modifier: Modifier, destructive: Boolean = false, onClick: () -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    Box(
        modifier.heightIn(min = KeyHeight).clip(shape).background(Tn.tile).border(1.dp, if (destructive) Tn.red else Tn.line, shape)
            .clickable(onClickLabel = description, role = Role.Button, onClick = onClick)
            .clearAndSetSemantics { contentDescription = description }
            .padding(horizontal = 4.dp),
        contentAlignment = Alignment.Center,
    ) { KeyLabel(label, if (destructive) Tn.red else Tn.sub) }
}

/** A pinned shortcut: its description and its keys. */
@Composable
private fun LaunchKey(s: Shortcut, modifier: Modifier, onClick: () -> Unit) {
    Tile(modifier.heightIn(min = 52.dp), onClick, padding = PaddingValues(horizontal = 10.dp, vertical = 6.dp)) {
        T(s.description, size = 13, weight = FontWeight.SemiBold)
        T(Shortcuts.keysLabel(s.keys), size = 11, color = Tn.sub, family = Mono)
    }
}

/**
 * All shortcuts of the computer, with a search. A tap runs a shortcut. The
 * star pins it to the panel. A dictation replaces the search.
 */
@Composable
private fun ShortcutSheet(all: List<Shortcut>, pins: List<String>, onRun: (Shortcut) -> Unit, onPin: (Shortcut) -> Unit, onDismiss: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    val voice = rememberVoiceTyping { query = DictationText.query(it) }
    FluxSheet(onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = TiledGutter), verticalArrangement = Arrangement.spacedBy(TileGap)) {
            TileLabel("All shortcuts · ${all.size}", Modifier.semantics { heading() })
            VoiceField(voice) { m ->
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    modifier = m,
                    placeholder = { T("Search, for example workspace or browser", color = Tn.sub) },
                    leadingIcon = { Sym(Ic.search, tint = Tn.sub, size = 20.dp) },
                    trailingIcon = if (query.isEmpty()) null else { { ClearKey({ query = "" }, "Clear the search") } },
                    singleLine = true,
                    textStyle = TextStyle(color = Tn.text, fontSize = 14.sp),
                    shape = TileShape,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                )
            }
            val found = remember(all, query) { Shortcuts.search(all, query) }
            LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false), verticalArrangement = Arrangement.spacedBy(TileGap)) {
                items(found, key = { it.ref }) { s ->
                    val pinned = s.description in pins
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(RoundedCornerShape(8.dp)).background(Tn.tile)
                            .clickable(onClickLabel = "Run ${s.description}", role = Role.Button) { onRun(s) }
                            .padding(start = 12.dp, top = 4.dp, bottom = 4.dp, end = 0.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            T(s.description, size = 14, weight = FontWeight.SemiBold)
                            if (s.keys.isNotEmpty()) T(Shortcuts.keysLabel(s.keys), size = 12, color = Tn.sub, family = Mono)
                        }
                        // The star pins the shortcut to the panel. TalkBack reads it as a switch.
                        Box(
                            Modifier.size(48.dp).clip(RoundedCornerShape(8.dp))
                                .toggleable(value = pinned, role = Role.Switch, onValueChange = { onPin(s) })
                                .semantics { contentDescription = "Pin ${s.description}" },
                            contentAlignment = Alignment.Center,
                        ) { Sym(if (pinned) Ic.starFill else Ic.star, tint = if (pinned) Tn.yellow else Tn.sub, size = 22.dp) }
                    }
                }
                item { Spacer(Modifier.height(24.dp)) }
            }
        }
    }
}
