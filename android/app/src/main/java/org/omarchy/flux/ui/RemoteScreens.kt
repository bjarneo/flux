package org.omarchy.flux.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
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
fun NotReachable(d: DeviceUi, what: String, modifier: Modifier = Modifier) {
    EmptyState(
        Ic.wifiOff,
        "${d.name} is not reachable",
        "$what show here when ${d.name} connects again. Check that Flux runs on ${d.name}, and that this phone is on the same network or on Tailscale.",
        modifier.padding(top = 48.dp),
        action = { FluxButton("Retry", { FluxCore.rediscover() }, kind = ButtonKind.Tonal, icon = Ic.refresh) },
    )
}

/**
 * The 1-line form of [NotReachable], for a screen that keeps its work while
 * the link is down, such as a capture to send. [what] names what works
 * again when the computer connects. TalkBack reads the line when it shows.
 */
@Composable
fun NotReachableLine(d: DeviceUi, what: String, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)
            .padding(start = 14.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(Ic.wifiOff, tint = Tn.sub, size = 20.dp)
        T(
            "${d.name} is not reachable. $what works again when it connects.",
            Modifier.weight(1f).padding(vertical = 8.dp).semantics { liveRegion = LiveRegionMode.Polite },
            size = 13, lineHeight = 1.3f,
        )
        FluxButton("Retry", { FluxCore.rediscover() }, kind = ButtonKind.Text, icon = Ic.refresh)
    }
}

/**
 * Get files: the folders that the computer shares, read-only. A tap on a
 * folder opens it, and a tap on a file downloads it to this phone. Back
 * goes up 1 folder, then leaves the screen.
 */
@Composable
fun BrowseScreen(d: DeviceUi, browse: BrowseState?, onBack: () -> Unit) {
    fun open() {
        if (isDemo(d.id)) FluxCore.setBrowse(DebugDemo.browse()) else Browse.start(FluxCore, d.id)
    }
    // The state of the screen stays until the screen closes. A link drop
    // keeps the folder that is open.
    DisposableEffect(d.id) {
        onDispose {
            Browse.close()
            FluxCore.setBrowse(null)
        }
    }
    // The session starts when the computer is reachable. fluxd ends the
    // session when the link drops, so a new session opens the same folder.
    LaunchedEffect(d.id, d.online) {
        if (!d.online) return@LaunchedEffect
        if (isDemo(d.id)) {
            if (browse == null) open()
        } else {
            Browse.start(FluxCore, d.id, browse?.path?.takeIf { browse.deviceId == d.id && it.isNotEmpty() })
        }
    }
    val rootEntry = browse?.roots?.firstOrNull { browse.path.startsWith(it.second) }
    val root = rootEntry?.second
    val atRoot = browse == null || browse.path.isEmpty() || browse.path == root
    // Back goes up 1 folder. While the computer is not reachable, Back leaves the screen.
    val up = {
        if (atRoot || !d.online) onBack() else Browse.list(FluxCore, browse!!.path.trimEnd('/').substringBeforeLast('/').ifEmpty { "/" })
    }
    BackHandler(enabled = d.online && !atRoot) { up() }
    // Show the path from the root folder name, not the full path on the computer.
    val shown = browse?.path?.takeIf { it.isNotEmpty() }?.let { path ->
        rootEntry?.let { it.first + "/" + path.removePrefix(it.second).trimEnd('/') }?.trimEnd('/') ?: path
    }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.padding(horizontal = TiledGutter)) {
            TiledTopBar("Get files", onBack = { up() }, context = if (d.online) shown ?: d.name else d.name)
        }
        if (!d.online) {
            Box(Modifier.padding(horizontal = TiledGutter)) { NotReachable(d, "The files") }
            return@Column
        }
        if (browse != null && browse.loading && browse.entries.isNotEmpty()) {
            LinearProgressIndicator(Modifier.fillMaxWidth(), color = Tn.blue, trackColor = Tn.line)
        } else {
            Spacer(Modifier.height(4.dp))
        }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            if (browse != null && browse.roots.size > 1) {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).selectableGroup().padding(horizontal = Gutter, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    for ((name, path) in browse.roots) {
                        ChoiceChip(
                            name, selected = path == root, onClick = { Browse.list(FluxCore, path) },
                            leading = { Sym(if (name.equals("Home", ignoreCase = true)) Ic.home else Ic.drive, tint = if (path == root) Tn.blue else Tn.sub, size = 18.dp) },
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
                    action = { FluxButton("Try again", ::open, kind = ButtonKind.Tonal, icon = Ic.refresh) },
                )
                browse == null || (browse.loading && browse.entries.isEmpty()) -> LineSkeleton(
                    "Opening the files of ${d.name}",
                    Modifier.padding(horizontal = Gutter, vertical = 16.dp),
                    lines = listOf(0.6f, 0.45f, 0.7f, 0.5f, 0.65f, 0.4f),
                )
                browse.entries.isEmpty() -> EmptyState(Ic.folderOpen, "This folder is empty", "Go back to open another folder.", Modifier.padding(top = 32.dp))
            }
            for (e in browse?.entries.orEmpty()) {
                ListItem(
                    headlineContent = { Text(e.name) },
                    supportingContent = { Text(if (e.dir) "Folder" else bytes(e.size)) },
                    leadingContent = {
                        IconBadge(
                            fileIcon(e.name, e.dir),
                            container = Tn.tile,
                            content = if (e.dir) Tn.blue else Tn.sub,
                            shape = RoundedCornerShape(8.dp),
                        )
                    },
                    trailingContent = {
                        if (e.dir) Sym(Ic.chevron, tint = Tn.sub) else Sym(Ic.download, "Download", tint = Tn.blue)
                    },
                    modifier = Modifier.clickable(role = Role.Button, onClickLabel = if (e.dir) "Open the folder" else "Download the file") {
                        if (e.dir) Browse.list(FluxCore, e.path) else Browse.download(FluxCore, e)
                    },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent, supportingColor = Tn.sub),
                )
            }
            Spacer(Modifier.height(96.dp))
        }
    }
}
