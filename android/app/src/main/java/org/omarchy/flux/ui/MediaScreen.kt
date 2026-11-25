package org.omarchy.flux.ui

import android.os.SystemClock
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Switch
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import org.omarchy.flux.core.AudioOutput
import org.omarchy.flux.core.AudioOutputsSync
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.PlayerState
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.core.StreamKind
import org.omarchy.flux.speaker.SpeakerSession
import org.omarchy.flux.speaker.SpeakerSettings

/**
 * The player of 1 computer: the players as pills, the album art, the
 * title, the artist, and the album, and the dock with the position,
 * Previous, Play or Pause, Next, and the volume. A player that sends no
 * volume shows no volume row. The dock also shows the audio output of the
 * computer, which opens the audio sheet, and Play on phone.
 */
@Composable
fun TiledMediaScreen(d: DeviceUi, onBack: () -> Unit) {
    val p = d.player
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(d.id, d.online) {
        if (!d.online) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                Plugins.requestPlayers(FluxCore, d.id)
                AudioOutputsSync.request(FluxCore, d.id)
                delay(10_000)
            }
        }
    }
    var outputs by remember { mutableStateOf(false) }
    // The dock shows also when nothing plays, because the outputs and Play on phone are in it.
    val audio = d.outputsSupported || d.speakerSupported
    // A tap on Play on phone in a request of the computer starts the audio here.
    val startNow = rememberStreamStart(d.id, StreamKind.Speaker)
    StartAfterTap(startNow, ready = d.online && d.speakerSupported, StreamKind.Speaker) {
        if (!SpeakerSession.runsTo(d.id)) SpeakerSession.start(FluxCore, d.id)
    }
    // The position that the user drags to, until the drag ends.
    var dragging by remember { mutableStateOf<Float?>(null) }
    val position = if (p != null) rememberPlayerPosition(p) else 0L
    val shown = dragging?.let { (it * (p?.length ?: 0)).toLong() } ?: position
    Column(Modifier.fillMaxSize()) {
        ScreenHeader("Media", listOfNotNull(p?.name, d.name).joinToString(" · "), onBack)
        if (p != null && d.players.size > 1) {
            PillStrip {
                for (name in d.players) {
                    val on = name == p.name
                    Pill(
                        name, on,
                        onClick = { if (!on) Plugins.selectPlayer(FluxCore, d.id, name) },
                        meta = if (on) (if (p.playing) "playing" else "paused") else "",
                        clickLabel = "Show $name",
                        state = if (on) "Shown" else null,
                    ) { if (on && p.playing) Dot(Tn.green, 8.dp) else RingMark() }
                }
            }
        }
        ProgressLine { if (p != null && p.length > 0) LineFill(shown.toFloat() / p.length, Tn.green) }
        when {
            !d.online -> Box(Modifier.padding(horizontal = TiledGutter)) { NotReachable(d, "The player controls") }
            p == null && !audio -> NothingPlays(d)
            else -> DockLayout(
                Modifier.weight(1f).fillMaxWidth(),
                thread = { bottom -> if (p != null) NowPlaying(p, bottom) else NothingPlays(d) },
                dock = { shape ->
                    PlayerDock(d, p, shown, shape, onDrag = { dragging = it }, onOutputs = { outputs = true }, onSeek = { f ->
                        dragging = null
                        if (p != null) Plugins.seek(FluxCore, d.id, (f * p.length).toLong())
                    })
                },
            )
        }
    }
    if (outputs && d.online && audio) OutputsSheet(d) { outputs = false }
}

/** The text of a computer that plays nothing. */
@Composable
private fun NothingPlays(d: DeviceUi) {
    EmptyState(Ic.music, "Nothing is playing", "Play music or a video on ${d.name}. The controls show here.", Modifier.padding(top = 48.dp))
}

/** The position of [p] in milliseconds now. It moves each half second while the player plays. */
@Composable
internal fun rememberPlayerPosition(p: PlayerState): Long {
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(p.playing, p.updatedAt) {
        now = SystemClock.elapsedRealtime()
        if (!p.playing) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                now = SystemClock.elapsedRealtime()
                delay(500)
            }
        }
    }
    return if (p.playing) (p.position + (now - p.updatedAt)).coerceIn(0, maxOf(p.length, 0)) else p.position
}

