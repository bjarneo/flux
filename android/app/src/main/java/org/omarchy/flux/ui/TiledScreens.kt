package org.omarchy.flux.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins

// ───────────────────────── Pairing ─────────────────────────

/** The text of a group of the pairing key. The pair sheet measures it to choose the number of rows. */
private val PairKeyStyle = TextStyle(fontSize = 18.sp, fontWeight = FontWeight.Medium, fontFamily = Mono)

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
                // The 4 groups share 1 row. At a large font size, the groups go to 2 rows, and a box grows with its text.
                val groups = PairKey.groups(key)
                val measurer = rememberTextMeasurer()
                val density = LocalDensity.current
                BoxWithConstraints(Modifier.semantics(mergeDescendants = true) { contentDescription = "Code ${PairKey.display(key)}" }) {
                    // The widest group with 8 dp of space on each side.
                    val box = groups.maxOf { measurer.measure(it, PairKeyStyle).size.width } + with(density) { 16.dp.roundToPx() }
                    val perRow = PairKey.perRow(box, constraints.maxWidth, with(density) { 8.dp.roundToPx() })
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (row in groups.chunked(perRow)) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                for (group in row) {
                                    Box(
                                        Modifier.weight(1f).heightIn(min = 44.dp).clip(RoundedCornerShape(6.dp)).background(Tn.bg)
                                            .border(1.dp, Tn.lineHi, RoundedCornerShape(6.dp)),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        T(group, Modifier.padding(vertical = 6.dp), size = 18, color = Tn.yellow, weight = FontWeight.Medium, family = Mono)
                                    }
                                }
                            }
                        }
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
