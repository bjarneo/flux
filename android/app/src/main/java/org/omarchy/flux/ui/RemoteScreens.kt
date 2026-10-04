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
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import org.omarchy.flux.core.Browse
import org.omarchy.flux.core.BrowseEntry
import org.omarchy.flux.core.BrowseSearch
import org.omarchy.flux.core.BrowseState
import org.omarchy.flux.core.DebugDemo
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.voice.DictationText
import org.omarchy.flux.voice.VoiceField
import org.omarchy.flux.voice.rememberVoiceTyping

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
 * goes up 1 folder, then leaves the screen. The search finds names in the
 * folder that is open and its subfolders. At the top of the home folder,
 * it finds names in each shared folder.
 */
@Composable
fun BrowseScreen(d: DeviceUi, browse: BrowseState?, onBack: () -> Unit) {
    fun open() {
        if (isDemo(d.id)) FluxCore.setBrowse(DebugDemo.browse()) else Browse.start(FluxCore, d.id)
    }
    var query by rememberSaveable(d.id) { mutableStateOf("") }
    val focus = LocalFocusManager.current
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
    val canSearch = d.online && browse?.canSearch == true
    val searching = canSearch && query.isNotBlank()
    // At the top of the first root, the search reads each shared folder.
    val home = browse?.roots?.firstOrNull()?.second?.trimEnd('/')
    val searchFrom = browse?.path?.takeIf { it.isNotEmpty() && it.trimEnd('/') != home }.orEmpty()
    // A new session has no roots until the computer answers, so the search
    // waits for them.
    val ready = browse != null && browse.roots.isNotEmpty() && browse.error == null
    LaunchedEffect(query, searchFrom, canSearch, ready) {
        if (!canSearch || !ready) return@LaunchedEffect
        if (query.isBlank()) {
            Browse.search(FluxCore, "", searchFrom)
            return@LaunchedEffect
        }
        // The search waits for a pause in the typing.
        delay(350)
        val state = FluxCore.browseState() ?: return@LaunchedEffect
        if (isDemo(d.id)) FluxCore.setBrowse(state.copy(search = DebugDemo.search(query, searchFrom))) else Browse.search(FluxCore, query, searchFrom)
    }
    // Back goes up 1 folder. While the computer is not reachable, Back leaves the screen.
    val up = {
        if (atRoot || !d.online) onBack() else Browse.list(FluxCore, browse!!.path.trimEnd('/').substringBeforeLast('/').ifEmpty { "/" })
    }
    BackHandler(enabled = d.online && !atRoot) { up() }
    // Back clears the search first.
    BackHandler(enabled = searching) { query = "" }
    // Show the path from the root folder name, not the full path on the computer.
    // The first root that holds the path names it, as for the chips.
    fun shownPath(path: String): String {
        val r = browse?.roots?.firstOrNull { path.startsWith(it.second) } ?: return path
        return (r.first + "/" + path.removePrefix(r.second).trim('/')).trimEnd('/')
    }
    val shown = browse?.path?.takeIf { it.isNotEmpty() }?.let { shownPath(it) }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.padding(horizontal = TiledGutter)) {
            TiledTopBar("Get files", onBack = { if (searching) query = "" else up() }, context = if (d.online) shown ?: d.name else d.name)
        }
        if (!d.online) {
            Box(Modifier.padding(horizontal = TiledGutter)) { NotReachable(d, "The files") }
            return@Column
        }
        if (canSearch) {
            BrowseSearchField(
                query,
                if (searchFrom.isEmpty()) "Search all shared folders" else "Search in ${shownPath(searchFrom).substringAfterLast('/')}",
                Modifier.padding(horizontal = TiledGutter, vertical = 4.dp),
                onDone = { focus.clearFocus() },
            ) { query = it.take(200) }
        }
        val search = browse?.search?.takeIf { searching }
        val searchBusy = search != null && search.loading && search.results.isNotEmpty()
        if ((browse != null && browse.loading && browse.entries.isNotEmpty() && !searching) || searchBusy) {
            LinearProgressIndicator(Modifier.fillMaxWidth(), color = Tn.blue, trackColor = Tn.line)
        } else {
            Spacer(Modifier.height(4.dp))
        }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            if (searching) {
                BrowseResults(d, query, search, searchFrom.isEmpty(), ::shownPath) { e ->
                    if (e.dir) {
                        query = ""
                        focus.clearFocus()
                        Browse.list(FluxCore, e.path)
                    } else {
                        Browse.download(FluxCore, e)
                    }
                }
                Spacer(Modifier.height(96.dp))
                return@Column
            }
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
                BrowseRow(e, if (e.dir) "Folder" else bytes(e.size)) {
                    if (e.dir) Browse.list(FluxCore, e.path) else Browse.download(FluxCore, e)
                }
            }
            Spacer(Modifier.height(96.dp))
        }
    }
}