/** The album art, the title, the artist, and the album, at the bottom of the space above the dock. */
@Composable
private fun NowPlaying(p: PlayerState, bottom: Dp) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).heightIn(min = maxHeight)
                .padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = maxOf(bottom, 30.dp)),
            verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.Bottom),
        ) {
            val art by rememberAlbumArt(p.artUrl)
            val shape = RoundedCornerShape(16.dp)
            Box(
                Modifier.align(Alignment.CenterHorizontally).widthIn(max = 230.dp).fillMaxWidth().aspectRatio(1f)
                    .clip(shape).background(Tn.tile).border(1.dp, Tn.line, shape),
                contentAlignment = Alignment.Center,
            ) {
                val image = art
                if (image != null) Image(image, "Album art", Modifier.fillMaxSize(), contentScale = ContentScale.Crop) else Sym(Ic.music, tint = Tn.dim, size = 48.dp)
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                LineText(p.title.ifEmpty { "Unknown title" }, size = 24f, lineHeight = 1.2f, weight = FontWeight.SemiBold)
                if (p.artist.isNotEmpty()) T(p.artist, size = 15, color = Tn.sub)
                if (p.album.isNotEmpty()) T(p.album, size = 12, color = Tn.sub, family = Mono)
            }
        }
    }
}

/**
 * The dock of the player: the position with a thumb, the time and the
 * length, Previous, Play or Pause, and Next, and the volume. [onDrag]
 * follows a drag of the position, and [onSeek] gets the part of the length
 * at the end of a tap or a drag. Without a player [p], the dock shows only
 * the audio row. [onOutputs] opens the list of the outputs.
 */
@Composable
private fun PlayerDock(
    d: DeviceUi,
    p: PlayerState?,
    position: Long,
    shape: DockShape,
    onDrag: (Float) -> Unit,
    onOutputs: () -> Unit,
    onSeek: (Float) -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().dockFrame(shape).padding(start = 12.dp, end = 12.dp, top = 16.dp, bottom = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (p != null) PlayerControls(d, p, position, onDrag, onSeek)
        if (d.outputsSupported || d.speakerSupported) AudioRow(d, onOutputs)
    }
}

/** The position, Previous, Play or Pause, Next, and the volume of the player [p]. */
@Composable
private fun PlayerControls(d: DeviceUi, p: PlayerState, position: Long, onDrag: (Float) -> Unit, onSeek: (Float) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (p.length > 0) {
            Column(Modifier.padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                LineSlider(
                    position.toFloat() / p.length, Tn.green, "Position", clock(position),
                    Modifier.height(24.dp), thumb = p.canSeek, enabled = p.canSeek, onChange = onDrag, onDone = onSeek,
                )
                Row(Modifier.fillMaxWidth()) {
                    T(clock(position), Modifier.weight(1f), size = 11, color = Tn.sub, family = Mono)
                    T(clock(p.length), size = 11, color = Tn.sub, family = Mono)
                }
            }
        }
        Row(Modifier.fillMaxWidth().height(64.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PlayerKey(Ic.previous, "Previous", Tn.line, Tn.text, 30.dp, Modifier.weight(1f), p.canGoPrevious) { Plugins.mediaAction(FluxCore, d.id, "Previous") }
            PlayerKey(if (p.playing) Ic.pause else Ic.play, if (p.playing) "Pause" else "Play", Tn.green, Tn.onAccent, 34.dp, Modifier.weight(1.4f)) {
                Plugins.mediaAction(FluxCore, d.id, "PlayPause")
            }
            PlayerKey(Ic.next, "Next", Tn.line, Tn.text, 30.dp, Modifier.weight(1f), p.canGoNext) { Plugins.mediaAction(FluxCore, d.id, "Next") }
        }
        // Only a player that takes a volume sends one. Chromium, for example, does not.
        val volume = p.volume
        if (volume != null) VolumeRow(d, volume)
    }
}

