package org.omarchy.flux.ui

import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import org.omarchy.flux.core.Browse
import org.omarchy.flux.core.BrowseState
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins

fun clock(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, (s / 60) % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

fun bytes(n: Long): String = when {
    n < 0 -> ""
    n < 1024 -> "$n B"
    n < 1024 * 1024 -> "%.0f KB".format(n / 1024.0)
    n < 1024L * 1024 * 1024 -> "%.1f MB".format(n / 1024.0 / 1024.0)
    else -> "%.1f GB".format(n / 1024.0 / 1024.0 / 1024.0)
}

@Composable
fun MediaScreen(d: DeviceUi, onBack: () -> Unit) {
    val accent = Palette.accent
    val p = d.player
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    LaunchedEffect(d.id) {
        while (true) {
            Plugins.requestPlayers(FluxCore, d.id)
            delay(10_000)
        }
    }
    LaunchedEffect(p?.playing) {
        while (p?.playing == true) {
            now = SystemClock.elapsedRealtime()
            delay(500)
        }
    }
    val position = when {
        p == null -> 0L
        p.playing -> (p.position + (now - p.updatedAt)).coerceIn(0, maxOf(p.length, 0))
        else -> p.position
    }
    val fraction = if (p != null && p.length > 0) (position.toFloat() / p.length).coerceIn(0f, 1f) else 0f
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        TopBar("Media", onBack)
        Column(Modifier.padding(horizontal = 28.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(28.dp)).stripes(Palette.stripeA, Palette.stripeB),
                contentAlignment = Alignment.Center,
            ) { T("album art", size = 11, color = Palette.hint, family = Mono) }
            T(if (p != null) "${p.name} on ${d.name}" else "No player on ${d.name}", size = 13, color = accent)
            Column {
                T(p?.title?.ifEmpty { null } ?: if (p == null) "Nothing is playing" else "Unknown title", size = 24, maxLines = 2)
                T(p?.artist?.ifEmpty { null } ?: if (p == null) "Start a player on ${d.name}" else "", size = 16, color = Palette.secondary, maxLines = 1)
            }
            Box(
                Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)).background(Palette.track)
                    .pointerInput(p?.length, p?.canSeek) {
                        detectTapGestures { o ->
                            if (p != null && p.canSeek && p.length > 0) {
                                Plugins.seek(FluxCore, d.id, (o.x / size.width * p.length).toLong())
                            }
                        }
                    },
            ) {
                Box(Modifier.fillMaxHeight().fillMaxWidth(fraction).clip(RoundedCornerShape(3.dp)).background(accent))
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                T(clock(position), size = 12, color = Palette.secondary)
                T(if (p != null && p.length > 0) clock(p.length) else "0:00", size = 12, color = Palette.secondary)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(28.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(56.dp).clip(CircleShape).background(Palette.tile).clickable { Plugins.mediaAction(FluxCore, d.id, "Previous") }, contentAlignment = Alignment.Center) {
                    T("◀◀")
                }
                Box(Modifier.size(84.dp).clip(RoundedCornerShape(28.dp)).background(accent).clickable { Plugins.mediaAction(FluxCore, d.id, "PlayPause") }, contentAlignment = Alignment.Center) {
                    T(if (p?.playing == true) "❚❚" else "▶", size = 26, color = Palette.onAccent)
                }
                Box(Modifier.size(56.dp).clip(CircleShape).background(Palette.tile).clickable { Plugins.mediaAction(FluxCore, d.id, "Next") }, contentAlignment = Alignment.Center) {
                    T("▶▶")
                }
            }
        }
        Spacer(Modifier.height(96.dp))
    }
}

@Composable
fun CommandsScreen(d: DeviceUi, onBack: () -> Unit) {
    LaunchedEffect(d.id) { Plugins.requestCommands(FluxCore, d.id) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        TopBar("Run commands", onBack)
        when {
            !d.commandsLoaded -> T("Loading the commands of ${d.name}", Modifier.padding(horizontal = 20.dp, vertical = 14.dp), color = Palette.secondary)
            d.commands.isEmpty() -> T("${d.name} has no commands yet", Modifier.padding(horizontal = 20.dp, vertical = 14.dp), color = Palette.secondary)
        }
        for (c in d.commands) {
            PressRow(onClick = { Plugins.runCommand(FluxCore, d.id, c) }) {
                ListRow("$", c.name, c.command, monoGlyph = true)
            }
        }
        Spacer(Modifier.height(96.dp))
    }
}

@Composable
private fun ListRow(glyph: String, title: String, subtitle: String, monoGlyph: Boolean = false) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        GlyphBox(glyph, mono = monoGlyph)
        Column(Modifier.weight(1f)) {
            T(title, size = 16, maxLines = 1)
            if (subtitle.isNotEmpty()) T(subtitle, size = 12, color = Palette.secondary, family = Mono, maxLines = 1)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun BrowseScreen(d: DeviceUi, browse: BrowseState?, onBack: () -> Unit) {
    DisposableEffect(d.id) {
        Browse.start(FluxCore, d.id)
        onDispose {
            Browse.close()
            FluxCore.setBrowse(null)
        }
    }
    val root = browse?.roots?.firstOrNull { browse.path.startsWith(it.second) }?.second
    val atRoot = browse == null || browse.path.isEmpty() || browse.path == root
    val up = {
        if (atRoot) onBack() else Browse.list(FluxCore, browse!!.path.trimEnd('/').substringBeforeLast('/').ifEmpty { "/" })
    }
    BackHandler(enabled = !atRoot) { up() }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        TopBar("Browse PC", onBack = { up() })
        if (browse != null && browse.roots.size > 1) {
            FlowRow(
                Modifier.padding(start = 20.dp, end = 20.dp, bottom = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                for ((name, path) in browse.roots) {
                    Box(Modifier.clickable { Browse.list(FluxCore, path) }) { Chip(name, filled = path == root) }
                }
            }
        }
        if (browse != null && browse.path.isNotEmpty()) {
            // Show the path from the root folder name, not the full path on the computer.
            val rootEntry = browse.roots.firstOrNull { browse.path.startsWith(it.second) }
            val shown = rootEntry?.let { it.first + browse.path.removePrefix(it.second) } ?: browse.path
            T(shown, Modifier.padding(horizontal = 20.dp, vertical = 4.dp), size = 12, color = Palette.secondary, family = Mono, maxLines = 1)
        }
        when {
            browse?.error != null -> T(browse.error, Modifier.padding(horizontal = 20.dp, vertical = 14.dp), color = Palette.secondary)
            browse == null || (browse.loading && browse.entries.isEmpty()) ->
                T("Opening the files of ${d.name}", Modifier.padding(horizontal = 20.dp, vertical = 14.dp), color = Palette.secondary)
            browse.entries.isEmpty() -> T("This folder is empty", Modifier.padding(horizontal = 20.dp, vertical = 14.dp), color = Palette.secondary)
        }
        for (e in browse?.entries.orEmpty()) {
            PressRow(onClick = { if (e.dir) Browse.list(FluxCore, e.path) else Browse.download(FluxCore, e) }) {
                ListRow(if (e.dir) "▤" else "↓", if (e.dir) e.name + "/" else e.name, if (e.dir) "folder" else bytes(e.size))
            }
        }
        Spacer(Modifier.height(96.dp))
    }
}
