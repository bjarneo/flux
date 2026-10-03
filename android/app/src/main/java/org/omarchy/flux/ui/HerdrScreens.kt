package org.omarchy.flux.ui

import android.content.Context
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
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
        TiledTopBar("New agent or terminal", onBack, context = d.name)
        when {
            !d.online -> NotReachable(d, "The agents that you can start")
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
                    TileLabel("Run", Modifier.padding(start = 4.dp).semantics { heading() })
                    val options = kinds + if (shell) listOf(SHELL_CHOICE) else emptyList()
                    Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(TileGap)) {
                        for (row in options.chunked(2)) {
                            TileRow(68.dp) {
                                for (k in row) {
                                    val running = if (k == SHELL_CHOICE) 0 else herdr.agents.count { it.agent == k }
                                    RunTile(k, running, selected = k == choice, enabled = !busy, modifier = Modifier.weight(1f).fillMaxHeight()) { run = k }
                                }
                                if (row.size == 1) Spacer(Modifier.weight(1f))
                            }
                        }
                    }
                    if (kinds.isEmpty()) {
                        T("No coding agent is installed on ${d.name}.", Modifier.padding(horizontal = 4.dp), size = 12, color = Tn.sub)
                    }
                    TileLabel("Folder", Modifier.padding(start = 4.dp, top = 12.dp).semantics { heading() })
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
 * [running] counts the agents of the kind that run now. The selected tile
 * takes the selection color, the accent.
 */
@Composable
private fun RunTile(choice: String, running: Int, selected: Boolean, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val terminal = choice == SHELL_CHOICE
    val accent = if (terminal) Tn.green else Tn.magenta
    Tile(
        modifier.heightIn(min = 68.dp), onClick,
        accent = Tn.blue,
        container = choiceFill(selected),
        border = choiceBorder(selected),
        enabled = enabled,
        padding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.Center,
        selected = selected,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(if (terminal) Ic.terminal else Ic.agent, tint = accent, size = 20.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(if (terminal) "terminal" else choice, size = 14, weight = FontWeight.SemiBold, family = Mono)
                val sub = if (terminal) "a shell" else agentProduct(choice)
                val line = listOfNotNull(sub, if (running > 0) "$running running" else null).joinToString(" · ")
                if (line.isNotEmpty()) T(line, size = 12, color = Tn.sub)
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
            placeholder = { T("Search, or type a path such as ~/Code/app", color = Tn.sub, size = 13) },
            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Tn.blue, unfocusedBorderColor = Tn.dim),
            leadingIcon = { Sym(Ic.search, tint = Tn.dim, size = 20.dp) },
            trailingIcon = if (query.isEmpty()) null else { { ClearKey({ onQuery("") }, "Clear the search") } },
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
        T("No folder has \"$query\". Type a path that starts with ~/ or /.", Modifier.padding(horizontal = 4.dp), size = 13, color = Tn.sub)
    }
}

/** A folder: its name, its path, and the agents in its workspace. [typed] marks a new path from the search field. */
@Composable
private fun FolderRow(f: FolderChoice, selected: Boolean, enabled: Boolean, typed: Boolean = false, onClick: () -> Unit) {
    Tile(
        Modifier.fillMaxWidth().heightIn(min = 58.dp), onClick,
        container = choiceFill(selected),
        border = choiceBorder(selected),
        enabled = enabled,
        padding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.Center,
        selected = selected,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(if (f.path == "~") Ic.home else Ic.folder, tint = if (selected || typed) Tn.blue else Tn.sub, size = 20.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(f.name, size = 14, weight = FontWeight.SemiBold)
                T(f.path, size = 12, color = Tn.sub, family = Mono, maxLines = 2)
            }
            if (typed) T("typed", size = 12, color = Tn.sub)
            if (f.agents > 0) T(if (f.agents == 1) "1 agent" else "${f.agents} agents", size = 12, color = Tn.sub)
            if (selected) Sym(Ic.check, tint = Tn.blue, size = 18.dp)
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
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).selectableGroup(), horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                ChoiceChip("New tab in ${match.label}", !newWorkspace, { onNewWorkspace(false) }, Modifier.weight(1f).fillMaxHeight(), enabled = !busy)
                ChoiceChip("New workspace", newWorkspace, { onNewWorkspace(true) }, Modifier.weight(1f).fillMaxHeight(), enabled = !busy)
            }
        } else {
            T("Opens in a new workspace, because no workspace has this folder.", Modifier.padding(horizontal = 4.dp), size = 12, color = Tn.sub)
        }
        if (problem != null) T(problem, Modifier.padding(horizontal = 4.dp), size = 12, color = Tn.red)
        val where = folderName(folder)
        val label = when {
            choice == null -> "Select what to run"
            busy && terminal -> "Opening a terminal in $where"
            busy -> "Starting $choice. This can take 30 seconds."
            terminal -> "Open a terminal in $where"
            else -> "Start $choice in $where"
        }
        FluxButton(label, onStart, Modifier.fillMaxWidth().heightIn(min = 54.dp), enabled = canStart || busy, busy = busy)
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
    val title = term?.project?.ifEmpty { null } ?: pane
    Column(Modifier.fillMaxSize().imePadding().padding(horizontal = TiledGutter)) {
        TiledTopBar(title, onBack, context = "terminal · ${d.name}") {
            if (out?.loading == true && out.lines.isNotEmpty()) {
                SquareSpinner("Reading the output")
            } else if (d.online && term != null && !demo) {
                SquareButton(Ic.refresh, "Refresh", { HerdrSync.read(FluxCore, d.id, pane) })
            }
        }
        when {
            !d.online -> NotReachable(d, "The lines of the terminal")
            herdr != null && !herdr.terminals -> EmptyState(
                Ic.terminal,
                "Terminals are off",
                "To use herdr terminals from this phone, set herdr_terminals = true on ${d.name}. It needs herdr_control = true too.",
                Modifier.padding(top = 48.dp),
            )
            term == null && herdr != null -> EmptyState(
                Ic.terminal, "The terminal is gone", "The terminal $pane on ${d.name} closed.", Modifier.padding(top = 48.dp),
            )
            else -> PaneLayout(
                Modifier.weight(1f),
                header = { TerminalHeader(term?.title?.ifEmpty { null } ?: "shell", pane, closer) },
                output = { m -> AgentOutput(out, m) },
                controls = { TerminalControls(d, pane, d.herdrReply?.takeIf { it.pane == pane }) },
            )
        }
    }
    closer.Dialog("Close this terminal?", "herdr closes $pane on ${d.name}. The shell and its command stop.")
}

