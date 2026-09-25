package org.omarchy.flux.ui

import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import org.omarchy.flux.core.Browse
import org.omarchy.flux.core.BrowseState
import org.omarchy.flux.core.DebugDemo
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
    val scheme = MaterialTheme.colorScheme
    val p = d.player
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    // The position that the user drags to, until the drag ends.
    var dragging by remember { mutableStateOf<Float?>(null) }
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
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        TopBar("Media", onBack, subtitle = "On ${d.name}")
        if (!d.online) {
            NotReachable(d, "The player controls")
            return@Column
        }
        if (p == null) {
            EmptyState(
                Ic.music,
                "Nothing is playing",
                "Play music or a video on ${d.name}. The controls show here.",
                Modifier.padding(top = 48.dp),
            )
            return@Column
        }
        if (d.players.size > 1) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = Gutter),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                for (name in d.players) {
                    FilterChip(
                        selected = name == p.name,
                        onClick = { Plugins.selectPlayer(FluxCore, d.id, name) },
                        label = { Text(name) },
                    )
                }
            }
        }
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Surface(
                Modifier.widthIn(max = 360.dp).fillMaxWidth().aspectRatio(1f),
                shape = RoundedCornerShape(32.dp),
                color = scheme.primaryContainer,
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Sym(Ic.music, tint = scheme.onPrimaryContainer, size = 112.dp)
                }
            }
            Spacer(Modifier.height(8.dp))
            Column(Modifier.fillMaxWidth()) {
                Text(
                    p.title.ifEmpty { "Unknown title" },
                    style = MaterialTheme.typography.headlineSmall,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    listOf(p.artist, p.name).filter { it.isNotEmpty() }.joinToString(" · "),
                    style = MaterialTheme.typography.titleMedium,
                    color = scheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (p.length > 0) {
                Column(Modifier.fillMaxWidth()) {
                    Slider(
                        value = dragging ?: position.toFloat(),
                        onValueChange = { dragging = it },
                        onValueChangeFinished = {
                            dragging?.let { Plugins.seek(FluxCore, d.id, it.toLong()) }
                            dragging = null
                        },
                        valueRange = 0f..p.length.toFloat(),
                        enabled = p.canSeek,
                    )
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(clock(dragging?.toLong() ?: position), style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant)
                        Text(clock(p.length), style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant)
                    }
                }
            }
            Row(
                Modifier.fillMaxWidth().padding(top = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(24.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FilledTonalIconButton(onClick = { Plugins.mediaAction(FluxCore, d.id, "Previous") }, modifier = Modifier.size(64.dp)) {
                    Sym(Ic.previous, "Previous", size = 32.dp)
                }
                FilledIconButton(
                    onClick = { Plugins.mediaAction(FluxCore, d.id, "PlayPause") },
                    modifier = Modifier.size(88.dp),
                    shape = RoundedCornerShape(28.dp),
                    colors = IconButtonDefaults.filledIconButtonColors(),
                ) {
                    Sym(if (p.playing) Ic.pause else Ic.play, if (p.playing) "Pause" else "Play", size = 44.dp)
                }
                FilledTonalIconButton(onClick = { Plugins.mediaAction(FluxCore, d.id, "Next") }, modifier = Modifier.size(64.dp)) {
                    Sym(Ic.next, "Next", size = 32.dp)
                }
            }
        }
        Spacer(Modifier.height(48.dp))
    }
}

