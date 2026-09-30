package org.omarchy.flux.ui

import android.content.Context
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.edit
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.FolderChoice
import org.omarchy.flux.core.HerdrReply
import org.omarchy.flux.core.HerdrSync
import org.omarchy.flux.core.HerdrWorkspace
import org.omarchy.flux.core.SHELL_CHOICE
import org.omarchy.flux.core.agentProduct
import org.omarchy.flux.core.filterFolders
import org.omarchy.flux.core.folderChoices
import org.omarchy.flux.core.folderName
import org.omarchy.flux.core.looksLikePath
import org.omarchy.flux.core.normalFolder
import org.omarchy.flux.core.pickRun
import org.omarchy.flux.core.workspaceFor
import org.omarchy.flux.voice.DictationText
import org.omarchy.flux.voice.VoiceField
import org.omarchy.flux.voice.rememberVoiceTyping

/** How often the terminal screen reads the output again. */
private const val TERMINAL_REFRESH_MS = 3_000L

/** The preferences of the new pane screen: the last run choice and folder of each computer. */
private object NewPanePrefs {
    private const val PREFS = "flux-herdr"

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The last run choice, [SHELL_CHOICE] for a terminal, or null when there is none. */
    fun run(context: Context, device: String): String? = prefs(context).getString("run.$device", null)

    fun folder(context: Context, device: String): String = prefs(context).getString("folder.$device", null).orEmpty()

    fun save(context: Context, device: String, run: String, folder: String) {
        prefs(context).edit {
            putString("run.$device", run)
            putString("folder.$device", folder)
        }
    }
}

// ───────────────────────── New agent or terminal ─────────────────────────

/**
 * Starts a herdr agent or opens a terminal on a computer. The user picks
 * what to run from the agents that the computer has, then a folder. The
 * pane opens as a new tab of the workspace of that folder, or in a new
 * workspace. The start bar stays at the bottom and says what happens.
 * [onOpened] gets "agent" or "terminal" and the new pane when the
 * computer reports it.
 */