/** A key of the player dock: a rounded tile with an icon. A key that the player does not offer shows dimmed. */
@Composable
private fun PlayerKey(icon: Int, description: String, fill: Color, ink: Color, iconSize: Dp, modifier: Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val shape = RoundedCornerShape(16.dp)
    Box(
        modifier.fillMaxHeight().alpha(if (enabled) 1f else DimAlpha).clip(shape).background(fill)
            .clickable(enabled = enabled, onClickLabel = description, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { Sym(icon, tint = ink, size = iconSize) }
}

/** The volume of the player: the icon, a line to tap or drag, and the value. */
@Composable
private fun VolumeRow(d: DeviceUi, volume: Int) {
    Row(
        Modifier.fillMaxWidth().height(40.dp).padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(Ic.volumeDown, tint = Tn.sub, size = 20.dp)
        VolumeLine(volume, "Volume", muted = false, Modifier.weight(1f)) { Plugins.setVolume(FluxCore, d.id, it) }
    }
}

/**
 * A volume from 0 to 100: a line to tap or drag, and the value in percent.
 * A [muted] volume shows its line in `sub`. [onSet] gets the volume at
 * most each 150 ms during a drag, and at the end of a tap or a drag.
 */
@Composable
private fun VolumeLine(volume: Int, label: String, muted: Boolean, modifier: Modifier, onSet: (Int) -> Unit) {
    var drag by remember { mutableStateOf<Float?>(null) }
    var sentAt by remember { mutableLongStateOf(0L) }
    val shown = drag?.let { (it * 100).roundToInt() } ?: volume
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        LineSlider(
            shown / 100f, if (muted) Tn.sub else Tn.text, label, if (muted) "Muted, $shown%" else "$shown%",
            Modifier.weight(1f).height(32.dp), thumb = false,
            onChange = {
                drag = it
                val now = SystemClock.elapsedRealtime()
                if (now - sentAt >= 150) {
                    sentAt = now
                    onSet((it * 100).roundToInt())
                }
            },
            onDone = {
                onSet((it * 100).roundToInt())
                drag = null
            },
        )
        T("$shown%", Modifier.widthIn(min = 34.dp), size = 11, color = Tn.sub, family = Mono, align = TextAlign.End)
    }
}

// ───────────────────────── Audio outputs ─────────────────────────

/**
 * The audio row at the bottom of the dock: the default output of the
 * computer, which opens the list of the outputs, and Play on phone.
 */
@Composable
private fun AudioRow(d: DeviceUi, onOutputs: () -> Unit) {
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (d.outputsSupported) OutputKey(d, Modifier.weight(1f), onOutputs)
        if (d.speakerSupported) SpeakerKey(d, Modifier.weight(1f), onOutputs)
    }
}

/**
 * Play on phone: a tap starts the audio of the computer on this phone, and
 * a tap while it plays stops it. The line under the label tells the state.
 * A long press opens the sheet with the mute choice.
 */
@Composable
private fun SpeakerKey(d: DeviceUi, modifier: Modifier, onSettings: () -> Unit) {
    val status by SpeakerSession.status.collectAsState()
    val mine = status.deviceId == d.id
    val active = mine && status.active
    val live = mine && status.phase == SpeakerSession.Phase.Live
    val label = if (live) "Plays on phone" else "Play on phone"
    val line = when {
        live && status.muted.isNotEmpty() -> "Live · ${d.name} muted"
        live -> "Live"
        active -> "Connecting…"
        mine && status.phase == SpeakerSession.Phase.Error -> "Failed · tap to try again"
        else -> "Off"
    }
    val description = when {
        live -> "Stop the audio of ${d.name} on this phone"
        active -> "Stop the connection to ${d.name}"
        else -> "Play the audio of ${d.name} on this phone"
    }
    AudioKey(Ic.speakerPhone, label, line, description, modifier, tint = if (live) Tn.green else Tn.blue, onLongClick = onSettings) {
        if (active) SpeakerSession.stop(FluxCore, notify = true) else SpeakerSession.start(FluxCore, d.id)
    }
}

