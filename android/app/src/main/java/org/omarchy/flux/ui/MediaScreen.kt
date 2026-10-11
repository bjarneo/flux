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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
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
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.PlayerState
import org.omarchy.flux.core.Plugins

/**
 * The player of 1 computer: the players as pills, the album art, the
 * title, the artist, and the album, and the dock with the position,
 * Previous, Play or Pause, Next, and the volume. A player that sends no
 * volume shows no volume row.
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
                delay(10_000)
            }
        }
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
            p == null -> EmptyState(Ic.music, "Nothing is playing", "Play music or a video on ${d.name}. The controls show here.", Modifier.padding(top = 48.dp))
            else -> DockLayout(
                Modifier.weight(1f).fillMaxWidth(),
                thread = { bottom -> NowPlaying(p, bottom) },
                dock = { shape -> PlayerDock(d, p, shown, shape, onDrag = { dragging = it }, onSeek = { f ->
                    dragging = null
                    Plugins.seek(FluxCore, d.id, (f * p.length).toLong())
                }) },
            )
        }
    }
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
 * at the end of a tap or a drag.
 */
@Composable
private fun PlayerDock(d: DeviceUi, p: PlayerState, position: Long, shape: DockShape, onDrag: (Float) -> Unit, onSeek: (Float) -> Unit) {
    Column(
        Modifier.fillMaxWidth().dockFrame(shape).padding(start = 12.dp, end = 12.dp, top = 16.dp, bottom = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
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

/** The volume of the player: the icon, a line to tap or drag, and the value. At most 1 request goes out each 150 ms during a drag. */
@Composable
private fun VolumeRow(d: DeviceUi, volume: Int) {
    var drag by remember { mutableStateOf<Float?>(null) }
    var sentAt by remember { mutableLongStateOf(0L) }
    val shown = drag?.let { (it * 100).roundToInt() } ?: volume
    Row(
        Modifier.fillMaxWidth().height(40.dp).padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(Ic.volumeDown, tint = Tn.sub, size = 20.dp)
        LineSlider(
            shown / 100f, Tn.text, "Volume", "$shown%", Modifier.weight(1f).height(32.dp), thumb = false,
            onChange = {
                drag = it
                val now = SystemClock.elapsedRealtime()
                if (now - sentAt >= 150) {
                    sentAt = now
                    Plugins.setVolume(FluxCore, d.id, (it * 100).roundToInt())
                }
            },
            onDone = {
                Plugins.setVolume(FluxCore, d.id, (it * 100).roundToInt())
                drag = null
            },
        )
        T("$shown%", Modifier.widthIn(min = 34.dp), size = 11, color = Tn.sub, family = Mono, align = TextAlign.End)
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