@Composable
fun TiledNewPaneScreen(d: DeviceUi, onBack: () -> Unit, onOpened: (what: String, pane: String) -> Unit) {
    val context = LocalContext.current
    val herdr = d.herdr
    val kinds = herdr?.kinds.orEmpty()
    val shell = herdr?.terminals == true
    var run by rememberSaveable(d.id) { mutableStateOf(NewPanePrefs.run(context, d.id)) }
    LaunchedEffect(kinds, shell) { run = pickRun(run, kinds, shell) }
    var folder by rememberSaveable(d.id) { mutableStateOf(normalFolder(NewPanePrefs.folder(context, d.id)).ifEmpty { "~" }) }
    var query by rememberSaveable(d.id) { mutableStateOf("") }
    var newWorkspace by rememberSaveable(d.id) { mutableStateOf(false) }
    var lockError by remember { mutableStateOf<String?>(null) }

    // Only a create from this screen counts. Its sequence number is higher than the last action at the tap.
    var after by rememberSaveable(d.id) { mutableLongStateOf(Long.MAX_VALUE) }
    val action = d.herdrAction?.takeIf { it.action == "create" && it.seq > after }
    LaunchedEffect(action) {
        val pane = action?.pane
        if (action != null && !action.sending && action.error == null && pane != null) {
            HerdrSync.clearAction(FluxCore, d.id, action.seq)
            onOpened(action.what, pane)
        }
    }
    val busy = action?.sending == true

    Column(Modifier.fillMaxSize().imePadding().padding(horizontal = TiledGutter)) {
        TiledTopBar("new · ${d.name}", onBack)
        when {
            !d.online -> NotReachable(d, "herdr")
            herdr == null || !herdr.running -> EmptyState(
                Ic.agent, "herdr is not running", "Start herdr on ${d.name}. Then start agents from here.", Modifier.padding(top = 48.dp),
            )
            !herdr.control -> EmptyState(
                Ic.agent,
                "Control is off",
                "To start agents from this phone, set herdr_control = true on ${d.name}. Then run systemctl --user reload fluxd.",
                Modifier.padding(top = 48.dp),
            )
            kinds.isEmpty() && !shell -> EmptyState(
                Ic.agent,
                "No coding agent on ${d.name}",
                "Install a coding agent that herdr supports, such as Claude Code or Codex, on ${d.name}. It shows here within a minute.",
                Modifier.padding(top = 48.dp),
            )
            else -> {
                val choice = run
                val folders = remember(herdr) { folderChoices(herdr) }
                // A typed path is the folder at once. Enter or a tap on its row keeps it after the search.
                val target = if (looksLikePath(query)) normalFolder(query) else folder
                val match = workspaceFor(herdr, target)
                val workspace = if (match != null && !newWorkspace) match.id else ""
                fun start() {
                    val what = if (choice == SHELL_CHOICE) "terminal" else "agent"
                    val kind = choice ?: return
                    lockError = null
                    val last = d.herdrAction?.seq ?: 0L
                    ReplyLock.run(context, {
                        after = last
                        NewPanePrefs.save(context, d.id, kind, target)
                        HerdrSync.create(FluxCore, d.id, what, kind, target, workspace)
                    }, title = if (what == "agent") "Start an agent" else "Open a terminal", purpose = "start agents and terminals") {
                        lockError = it
                    }
                }
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(TileGap)) {
                    TileLabel("Run", Modifier.padding(start = 4.dp))
                    val options = kinds + if (shell) listOf(SHELL_CHOICE) else emptyList()
                    for (row in options.chunked(2)) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                            for (k in row) {
                                val running = if (k == SHELL_CHOICE) 0 else herdr.agents.count { it.agent == k }
                                RunTile(k, running, selected = k == choice, enabled = !busy, modifier = Modifier.weight(1f)) { run = k }
                            }
                            if (row.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }
                    if (kinds.isEmpty()) {
                        T("No coding agent is installed on ${d.name}.", Modifier.padding(horizontal = 4.dp), size = 11, color = Tn.dim)
                    }
                    TileLabel("Folder", Modifier.padding(start = 4.dp, top = 12.dp))
                    FolderPicker(folders, target, query, enabled = !busy, onQuery = { query = it }) {
                        folder = normalFolder(it)
                        query = ""
                        newWorkspace = false
                    }
                    Spacer(Modifier.height(8.dp))
                }
                StartBar(choice, target, match, newWorkspace, busy, lockError ?: action?.error, onNewWorkspace = { newWorkspace = it }, onStart = ::start)
            }
        }
    }
}

/**
 * One thing to run: an agent kind with its product name, or a terminal.
 * [running] counts the agents of the kind that run now.
 */
@Composable
private fun RunTile(choice: String, running: Int, selected: Boolean, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val terminal = choice == SHELL_CHOICE
    val accent = if (terminal) Tn.green else Tn.magenta
    Tile(
        modifier.height(68.dp), if (enabled) onClick else null,
        accent = accent,
        container = if (selected) Tn.tileHi else Tn.tile,
        border = BorderStroke(if (selected) 2.dp else 1.dp, if (selected) accent else Tn.line),
        padding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(if (terminal) Ic.terminal else Ic.agent, tint = accent, size = 20.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(if (terminal) "terminal" else choice, size = 14, weight = FontWeight.SemiBold, family = Mono, maxLines = 1)
                val sub = if (terminal) "a shell" else agentProduct(choice)
                val line = listOfNotNull(sub, if (running > 0) "$running running" else null).joinToString(" · ")
                if (line.isNotEmpty()) T(line, size = 11, color = Tn.dim, maxLines = 1)
            }
        }
    }
}

/**
 * The folder list: a search field, the folders of the workspaces, and the
 * typed path when the text is a path. A typed path is [selected]. The
 * selected folder shows first when the list does not have it. A dictation
 * replaces the search.
 */
