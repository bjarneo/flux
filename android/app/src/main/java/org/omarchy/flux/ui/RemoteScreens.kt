package org.omarchy.flux.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.omarchy.flux.core.Browse
import org.omarchy.flux.core.BrowseState
import org.omarchy.flux.core.DebugDemo
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore

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

/** The empty state of a screen whose computer is not reachable. [what] names what shows when it connects. */
@Composable
fun NotReachable(d: DeviceUi, what: String) {
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
