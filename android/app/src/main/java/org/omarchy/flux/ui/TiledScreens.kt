package org.omarchy.flux.ui

import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.annotation.DrawableRes
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins

// ───────────────────────── Pairing ─────────────────────────

/**
 * The pairing sheet: the verification key, 1 box for each group of 4
 * digits. Back and a tap on the scrim cancel. Windows of other apps hide
 * while the sheet shows, and a tap that such a window covered does not pair.
 */
@Composable
fun TiledPairSheet(name: String, key: String, waiting: Boolean, onCancel: () -> Unit, onPair: () -> Unit) {
    BackHandler(onBack = onCancel)
    HideOverlays()
    val activity = LocalActivity.current as? MainActivity
    val pair = {
        if (activity?.touchObscured == true) {
            FluxCore.toast("Another app draws over Flux. Close that app, then pair.")
        } else {
            onPair()
        }
    }
    Box(
        Modifier.fillMaxSize().background(Color(0x990A0A0F))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onCancel),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                .background(Tn.tile)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { },
        ) {
            Box(Modifier.fillMaxWidth().height(2.dp).background(Tn.yellow))
            Column(
                Modifier.navigationBarsPadding().padding(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    TileLabel("Pair", color = Tn.yellow)
                    T(name, size = 22, weight = FontWeight.SemiBold, letterSpacing = -0.4f, maxLines = 1)
                    T(
                        if (waiting) "Confirm the same code on $name. Compare all 16 characters." else "Check that $name shows the same code. Compare all 16 characters.",
                        size = 13, color = Tn.sub,
                    )
                }
                Row(
                    Modifier.semantics(mergeDescendants = true) { contentDescription = "Code ${PairKey.display(key)}" },
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    for (group in PairKey.groups(key)) {
                        Box(
                            Modifier.weight(1f).height(44.dp).clip(RoundedCornerShape(6.dp)).background(Tn.bg)
                                .border(1.dp, Tn.lineHi, RoundedCornerShape(6.dp)),
                            contentAlignment = Alignment.Center,
                        ) { T(group, size = 18, color = Tn.yellow, weight = FontWeight.Medium, family = Mono, maxLines = 1) }
                    }
                }
                Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                    Box(
                        Modifier.weight(1f).height(48.dp).clip(RoundedCornerShape(10.dp)).background(Tn.line).clickable(onClick = onCancel),
                        contentAlignment = Alignment.Center,
                    ) { T("Cancel", size = 14, weight = FontWeight.SemiBold) }
                    Box(
                        Modifier.weight(2f).height(48.dp).clip(RoundedCornerShape(10.dp)).background(Tn.yellow)
                            .clickable(enabled = !waiting, onClick = pair),
                        contentAlignment = Alignment.Center,
                    ) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            if (waiting) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Tn.onAccent)
                            T(if (waiting) "Waiting" else "Pair", size = 14, color = Tn.onAccent, weight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        }
    }
}

// ───────────────────────── Media ─────────────────────────