@Composable
private fun FolderPicker(
    folders: List<FolderChoice>,
    selected: String,
    query: String,
    enabled: Boolean,
    onQuery: (String) -> Unit,
    onSelect: (String) -> Unit,
) {
    val voice = rememberVoiceTyping { onQuery(DictationText.query(it)) }
    VoiceField(voice, enabled = enabled) { m ->
        OutlinedTextField(
            value = query,
            onValueChange = onQuery,
            modifier = m,
            enabled = enabled,
            placeholder = { T("Search, or type a path such as ~/Code/app", color = Tn.dim, size = 13) },
            leadingIcon = { Sym(Ic.search, tint = Tn.dim, size = 20.dp) },
            textStyle = TextStyle(color = Tn.text, fontFamily = Mono, fontSize = 14.sp),
            shape = TileShape,
            singleLine = true,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { if (looksLikePath(query)) onSelect(query) }),
        )
    }
    val typed = normalFolder(query)
    if (looksLikePath(query) && folders.none { it.path == typed }) {
        FolderRow(FolderChoice(typed, folderName(typed), null, 0), selected = true, enabled = enabled, typed = true) { onSelect(typed) }
    }
    val shown = filterFolders(folders, if (looksLikePath(query)) "" else query)
    if (query.isEmpty() && folders.none { it.path == selected }) {
        FolderRow(FolderChoice(selected, folderName(selected), null, 0), selected = true, enabled = enabled) { }
    }
    for (f in shown) FolderRow(f, selected = f.path == selected, enabled = enabled) { onSelect(f.path) }
    if (shown.isEmpty() && !looksLikePath(query)) {
        T("No folder has \"$query\". Type a path that starts with ~/ or /.", Modifier.padding(horizontal = 4.dp), size = 12, color = Tn.dim)
    }
}

/** A folder: its name, its path, and the agents in its workspace. [typed] marks a new path from the search field. */
@Composable
private fun FolderRow(f: FolderChoice, selected: Boolean, enabled: Boolean, typed: Boolean = false, onClick: () -> Unit) {
    Tile(
        Modifier.fillMaxWidth().height(58.dp), if (enabled) onClick else null,
        container = if (selected) Tn.tileHi else Tn.tile,
        border = BorderStroke(if (selected) 2.dp else 1.dp, if (selected) Tn.blue else Tn.line),
        padding = PaddingValues(horizontal = 12.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(if (f.path == "~") Ic.home else Ic.folder, tint = if (selected || typed) Tn.blue else Tn.sub, size = 20.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(f.name, size = 14, weight = FontWeight.SemiBold, maxLines = 1)
                T(f.path, size = 11, color = Tn.dim, family = Mono, maxLines = 1)
            }
            if (typed) T("typed", size = 11, color = Tn.dim)
            if (f.agents > 0) T(if (f.agents == 1) "1 agent" else "${f.agents} agents", size = 11, color = Tn.dim)
            if (selected) Sym(Ic.check, "Selected", tint = Tn.blue, size = 18.dp)
        }
    }
}

/**
 * The bar at the bottom: where the pane opens, the last problem, and the
 * start key. When the folder has a workspace, the pane opens as a tab in
 * it, and a switch opens a new workspace instead.
 */
@Composable
private fun StartBar(
    choice: String?,
    folder: String,
    match: HerdrWorkspace?,
    newWorkspace: Boolean,
    busy: Boolean,
    problem: String?,
    onNewWorkspace: (Boolean) -> Unit,
    onStart: () -> Unit,
) {
    val terminal = choice == SHELL_CHOICE
    val canStart = choice != null && !busy
    Column(Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (match != null) {
            Row(Modifier.fillMaxWidth().height(40.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                ChoiceKey("New tab in ${match.label}", !newWorkspace, Modifier.weight(1f), enabled = !busy) { onNewWorkspace(false) }
                ChoiceKey("New workspace", newWorkspace, Modifier.weight(1f), enabled = !busy) { onNewWorkspace(true) }
            }
        } else {
            T("Opens in a new workspace, because no workspace has this folder.", Modifier.padding(horizontal = 4.dp), size = 11, color = Tn.dim)
        }
        if (problem != null) T(problem, Modifier.padding(horizontal = 4.dp), size = 12, color = Tn.red)
        Box(
            Modifier.fillMaxWidth().height(54.dp).clip(TileShape).background(if (canStart) Tn.blue else Tn.tile)
                .clickable(enabled = canStart, onClickLabel = if (terminal) "Open the terminal" else "Start the agent", onClick = onStart),
            contentAlignment = Alignment.Center,
        ) {
            Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                if (busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Tn.magenta)
                val where = folderName(folder)
                val label = when {
                    choice == null -> "Select what to run"
                    busy && terminal -> "Opening a terminal in $where"
                    busy -> "Starting $choice. This can take 30 seconds."
                    terminal -> "Open a terminal in $where"
                    else -> "Start $choice in $where"
                }
                T(label, size = 14, weight = FontWeight.SemiBold, color = if (canStart) Tn.onAccent else Tn.sub, maxLines = 1)
            }
        }
    }
}