/** The header of a terminal: the terminal title, the pane, the Close key, and the last close problem. */
@Composable
private fun TerminalHeader(title: String, pane: String, closer: PaneCloser) {
    Tile(Modifier.fillMaxWidth(), padding = PaddingValues(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(Ic.terminal, tint = Tn.green, size = 18.dp)
            T(title, Modifier.weight(1f), size = 13, weight = FontWeight.SemiBold, family = Mono, maxLines = 2)
            T(pane, size = 11, color = Tn.sub, family = Mono)
            closer.Button()
        }
        closer.error?.let { T(it, size = 12, color = Tn.red) }
    }
}

/** The key bar and the command field of a terminal. Send types the command and presses Enter. */
@Composable
private fun TerminalControls(d: DeviceUi, pane: String, reply: HerdrReply?) {
    val context = LocalContext.current
    var field by rememberSaveable(d.id, pane, stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue()) }
    var lockError by remember { mutableStateOf<String?>(null) }
    // True while the large editor of the field shows.
    var editing by remember { mutableStateOf(false) }
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
        // The 7 keys have the same width. Then 48 dp keys fit in 1 row on a window that is 404 dp wide or more.
        KeyBar(
            listOf(
                BarKey("esc", "Escape") { keys("esc") },
                BarKey("tab", "Tab") { keys("tab") },
                BarKey("^C", "Control C") { keys("ctrl+c") },
                BarKey("^D", "Control D") { keys("ctrl+d") },
                BarKey("↑", "Up") { keys("up") },
                BarKey("↓", "Down") { keys("down") },
                BarKey("enter", "Enter") { keys("enter") },
            ),
        )
        VoiceField(
            voice,
            send = { FieldKey("Run", onClick = { send() }, busy = sending) { Sym(Ic.send, size = 22.dp) } },
        ) { m ->
            OutlinedTextField(
                value = field,
                onValueChange = { field = it },
                modifier = m,
                placeholder = { T("Type a command", color = Tn.sub, family = Mono) },
                trailingIcon = { FieldKeys(field.text.isNotEmpty(), { field = TextFieldValue() }, { editing = true }) },
                textStyle = TextStyle(color = Tn.text, fontFamily = Mono, fontSize = 14.sp),
                shape = TileShape,
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Send,
                ),
                keyboardActions = KeyboardActions(onSend = { send() }),
            )
        }
        if (editing) {
            FieldEditor(
                title = "Type a command",
                value = field,
                onValueChange = { field = it },
                onDismiss = { editing = false },
                context = d.name,
                placeholder = "A command for the terminal",
                mono = true,
                keyboard = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
            ) {
                FluxButton("Run", {
                    editing = false
                    send()
                }, icon = Ic.send, busy = sending)
            }
        }
        val problem = lockError ?: reply?.error
        if (problem != null) T(problem, Modifier.padding(horizontal = 4.dp), size = 12, color = Tn.red)
    }
}