/**
 * The player controls of 1 computer. The album art shows when the player
 * has it. Without art, the controls move up.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TiledMediaScreen(d: DeviceUi, onBack: () -> Unit) {
    val p = d.player
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    // The position that the user drags to, until the drag ends.
    var dragging by remember { mutableStateOf<Float?>(null) }
    // The volume that the user drags to, and the time of the last volume sent.
    var volumeDrag by remember { mutableStateOf<Float?>(null) }
    var volumeSentAt by remember { mutableLongStateOf(0L) }
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
    LaunchedEffect(p?.playing) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (p?.playing == true) {
                now = SystemClock.elapsedRealtime()
                delay(500)
            }
        }
    }
    val position = when {
        p == null -> 0L
        p.playing -> (p.position + (now - p.updatedAt)).coerceIn(0, maxOf(p.length, 0))
        else -> p.position
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter)) {
        TiledTopBar("Media", onBack, context = d.name)
        if (!d.online) {
            NotReachable(d, "The player controls")
            return@Column
        }
        if (p == null) {
            EmptyState(Ic.music, "Nothing is playing", "Play music or a video on ${d.name}. The controls show here.", Modifier.padding(top = 48.dp))
            return@Column
        }
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            if (d.players.size > 1) {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).selectableGroup(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    for (name in d.players) {
                        ChoiceChip(name, selected = name == p.name, onClick = { Plugins.selectPlayer(FluxCore, d.id, name) }, mono = true)
                    }
                }
            }
            val art by rememberAlbumArt(p.artUrl)
            art?.let { image ->
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Image(
                        image, "Album art",
                        Modifier.widthIn(max = 360.dp).fillMaxWidth().aspectRatio(1f).clip(TileShape).border(1.dp, Tn.line, TileShape),
                        contentScale = ContentScale.Crop,
                    )
                }
            }
            Tile(Modifier.fillMaxWidth(), border = null, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                T(p.title.ifEmpty { "Unknown title" }, size = 22, weight = FontWeight.SemiBold, letterSpacing = -0.4f)
                val by = listOf(p.artist, p.album).filter { it.isNotEmpty() }.joinToString(" · ")
                if (by.isNotEmpty()) T(by, size = 14, color = Tn.sub)
                T(p.name, size = 12, color = Tn.sub, family = Mono)
                if (p.length > 0) {
                    // A thin track like the battery bar, with a small thumb while the player can seek.
                    val colors = SliderDefaults.colors(
                        thumbColor = Tn.green, activeTrackColor = Tn.green, inactiveTrackColor = Tn.line,
                        disabledThumbColor = Tn.green, disabledActiveTrackColor = Tn.green, disabledInactiveTrackColor = Tn.line,
                    )
                    val source = remember { MutableInteractionSource() }
                    Slider(
                        value = dragging ?: position.toFloat(),
                        onValueChange = { dragging = it },
                        onValueChangeFinished = {
                            dragging?.let { Plugins.seek(FluxCore, d.id, it.toLong()) }
                            dragging = null
                        },
                        valueRange = 0f..p.length.toFloat(),
                        enabled = p.canSeek,
                        modifier = Modifier.semantics { contentDescription = "Position" },
                        colors = colors,
                        interactionSource = source,
                        thumb = {
                            if (p.canSeek) SliderDefaults.Thumb(source, colors = colors, thumbSize = DpSize(4.dp, 18.dp))
                        },
                        track = {
                            SliderDefaults.Track(
                                it, Modifier.height(4.dp), enabled = p.canSeek, colors = colors,
                                drawStopIndicator = null, thumbTrackGapSize = if (p.canSeek) 4.dp else 0.dp,
                            )
                        },
                    )
                    Row(Modifier.fillMaxWidth()) {
                        T(clock(dragging?.toLong() ?: position), Modifier.weight(1f), size = 11, color = Tn.sub, family = Mono)
                        T(clock(p.length), size = 11, color = Tn.sub, family = Mono)
                    }
                }
            }
            TileRow(64.dp) {
                ControlTile(Ic.previous, "Previous", Modifier.weight(1f), p.canGoPrevious) { Plugins.mediaAction(FluxCore, d.id, "Previous") }
                Tile(
                    Modifier.weight(1f).fillMaxHeight().semantics { contentDescription = if (p.playing) "Pause" else "Play" },
                    { Plugins.mediaAction(FluxCore, d.id, "PlayPause") },
                    container = Tn.green, border = null, padding = PaddingValues(0.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                ) {
                    Sym(if (p.playing) Ic.pause else Ic.play, tint = Tn.onAccent, size = 34.dp)
                }
                ControlTile(Ic.next, "Next", Modifier.weight(1f), p.canGoNext) { Plugins.mediaAction(FluxCore, d.id, "Next") }
            }
            // Only a player that takes a volume sends one. Chromium, for example, does not.
            val volume = p.volume
            if (volume != null) {
                Tile(Modifier.fillMaxWidth(), border = null, padding = PaddingValues(horizontal = 14.dp, vertical = 6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Sym(Ic.volume, tint = Tn.green, size = 22.dp)
                        val colors = SliderDefaults.colors(thumbColor = Tn.green, activeTrackColor = Tn.green, inactiveTrackColor = Tn.line)
                        val source = remember { MutableInteractionSource() }
                        Slider(
                            value = volumeDrag ?: volume.toFloat(),
                            onValueChange = {
                                volumeDrag = it
                                // The player follows the drag. At most one request goes out each 150 ms.
                                val now = SystemClock.elapsedRealtime()
                                if (now - volumeSentAt >= 150) {
                                    volumeSentAt = now
                                    Plugins.setVolume(FluxCore, d.id, it.roundToInt())
                                }
                            },
                            onValueChangeFinished = {
                                volumeDrag?.let { Plugins.setVolume(FluxCore, d.id, it.roundToInt()) }
                                volumeDrag = null
                            },
                            valueRange = 0f..100f,
                            modifier = Modifier.weight(1f).semantics { contentDescription = "Volume" },
                            colors = colors,
                            interactionSource = source,
                            thumb = { SliderDefaults.Thumb(source, colors = colors, thumbSize = DpSize(4.dp, 18.dp)) },
                            track = {
                                SliderDefaults.Track(
                                    it, Modifier.height(4.dp), colors = colors,
                                    drawStopIndicator = null, thumbTrackGapSize = 4.dp,
                                )
                            },
                        )
                        T("${volumeDrag?.roundToInt() ?: volume}", size = 11, color = Tn.sub, family = Mono)
                    }
                }
            }
        }
        Spacer(Modifier.height(48.dp))
    }
}

/** A key of the player. A key that the player does not offer shows dimmed and takes no taps. */
@Composable
private fun ControlTile(@DrawableRes icon: Int, description: String, modifier: Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Tile(
        modifier.fillMaxHeight().semantics { contentDescription = description }, onClick, accent = Tn.green, enabled = enabled,
        padding = PaddingValues(0.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
    ) {
        Sym(icon, size = 28.dp)
    }
}

// ───────────────────────── Commands ─────────────────────────

/**
 * The commands that a computer publishes. A tap sends the command. The
 * computer does not report when a command ends, so the tile shows Sent,
 * not Done.
 */
@Composable
fun TiledCommandsScreen(d: DeviceUi, onBack: () -> Unit) {
    LaunchedEffect(d.id, d.online) { if (d.online) Plugins.requestCommands(FluxCore, d.id) }
    // The command that the phone sent last shows Sent for a moment.
    var sent by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(sent) {
        if (sent != null) {
            delay(2000)
            sent = null
        }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter)) {
        TiledTopBar("Commands", onBack, context = d.name)
        when {
            !d.online -> NotReachable(d, "The commands")
            !d.commandsLoaded -> LineSkeleton("Loading the commands of ${d.name}", Modifier.padding(4.dp), lines = listOf(0.5f, 0.35f, 0.45f))
            d.commands.isEmpty() -> EmptyState(
                Ic.terminal,
                "No commands yet",
                "On ${d.name}, open Flux and add commands in Phone commands. They show here.",
                Modifier.padding(top = 48.dp),
            )
            else -> Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
                for (row in d.commands.chunked(2)) {
                    TileRow(112.dp) {
                        for (c in row) {
                            val done = sent == c.key
                            Tile(
                                Modifier.weight(1f).fillMaxHeight(),
                                // The tile shows Sent only when the phone sent the command.
                                onClick = { if (Plugins.runCommand(FluxCore, d.id, c)) sent = c.key },
                                accent = Tn.yellow,
                                border = BorderStroke(1.dp, if (done) Tn.green else Tn.line),
                                verticalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Sym(Ic.terminal, tint = Tn.yellow, size = 22.dp)
                                    Spacer(Modifier.weight(1f))
                                    if (done) {
                                        Sym(Ic.check, tint = Tn.green, size = 18.dp)
                                        T("Sent", size = 12, color = Tn.green, weight = FontWeight.SemiBold)
                                    } else {
                                        Sym(Ic.play, tint = Tn.sub, size = 18.dp)
                                    }
                                }
                                Spacer(Modifier.weight(1f))
                                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    T(c.name, size = 14, weight = FontWeight.SemiBold)
                                    T(c.command, size = 11, color = Tn.sub, family = Mono, maxLines = 2)
                                }
                            }
                        }
                        if (row.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
        }
        Spacer(Modifier.height(96.dp))
    }
}