/** A key of the audio row: an icon, a label, and a line in mono under it. */
@Composable
private fun AudioKey(
    icon: Int,
    label: String,
    line: String,
    description: String,
    modifier: Modifier,
    tint: Color = Tn.blue,
    onLongClick: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    DockKey(description, modifier.fillMaxHeight().heightIn(min = 56.dp), border = Tn.line, onLongClick = onLongClick, onClick = onClick) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Sym(icon, tint = tint, size = 22.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(label, size = 14, weight = FontWeight.SemiBold, maxLines = 1)
                T(line, size = 11, color = Tn.sub, family = Mono, maxLines = 1)
            }
        }
    }
}

/** The default output of the computer and its volume. A tap opens the list of the outputs. */
@Composable
private fun OutputKey(d: DeviceUi, modifier: Modifier, onClick: () -> Unit) {
    val o = d.outputs?.current
    val label = o?.description ?: "Audio outputs"
    val line = when {
        o == null -> "Output"
        o.muted -> "Output · muted"
        else -> "Output · ${o.volume}%"
    }
    AudioKey(if (o?.muted == true) Ic.volumeOff else Ic.speaker, label, line, "Audio outputs of ${d.name}. $label", modifier, onClick = onClick)
}

/**
 * The audio of the computer [d]: the mute choice of Play on phone, and the
 * outputs with a choice of the default output, and the volume and the mute
 * key of each output.
 */
@Composable
private fun OutputsSheet(d: DeviceUi, onDismiss: () -> Unit) {
    LaunchedEffect(d.id) { AudioOutputsSync.request(FluxCore, d.id) }
    FluxSheet(onDismiss) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T("Audio", Modifier.semantics { heading() }, size = 18, weight = FontWeight.SemiBold)
                T(d.name, size = 11, color = Tn.sub, family = Mono, maxLines = 1)
            }
            if (d.speakerSupported) {
                SheetLabel("Play on phone")
                MuteRow(d)
            }
            if (d.outputsSupported) {
                SheetLabel("Outputs")
                OutputList(d)
            }
        }
    }
}

/** The label of a part of the sheet. */
@Composable
private fun SheetLabel(text: String) {
    T(text, Modifier.padding(start = 4.dp, top = 10.dp).semantics { heading() }, size = 14, weight = FontWeight.Medium)
}

/** The outputs of the computer [d], or the wait for them, or why the computer has none. */
@Composable
private fun OutputList(d: DeviceUi) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val outs = d.outputs
        when {
            outs == null -> Row(Modifier.heightIn(min = 48.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Spinner(Modifier.size(18.dp))
                T("Asking ${d.name} for its outputs…", size = 14, color = Tn.sub)
            }
            outs.list.isEmpty() -> T(outs.error ?: "${d.name} has no audio output.", size = 14, color = if (outs.error != null) Tn.red else Tn.sub)
            else -> {
                for (o in outs.list) OutputTile(d, o)
                outs.error?.let { T(it, size = 13, color = Tn.red) }
                T("Select an output to make it the default. Apps on ${d.name} then play to it.", size = 13, color = Tn.sub)
            }
        }
    }
}

/**
 * The choice to mute the computer while this phone plays its audio. The
 * computer turns the sound of its output on again when the audio stops.
 * A change applies at once to the audio that plays.
 */
@Composable
private fun MuteRow(d: DeviceUi) {
    val context = LocalContext.current
    val on by SpeakerSettings.muteComputer.collectAsState()
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)
            .toggleable(value = on, role = Role.Switch, onValueChange = { SpeakerSession.setMute(FluxCore, context, it) })
            .padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(Ic.speakerPhone, tint = if (on) Tn.blue else Tn.sub, size = 22.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T("Mute ${d.name} while this phone plays", size = 15, weight = FontWeight.SemiBold)
            T("Play on phone mutes the default output. Its sound comes back when the audio stops.", size = 13, color = Tn.sub, lineHeight = 1.3f)
        }
        // The row takes the tap and gives the state to TalkBack, so the switch only shows it.
        Switch(checked = on, onCheckedChange = null)
    }
}