/** A key of a 2-way choice, such as a new tab or a new workspace. */
@Composable
private fun ChoiceKey(label: String, selected: Boolean, modifier: Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Box(
        modifier.fillMaxSize().clip(RoundedCornerShape(8.dp)).background(if (selected) Tn.tileHi else Tn.tile)
            .border(1.dp, if (selected) Tn.blue else Tn.line, RoundedCornerShape(8.dp))
            .clickable(enabled = enabled, onClickLabel = label, onClick = onClick)
            .padding(horizontal = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        T(label, size = 12, color = if (selected) Tn.blue else Tn.sub, weight = FontWeight.SemiBold, maxLines = 1)
    }
}

// ───────────────────────── One terminal ─────────────────────────

/**
 * A herdr terminal: its recent output in terminal colors, a key bar, and
 * a command field. The screen reads the output again every few seconds
 * while it is on screen. Each input asks for the phone lock first, see
 * [ReplyLock].
 */
@Composable
fun TiledTerminalScreen(d: DeviceUi, pane: String, onBack: () -> Unit) {
    val herdr = d.herdr
    val term = herdr?.terminal(pane)
    val demo = isDemo(d.id)
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    // A poll waits while the last read did not end, so that reads do not pile up on a slow link.
    val loading by rememberUpdatedState(d.herdrOutput?.takeIf { it.pane == pane }?.loading == true)
    // The polls stop when the terminal closes or the computer turns terminals off.
    val alive = herdr == null || (herdr.terminals && term != null)
    LaunchedEffect(d.id, pane, d.online, alive) {
        if (!d.online || demo || !alive) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                if (!loading) HerdrSync.read(FluxCore, d.id, pane)
                delay(TERMINAL_REFRESH_MS)
            }
        }
    }
    DisposableEffect(d.id, pane) { onDispose { HerdrSync.closeOutput(FluxCore, d.id, pane) } }

    val out = d.herdrOutput?.takeIf { it.pane == pane }
    val closer = rememberPaneCloser(d, pane, onBack)
    val label = "terminal · ${term?.project?.ifEmpty { null } ?: pane}"
    Column(Modifier.fillMaxSize().imePadding().padding(horizontal = TiledGutter)) {
        TiledTopBar(label, onBack) {
            if (out?.loading == true && out.lines.isNotEmpty()) {
                Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Tn.magenta)
                }
            } else if (d.online && term != null && !demo) {
                SquareButton(Ic.refresh, "Refresh", { HerdrSync.read(FluxCore, d.id, pane) })
            }
        }
        when {
            !d.online -> NotReachable(d, "The terminal")
            herdr != null && !herdr.terminals -> EmptyState(
                Ic.terminal,
                "Terminals are off",
                "To use herdr terminals from this phone, set herdr_terminals = true on ${d.name}. It needs herdr_control = true too.",
                Modifier.padding(top = 48.dp),
            )
            term == null && herdr != null -> EmptyState(
                Ic.terminal, "The terminal is gone", "The terminal $pane on ${d.name} closed.", Modifier.padding(top = 48.dp),
            )
            else -> {
                Tile(Modifier.fillMaxWidth(), padding = PaddingValues(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Sym(Ic.terminal, tint = Tn.green, size = 18.dp)
                        T(term?.title?.ifEmpty { null } ?: "shell", Modifier.weight(1f), size = 13, weight = FontWeight.SemiBold, family = Mono, maxLines = 1)
                        T(pane, size = 10, color = Tn.dim, family = Mono, maxLines = 1)
                        closer.Button()
                    }
                    closer.error?.let { T(it, size = 11, color = Tn.red) }
                }
                Spacer(Modifier.height(TileGap))
                AgentOutput(out, Modifier.weight(1f))
                Spacer(Modifier.height(TileGap))
                TerminalControls(d, pane, d.herdrReply?.takeIf { it.pane == pane })
                Spacer(Modifier.height(12.dp))
            }
        }
    }
    closer.Dialog("Close this terminal?", "herdr closes $pane on ${d.name}. The shell and its command stop.")
}