/** The search field of Get files. A dictation replaces the query. */
@Composable
private fun BrowseSearchField(query: String, placeholder: String, modifier: Modifier, onDone: () -> Unit, onQuery: (String) -> Unit) {
    val voice = rememberVoiceTyping { onQuery(DictationText.query(it)) }
    VoiceField(voice, modifier) { m ->
        OutlinedTextField(
            value = query,
            onValueChange = onQuery,
            modifier = m,
            placeholder = { T(placeholder, color = Tn.sub, maxLines = 1) },
            leadingIcon = { Sym(Ic.search, tint = Tn.sub, size = 20.dp) },
            trailingIcon = if (query.isEmpty()) null else { { ClearKey({ onQuery("") }, "Clear the search") } },
            singleLine = true,
            textStyle = TextStyle(color = Tn.text, fontSize = 14.sp),
            shape = TileShape,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { onDone() }),
        )
    }
}

/**
 * The results of a search. Each row shows the folder of the match. [all]
 * tells that the search reads each shared folder. [onOpen] opens a folder
 * or downloads a file.
 */
@Composable
private fun BrowseResults(
    d: DeviceUi,
    query: String,
    search: BrowseSearch?,
    all: Boolean,
    shownPath: (String) -> String,
    onOpen: (BrowseEntry) -> Unit,
) {
    val q = query.trim()
    when {
        search == null || (search.loading && search.results.isEmpty()) -> LineSkeleton(
            "Searching the files of ${d.name}",
            Modifier.padding(horizontal = Gutter, vertical = 16.dp),
            lines = listOf(0.6f, 0.45f, 0.7f, 0.5f),
        )
        search.error != null -> EmptyState(
            Ic.error,
            "Cannot search",
            search.error,
            Modifier.padding(top = 32.dp),
            action = { FluxButton("Try again", { Browse.search(FluxCore, search.query, search.path) }, kind = ButtonKind.Tonal, icon = Ic.refresh) },
        )
        search.results.isEmpty() -> EmptyState(
            Ic.search,
            "No file or folder has \"$q\"",
            when {
                search.partial -> "The search stopped after 10 seconds. Open a folder and search there."
                all -> "The search reads the names in the shared folders. Names that start with a dot stay hidden."
                else -> "Go back to the top of Home to search all shared folders."
            },
            Modifier.padding(top = 32.dp),
        )
    }
    for (e in search?.results.orEmpty()) {
        val folder = shownPath(e.path.trimEnd('/').substringBeforeLast('/'))
        BrowseRow(e, if (e.dir) folder else "$folder · ${bytes(e.size)}", onOpen = { onOpen(e) })
    }
    if (search != null && !search.loading && search.results.isNotEmpty() && (search.more || search.partial)) {
        T(
            if (search.partial) "The search stopped after 10 seconds. Open a folder and search there to find more."
            else "Showing the first ${search.results.size} matches. Type more of the name.",
            Modifier.padding(horizontal = Gutter, vertical = 12.dp).semantics { liveRegion = LiveRegionMode.Polite },
            size = 13, color = Tn.sub, lineHeight = 1.3f,
        )
    }
}

/** 1 file or folder of Get files. A tap opens the folder or downloads the file. */
@Composable
private fun BrowseRow(e: BrowseEntry, supporting: String, onOpen: () -> Unit) {
    ListItem(
        headlineContent = { Text(e.name) },
        supportingContent = { Text(supporting, maxLines = 1) },
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
        modifier = Modifier.clickable(role = Role.Button, onClickLabel = if (e.dir) "Open the folder" else "Download the file", onClick = onOpen),
        colors = ListItemDefaults.colors(containerColor = Color.Transparent, supportingColor = Tn.sub),
    )
}