/**
 * 1 output: a choice that makes it the default, and under it the mute key
 * and the volume.
 */
@Composable
private fun OutputTile(d: DeviceUi, o: AudioOutput) {
    val shape = RoundedCornerShape(12.dp)
    Column(Modifier.fillMaxWidth().clip(shape).background(choiceFill(o.isDefault)).border(choiceBorder(o.isDefault), shape)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 48.dp)
                .selectable(selected = o.isDefault, role = Role.RadioButton) { if (!o.isDefault) AudioOutputsSync.select(FluxCore, d.id, o.name) }
                .padding(start = 14.dp, end = 14.dp, top = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Sym(if (o.isDefault) Ic.radioOn else Ic.radioOff, tint = if (o.isDefault) Tn.blue else Tn.sub, size = 20.dp)
            T(o.description, Modifier.weight(1f), size = 15, weight = FontWeight.SemiBold, maxLines = 2)
            if (o.isDefault) T("Default", size = 12, color = Tn.sub)
        }
        Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 14.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            val muteLabel = if (o.muted) "Turn on the sound of ${o.description}" else "Mute ${o.description}"
            Box(
                Modifier.size(48.dp).clip(RoundedCornerShape(8.dp))
                    .clickable(onClickLabel = muteLabel, role = Role.Button) { AudioOutputsSync.setMute(FluxCore, d.id, o.name, !o.muted) }
                    .semantics { contentDescription = muteLabel },
                contentAlignment = Alignment.Center,
            ) { Sym(if (o.muted) Ic.volumeOff else Ic.volume, tint = if (o.muted) Tn.sub else Tn.text, size = 22.dp) }
            VolumeLine(o.volume, "Volume of ${o.description}", o.muted, Modifier.weight(1f)) { AudioOutputsSync.setVolume(FluxCore, d.id, o.name, it) }
        }
    }
}

/**
 * A line of 4 dp that the user taps or drags, with the part [value] in
 * [color], and a thumb of 4 by 16 dp at the end of the part when [thumb]
 * is set. [onChange] follows a drag, and [onDone] gets the value at the
 * end of a tap or a drag. TalkBack reads [label] with [state], and can set
 * the value.
 */
@Composable
private fun LineSlider(
    value: Float,
    color: Color,
    label: String,
    state: String,
    modifier: Modifier,
    thumb: Boolean,
    enabled: Boolean = true,
    onChange: (Float) -> Unit,
    onDone: (Float) -> Unit,
) {
    val change by rememberUpdatedState(onChange)
    val done by rememberUpdatedState(onDone)
    var last by remember { mutableFloatStateOf(value) }
    val v = value.coerceIn(0f, 1f)
    BoxWithConstraints(
        modifier.fillMaxWidth()
            .semantics {
                contentDescription = label
                stateDescription = state
                progressBarRangeInfo = ProgressBarRangeInfo(v, 0f..1f)
                if (enabled) {
                    setProgress { target ->
                        done(target.coerceIn(0f, 1f))
                        true
                    }
                }
            }
            .then(
                if (!enabled) {
                    Modifier
                } else {
                    Modifier
                        .pointerInput(Unit) { detectTapGestures { done((it.x / size.width).coerceIn(0f, 1f)) } }
                        .pointerInput(Unit) {
                            detectHorizontalDragGestures(
                                onDragEnd = { done(last) },
                                onDragCancel = { done(last) },
                            ) { c, _ ->
                                last = (c.position.x / size.width).coerceIn(0f, 1f)
                                change(last)
                            }
                        }
                },
            ),
        contentAlignment = Alignment.CenterStart,
    ) {
        val w = maxWidth
        Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).background(Tn.line)) {
            Box(Modifier.fillMaxHeight().fillMaxWidth(v).clip(RoundedCornerShape(2.dp)).background(color))
        }
        if (thumb) Box(Modifier.offset(x = (w * v - 2.dp).coerceIn(0.dp, w - 4.dp)).size(4.dp, 16.dp).clip(RoundedCornerShape(2.dp)).background(color))
    }
}