@Composable
fun CommandsScreen(d: DeviceUi, onBack: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    LaunchedEffect(d.id) { Plugins.requestCommands(FluxCore, d.id) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        TopBar("Run commands", onBack, subtitle = "On ${d.name}")
        when {
            !d.online -> NotReachable(d, "The commands")
            !d.commandsLoaded -> Row(
                Modifier.padding(horizontal = Gutter, vertical = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                Text("Loading the commands of ${d.name}", color = scheme.onSurfaceVariant)
            }
            d.commands.isEmpty() -> EmptyState(
                Ic.terminal,
                "No commands yet",
                "On ${d.name}, open Flux and add commands in Phone commands. They show here.",
                Modifier.padding(top = 48.dp),
            )
            else -> Text(
                "Tap a command to run it on ${d.name}.",
                Modifier.padding(horizontal = Gutter, vertical = 8.dp),
                style = MaterialTheme.typography.bodyMedium,
                color = scheme.onSurfaceVariant,
            )
        }
        for (c in d.commands) {
            ListItem(
                headlineContent = { Text(c.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                supportingContent = {
                    Text(c.command, style = MaterialTheme.typography.bodySmall.copy(fontFamily = Mono), maxLines = 1, overflow = TextOverflow.Ellipsis)
                },
                leadingContent = { IconBadge(Ic.terminal, shape = RoundedCornerShape(12.dp)) },
                trailingContent = { Sym(Ic.play, "Run", tint = scheme.primary) },
                modifier = Modifier.clickable { Plugins.runCommand(FluxCore, d.id, c) },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            )
        }
        Spacer(Modifier.height(96.dp))
    }
}

/** The empty state of a screen whose computer is not reachable. [what] names what shows when it connects. */
@Composable
private fun NotReachable(d: DeviceUi, what: String) {
    EmptyState(
        Ic.wifiOff,
        "${d.name} is not reachable",
        "$what show here when ${d.name} connects again.",
        Modifier.padding(top = 48.dp),
        action = { TextButton(onClick = { FluxCore.rediscover() }) { Text("Retry") } },
    )
}

@Composable
fun BrowseScreen(d: DeviceUi, browse: BrowseState?, onBack: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    fun open() {
        if (DebugDemo.isDemo(d.id)) FluxCore.setBrowse(DebugDemo.browse()) else Browse.start(FluxCore, d.id)
    }
    DisposableEffect(d.id) {
        open()
        onDispose {
            Browse.close()
            FluxCore.setBrowse(null)
        }
    }
    val rootEntry = browse?.roots?.firstOrNull { browse.path.startsWith(it.second) }
    val root = rootEntry?.second
    val atRoot = browse == null || browse.path.isEmpty() || browse.path == root
    val up = {
        if (atRoot) onBack() else Browse.list(FluxCore, browse!!.path.trimEnd('/').substringBeforeLast('/').ifEmpty { "/" })
    }
    BackHandler(enabled = !atRoot) { up() }
    // Show the path from the root folder name, not the full path on the computer.
    val shown = browse?.path?.takeIf { it.isNotEmpty() }?.let { path ->
        rootEntry?.let { it.first + "/" + path.removePrefix(it.second).trimEnd('/') }?.trimEnd('/') ?: path
    }
    Column(Modifier.fillMaxSize()) {
        TopBar("Browse PC", onBack = { up() }, subtitle = shown ?: "On ${d.name}")
        if (browse != null && browse.loading) LinearProgressIndicator(Modifier.fillMaxWidth()) else Spacer(Modifier.height(4.dp))
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            if (browse != null && browse.roots.size > 1) {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = Gutter, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    for ((name, path) in browse.roots) {
                        FilterChip(
                            selected = path == root,
                            onClick = { Browse.list(FluxCore, path) },
                            label = { Text(name) },
                            leadingIcon = { Sym(if (name.equals("Home", ignoreCase = true)) Ic.home else Ic.drive, size = 18.dp) },
                        )
                    }
                }
            }
            when {
                browse?.error != null -> EmptyState(
                    Ic.error,
                    "Cannot open the files",
                    browse.error,
                    Modifier.padding(top = 32.dp),
                    action = { TextButton(onClick = ::open) { Text("Try again") } },
                )
                browse == null || (browse.loading && browse.entries.isEmpty()) -> Text(
                    "Opening the files of ${d.name}",
                    Modifier.padding(horizontal = Gutter, vertical = 16.dp),
                    color = scheme.onSurfaceVariant,
                )
                browse.entries.isEmpty() -> EmptyState(Ic.folderOpen, "This folder is empty", "Go back to open another folder.", Modifier.padding(top = 32.dp))
            }
            for (e in browse?.entries.orEmpty()) {
                ListItem(
                    headlineContent = { Text(e.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    supportingContent = { Text(if (e.dir) "Folder" else bytes(e.size)) },
                    leadingContent = {
                        IconBadge(
                            fileIcon(e.name, e.dir),
                            container = if (e.dir) scheme.primaryContainer else scheme.surfaceContainerHighest,
                            content = if (e.dir) scheme.onPrimaryContainer else scheme.onSurfaceVariant,
                            shape = RoundedCornerShape(12.dp),
                        )
                    },
                    trailingContent = {
                        if (e.dir) Sym(Ic.chevron, tint = scheme.onSurfaceVariant) else Sym(Ic.download, "Download", tint = scheme.primary)
                    },
                    modifier = Modifier.clickable { if (e.dir) Browse.list(FluxCore, e.path) else Browse.download(FluxCore, e) },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                )
            }
            Spacer(Modifier.height(96.dp))
        }
    }
}