/** The key bar and the command field of a terminal. Send types the command and presses Enter. */
@Composable
private fun TerminalControls(d: DeviceUi, pane: String, reply: HerdrReply?) {
    val context = LocalContext.current
    var field by rememberSaveable(d.id, pane, stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue()) }
    var lockError by remember { mutableStateOf<String?>(null) }
    // Only an input with the text of the field empties the field.
    var sentText by remember { mutableStateOf(false) }
    LaunchedEffect(reply) {
        if (reply == null || reply.action != "input" || reply.sending) return@LaunchedEffect
        if (sentText && reply.error == null) field = TextFieldValue()
        sentText = false
    }
    fun guarded(action: () -> Unit) {
        lockError = null
        ReplyLock.run(context, action, title = "Type in a terminal", purpose = "type in terminals") { lockError = it }
    }
    fun keys(vararg k: String) = guarded { HerdrSync.sendInput(FluxCore, d.id, pane, "", k.toList()) }
    fun send() {
        val t = field.text
        if (t.isEmpty()) {
            keys("enter")
            return
        }
        guarded {
            sentText = true
            HerdrSync.sendInput(FluxCore, d.id, pane, t, listOf("enter"))
        }
    }
    val sending = reply?.sending == true && sentText
    // Dictation puts a command at the cursor. It waits there for Run, so a command still needs the phone lock.
    val voice = rememberVoiceTyping { spoken ->
        val e = DictationText.insert(field.text, field.selection.start, field.selection.end, DictationText.command(spoken), sentences = false)
        field = TextFieldValue(e.text, TextRange(e.cursor))
    }
    Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
        Row(Modifier.fillMaxWidth().height(40.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            KeyTile("esc", "Escape", Modifier.weight(1f)) { keys("esc") }
            KeyTile("tab", "Tab", Modifier.weight(1f)) { keys("tab") }
            KeyTile("^C", "Control C", Modifier.weight(1f)) { keys("ctrl+c") }
            KeyTile("^D", "Control D", Modifier.weight(1f)) { keys("ctrl+d") }
            KeyTile("↑", "Up", Modifier.weight(1f)) { keys("up") }
            KeyTile("↓", "Down", Modifier.weight(1f)) { keys("down") }
            KeyTile("enter", "Enter", Modifier.weight(1.4f)) { keys("enter") }
        }
        VoiceField(
            voice,
            send = {
                Box(
                    Modifier.size(56.dp).clip(TileShape).background(if (!sending) Tn.blue else Tn.tile)
                        .clickable(enabled = !sending, onClickLabel = "Run") { send() },
                    contentAlignment = Alignment.Center,
                ) {
                    if (sending) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Tn.magenta)
                    } else {
                        Sym(Ic.send, "Run", tint = Tn.onAccent, size = 22.dp)
                    }
                }
            },
        ) { m ->
            OutlinedTextField(
                value = field,
                onValueChange = { field = it },
                modifier = m,
                placeholder = { T("Type a command", color = Tn.dim, family = Mono) },
                textStyle = TextStyle(color = Tn.text, fontFamily = Mono, fontSize = 14.sp),
                shape = TileShape,
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Send,
                ),
                keyboardActions = KeyboardActions(onSend = { send() }),
            )
        }
        val problem = lockError ?: reply?.error
        if (problem != null) T(problem, Modifier.padding(horizontal = 4.dp), size = 11, color = Tn.red)
    }
}
