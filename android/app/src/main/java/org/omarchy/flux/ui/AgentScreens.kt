package org.omarchy.flux.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.CancellationSignal
import android.os.SystemClock
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.omarchy.flux.core.AgentChoice
import org.omarchy.flux.core.AgentStatus
import org.omarchy.flux.core.ComputerThemes
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.HERDR_BLOCKED
import org.omarchy.flux.core.HerdrAgent
import org.omarchy.flux.core.HerdrOutput
import org.omarchy.flux.core.HerdrReply
import org.omarchy.flux.core.HerdrState
import org.omarchy.flux.core.HerdrSync
import org.omarchy.flux.core.HerdrTerminal
import org.omarchy.flux.core.HerdrTerminalSession
import org.omarchy.flux.core.choicesOpen
import org.omarchy.flux.core.terminalClosePending
import org.omarchy.flux.core.terminalControlReady
import org.omarchy.flux.mic.MicSession
import org.omarchy.flux.voice.Dictation
import org.omarchy.flux.voice.DictationBar
import org.omarchy.flux.voice.DictationSettings
import org.omarchy.flux.voice.DictationText
import org.omarchy.flux.voice.LanguageSheet
import org.omarchy.flux.voice.rememberDictation
import org.omarchy.flux.voice.rememberSpeechModels

/** How often the agent screen reads the output again while the agent works. */
private const val WORKING_REFRESH_MS = 5_000L

/** The color of the status dot and of the pressed border of an agent tile. */
@Composable
@ReadOnlyComposable
private fun statusColor(s: AgentStatus): Color = when (s) {
    AgentStatus.Blocked -> Tn.red
    AgentStatus.Done -> Tn.green
    AgentStatus.Working -> Tn.blue
    AgentStatus.Idle, AgentStatus.Unknown -> Tn.dim
}

/** The color of the status word. The dim color is not for text, so an idle or unknown status takes the second ink. */
@Composable
@ReadOnlyComposable
private fun statusInk(s: AgentStatus): Color = when (s) {
    AgentStatus.Idle, AgentStatus.Unknown -> Tn.sub
    else -> statusColor(s)
}

private fun statusLabel(s: AgentStatus): String = when (s) {
    AgentStatus.Blocked -> "Needs input"
    AgentStatus.Done -> "Done"
    AgentStatus.Working -> "Working"
    AgentStatus.Idle -> "Idle"
    AgentStatus.Unknown -> "Unknown"
}

/** The size and the line height of the window-title line. */
private val WindowTitleSize = 12.sp
private val WindowTitleLine = 16.sp

/**
 * The window-title line of an agent: a status dot, the status as 1 short
 * word in its color, and the [parts] in mono, such as the agent and the
 * project. For example: Needs input · codex · billing. The status comes
 * first, as on the Inbox tiles. From a font scale of 1.3, the parts start on
 * a new line, so that the line does not wrap at a separator. TalkBack reads
 * the parts, and the status as the state.
 */
@Composable
private fun WindowTitle(parts: List<String>, s: AgentStatus, modifier: Modifier = Modifier) {
    val label = statusLabel(s)
    val sub = Tn.sub
    val ink = statusInk(s)
    val split = LocalDensity.current.fontScale >= 1.3f
    val text = remember(parts, label, sub, ink, split) {
        buildAnnotatedString {
            withStyle(SpanStyle(color = ink, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Default)) { append(label) }
            if (parts.isNotEmpty()) withStyle(SpanStyle(color = sub)) { append((if (split) "\n" else " · ") + parts.joinToString(" · ")) }
        }
    }
    val line = with(LocalDensity.current) { WindowTitleLine.toDp() }
    Row(
        modifier.semantics { stateDescription = label },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.Top,
    ) {
        // The dot stays at the middle of the first line when the line wraps.
        Box(Modifier.height(line), contentAlignment = Alignment.Center) { Dot(statusColor(s), 7.dp) }
        BasicText(
            text,
            Modifier.clearAndSetSemantics { if (parts.isNotEmpty()) contentDescription = parts.joinToString(", ") },
            style = TextStyle(fontFamily = Mono, fontSize = WindowTitleSize, lineHeight = WindowTitleLine),
        )
    }
}

// ───────────────────────── Agents ─────────────────────────

/**
 * The herdr agents of a computer. The agents that need input come first.
 * A tap opens the recent output of the agent. When the computer allows
 * terminals, they follow the agents. When the computer allows control,
 * the add button opens a new agent or terminal.
 */
@Composable
fun TiledAgentsScreen(
    d: DeviceUi,
    onBack: () -> Unit,
    onOpen: (String) -> Unit,
    onOpenTerminal: (String) -> Unit = {},
    onNew: () -> Unit = {},
) {
    LaunchedEffect(d.id, d.online) { if (d.online) HerdrSync.request(FluxCore, d.id) }
    val herdr = d.herdr
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter)) {
        TiledTopBar("Agents", onBack, context = d.name) {
            if (d.online && herdr?.running == true && herdr.control) SquareButton(Ic.add, "New agent or terminal", onNew)
            if (d.online) SquareButton(Ic.refresh, "Refresh", { HerdrSync.request(FluxCore, d.id) })
        }
        when {
            !d.online -> NotReachable(d, "The agents")
            herdr == null -> LineSkeleton("Loading the agents of ${d.name}", Modifier.padding(4.dp), lines = listOf(0.7f, 0.5f, 0.6f))
            !herdr.enabled -> EmptyState(
                Ic.agent,
                "Agent status is off",
                "On ${d.name}, set herdr = true in ~/.config/flux/config.toml. Then run systemctl --user reload fluxd.",
                Modifier.padding(top = 48.dp),
            )
            !herdr.running -> EmptyState(
                Ic.agent,
                "herdr is not running",
                "Start herdr on ${d.name}. Its coding agents show here.",
                Modifier.padding(top = 48.dp),
            )
            herdr.agents.isEmpty() && herdr.panes.isEmpty() -> EmptyState(
                Ic.agent,
                "No agents yet",
                if (herdr.control) {
                    "Select New agent or terminal to start an agent on ${d.name}, or start one in a herdr pane there."
                } else {
                    "Start a coding agent in a herdr pane on ${d.name}. It shows here."
                },
                Modifier.padding(top = 48.dp),
            )
            else -> Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
                for (a in herdr.sorted) AgentTile(a) { onOpen(a.pane) }
                if (herdr.panes.isNotEmpty()) {
                    TileLabel("Terminals", Modifier.padding(start = 4.dp, top = 12.dp).semantics { heading() })
                    for (t in herdr.panes) TerminalTile(t) { onOpenTerminal(t.pane) }
                }
            }
        }
        Spacer(Modifier.height(96.dp))
    }
}

/**
 * An agent: the window-title line with the agent, its place, and its
 * status, and the task of the agent under it. Without a task, the project
 * shows in its place.
 */
@Composable
private fun AgentTile(a: HerdrAgent, onClick: () -> Unit) {
    val blocked = a.status == AgentStatus.Blocked
    val task = a.title.ifEmpty { a.project.ifEmpty { a.pane } }
    // The window title does not repeat the task.
    val parts = listOf(a.agent, a.project, a.workspace).filter { it.isNotEmpty() && it != task }.distinct()
    Tile(
        Modifier.fillMaxWidth().heightIn(min = 72.dp), onClick,
        accent = statusColor(a.status),
        container = if (blocked) Tn.tileHi else Tn.tile,
        border = BorderStroke(1.dp, if (blocked) Tn.red else Tn.line),
        padding = PaddingValues(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
    ) {
        WindowTitle(parts, a.status)
        T(task, size = 15, weight = FontWeight.SemiBold, maxLines = 2)
    }
}

/** A herdr terminal: its folder, its workspace, and the terminal title. */
@Composable
private fun TerminalTile(t: HerdrTerminal, onClick: () -> Unit) {
    Tile(
        Modifier.fillMaxWidth().heightIn(min = 72.dp), onClick, accent = Tn.green,
        padding = PaddingValues(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(Ic.terminal, tint = Tn.green, size = 18.dp)
            T(t.project.ifEmpty { t.pane }, Modifier.weight(1f), size = 14, weight = FontWeight.SemiBold)
            if (t.workspace.isNotEmpty() && t.workspace != t.project) T(t.workspace, size = 11, color = Tn.sub, family = Mono)
            T(t.pane, size = 11, color = Tn.sub, family = Mono)
        }
        T(t.title.ifEmpty { "shell" }, size = 12, color = Tn.sub, family = Mono, maxLines = 2)
    }
}

// ───────────────────────── One agent ─────────────────────────

/**
 * The recent output of one herdr agent in terminal colors, with the newest
 * lines at the bottom. The screen reads the output again when the status
 * changes, and every few seconds while the agent works and the screen is
 * visible. When the computer allows it, the screen also sends keys and text
 * to the agent. When the computer also allows terminal control, the Live key
 * shows the live terminal of the pane in the place of the output.
 */
@Composable
fun TiledAgentScreen(d: DeviceUi, pane: String, onBack: () -> Unit) {
    var review by rememberSaveable(d.id, pane) { mutableStateOf(false) }
    var reviewPath by rememberSaveable(d.id, pane) { mutableStateOf("") }
    var appliedReviewPath by rememberSaveable(d.id, pane) { mutableStateOf("") }
    // True while the live terminal shows in the place of the output.
    var live by rememberSaveable(d.id, pane) { mutableStateOf(false) }
    // Why the live terminal ended by itself, or null.
    var liveNote by rememberSaveable(d.id, pane) { mutableStateOf<String?>(null) }
    // True from a tap on Live until the unlock succeeds or Live ends. A
    // terminal that opens again without a tap, for example after the
    // computer connects again, opens only while the unlock is valid. A
    // link that drops during the unlock prompt keeps it true, so the
    // prompt shows again after the reconnect.
    var liveAsk by remember(d.id, pane) { mutableStateOf(false) }
    val reviewText = Tn.text
    fun readReview() {
        appliedReviewPath = reviewPath
        HerdrSync.read(FluxCore, d.id, pane, review = true, path = appliedReviewPath)
    }
    val agent = d.herdr?.agent(pane)
    val status = agent?.status
    val demo = isDemo(d.id)
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    // A poll waits while the last read did not end, so that reads do not pile up on a slow link.
    val loading by rememberUpdatedState(d.herdrOutput?.takeIf { it.pane == pane }?.loading == true)
    // The polls stop when the agent is gone.
    val alive = agent != null || d.herdr == null
    val liveShown = live && !review
    // True while the last read effect ran with the live terminal on.
    var liveBefore by remember(d.id, pane) { mutableStateOf(false) }
    LaunchedEffect(d.id, pane, d.online, status, alive, review, appliedReviewPath, liveShown) {
        // After Live ends, the computer gives the pane its desktop size
        // back, and the agent draws the pane again. A read at once gets a
        // half-drawn screen, so the first read waits for the redraw.
        var redraw = liveBefore && !liveShown
        liveBefore = liveShown
        if (!d.online || demo || !alive) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            if (redraw) {
                redraw = false
                delay(LIVE_REDRAW_MS)
            }
            // A new status reads at once. Only the polls wait for the last read.
            HerdrSync.read(FluxCore, d.id, pane, review = review, path = appliedReviewPath)
            // The live terminal shows the newest lines itself. Its reads
            // only keep the choices current, so they do not poll.
            while (status == AgentStatus.Working && !liveShown) {
                delay(WORKING_REFRESH_MS)
                if (!loading) HerdrSync.read(FluxCore, d.id, pane, review = review, path = appliedReviewPath)
            }
        }
    }
    DisposableEffect(d.id, pane) { onDispose { HerdrSync.closeOutput(FluxCore, d.id, pane) } }

    val out = d.herdrOutput?.takeIf { it.pane == pane }
    val closer = rememberPaneCloser(d, pane, onBack)
    val title = agent?.project?.ifEmpty { null } ?: agent?.agent ?: pane
    val context = listOfNotNull(agent?.agent?.takeIf { it != title }, d.name).joinToString(" · ")
    // A demo computer shows the debug sample screen in Live, with no unlock and no input.
    val sample = if (demo) terminalDebugSample() else null
    val offered = liveOffered(d.online, agent != null, d.herdr, demo, sample != null)
    // The live terminal runs above the layout, so a rotation that moves
    // the output keeps its stream and its page.
    val terminal = if (liveShown && d.online && (agent != null || d.herdr == null)) {
        key(d.id, pane) {
            rememberLiveTerminal(d, pane, sample, ask = liveAsk, onAsked = { liveAsk = false }) { reason ->
                live = false
                liveAsk = false
                liveNote = reason
            }
        }
    } else {
        null
    }
    // fluxd sends the state without the agent before it closes the stream,
    // and the terminal leaves the screen with the agent. So the state ends
    // Live, and a new agent in the same pane needs a new tap on Live.
    val gone = liveGoneReason(d.herdr, pane, d.name)
    LaunchedEffect(live, gone) {
        if (live && gone != null) {
            live = false
            liveAsk = false
            liveNote = gone
        }
    }
    val terminalInput = remember(d.id, pane) { TerminalInput() }
    val direct = liveInputOffered(terminal != null, d.herdr, sample != null)
    Column(Modifier.fillMaxSize().imePadding().padding(horizontal = TiledGutter)) {
        TiledTopBar(title, onBack, context = context) {
            // The key stays while Live is on, so that Live can always stop.
            if (!review && (live || offered)) {
                LiveKey(live) {
                    if (live) {
                        live = false
                    } else {
                        liveNote = null
                        liveAsk = !demo
                        live = true
                    }
                }
            }
            if (!liveShown) {
                if (out?.loading == true && out.lines.isNotEmpty()) {
                    SquareSpinner("Reading the output")
                } else if (d.online && agent != null && !demo) {
                    SquareButton(Ic.refresh, "Refresh", { HerdrSync.read(FluxCore, d.id, pane) })
                }
            }
        }
        when {
            !d.online -> NotReachable(d, "The lines of the agent")
            agent == null && d.herdr != null -> {
                // The line tells why Live ended with the agent. An older
                // reason does not show here.
                liveNote?.takeIf { it == gone }?.let { LiveNote(it) }
                EmptyState(
                    Ic.agent,
                    "The agent is gone",
                    "The agent in $pane on ${d.name} stopped or moved to another pane.",
                    Modifier.padding(top = 48.dp),
                )
            }
            else -> PaneLayout(
                Modifier.weight(1f),
                header = {
                    Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
                        if (agent != null) AgentHeader(agent, closer.takeIf { d.herdr?.control == true })
                        if (d.herdr?.review == true) {
                            Row(Modifier.fillMaxWidth().selectableGroup(), horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                                ChoiceChip("Output", !review, {
                                    review = false
                                    HerdrSync.read(FluxCore, d.id, pane, review = false)
                                }, Modifier.weight(1f), role = Role.Tab)
                                ChoiceChip("Changes", review, {
                                    review = true
                                    live = false
                                    readReview()
                                }, Modifier.weight(1f), role = Role.Tab)
                            }
                            if (review) OutlinedTextField(
                                value = reviewPath, onValueChange = { reviewPath = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                                placeholder = { T("File path, or leave empty for all changes", color = reviewText) },
                                textStyle = TextStyle(color = reviewText, fontSize = 14.sp), shape = TileShape,
                                keyboardActions = KeyboardActions(onDone = { readReview() }),
                                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done, autoCorrectEnabled = false),
                            )
                        }
                    }
                },
                output = { m ->
                    Column(m, verticalArrangement = Arrangement.spacedBy(TileGap)) {
                        if (!review) liveNote?.let { LiveNote(it) }
                        if (terminal != null) {
                            LiveTerminalView(
                                terminal, d, pane, sample,
                                Modifier.weight(1f).fillMaxWidth(), terminalInput,
                            )
                        } else {
                            AgentOutput(out, Modifier.weight(1f))
                        }
                    }
                },
                controls = {
                    if (agent != null && d.herdr?.control == true) {
                        if (!review && direct) {
                            DirectTerminalControls(agent, out, terminalInput)
                        } else {
                            ReplyControls(d, agent, out.takeUnless { review }, d.herdrReply?.takeIf { it.pane == pane },
                                if (review) appliedReviewPath else null, reviewReady = !review || (out?.loading == false && out.error == null))
                        }
                    } else if (agent != null) {
                        T(
                            "To answer from this phone, set herdr_control = true on ${d.name}.",
                            Modifier.padding(horizontal = 4.dp), size = 12, color = Tn.sub,
                        )
                    }
                },
            )
        }
    }
    closer.Dialog("Close ${agent?.agent ?: "the agent"}?", "herdr closes $pane on ${d.name}, and the agent in it stops.")
}

/**
 * True when the agent screen offers Live: on a demo computer with a
 * sample screen, or when the computer is [online], the [agent] runs, and
 * [herdr] allows terminal control.
 */
internal fun liveOffered(online: Boolean, agent: Boolean, herdr: HerdrState?, demo: Boolean, sample: Boolean): Boolean =
    if (demo) sample else online && agent && herdr?.liveTerminal == true

/** Direct controls replace the composer only in an opted-in, non-demo Live view. */
internal fun liveInputOffered(live: Boolean, herdr: HerdrState?, sample: Boolean): Boolean =
    live && !sample && herdr?.liveTerminal == true && herdr.terminalInput

/**
 * The reason that ends Live when the agent of [pane] is not in [herdr],
 * or null while the agent runs or no state arrived. The reason is the
 * same as the reason of the terminal_closed that fluxd sends later.
 * [computer] is the name of the computer.
 */
internal fun liveGoneReason(herdr: HerdrState?, pane: String, computer: String): String? {
    if (herdr == null || herdr.agent(pane) != null) return null
    val code = when {
        !herdr.enabled || !herdr.running -> "stopped"
        // Without terminals, the state does not list the panes, so a closed pane looks like an ended agent.
        herdr.terminals && herdr.terminal(pane) == null -> "pane_closed"
        else -> "agent_ended"
    }
    return liveEndReason(code, computer)
}

/**
 * The Live key of the top bar. It shows the live terminal in the place of
 * the output, and a second tap stops it. It has the accent color while
 * [on], and TalkBack reads what a tap does.
 */
@Composable
private fun LiveKey(on: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    val ink = if (on) Tn.blue else Tn.sub
    val description = if (on) "Stop the live terminal" else "Show the live terminal"
    Row(
        Modifier.minimumInteractiveComponentSize().heightIn(min = 40.dp).clip(shape)
            .background(if (on) Tn.accentTile else Tn.tile).border(1.dp, if (on) Tn.blue else Tn.line, shape)
            .clickable(onClickLabel = description, role = Role.Button, onClick = onClick)
            .clearAndSetSemantics { contentDescription = description }
            .padding(start = 10.dp, end = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(Ic.terminal, tint = ink, size = 18.dp)
        T("Live", size = 13, color = if (on) Tn.blue else Tn.text, weight = FontWeight.SemiBold)
    }
}

/** The line above the output that tells why Live ended by itself. TalkBack reads it when it shows. */
@Composable
private fun LiveNote(text: String) {
    T(
        text, Modifier.padding(horizontal = 4.dp).semantics { liveRegion = LiveRegionMode.Polite },
        size = 12, color = Tn.sub, lineHeight = 1.3f,
    )
}

/**
 * The header of an agent in 1 row, so that the output gets the height: the
 * window-title line with the pane and the status, the task of the agent
 * under it in 1 line, and the Close key. The top bar already names the
 * agent and the project.
 */
@Composable
private fun AgentHeader(a: HerdrAgent, closer: PaneCloser?) {
    Tile(Modifier.fillMaxWidth(), padding = PaddingValues(horizontal = 14.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                WindowTitle(listOf(a.pane), a.status)
                if (a.title.isNotEmpty()) T(a.title, size = 13, weight = FontWeight.SemiBold, maxLines = 1)
            }
            closer?.Button()
        }
        closer?.error?.let { T(it, size = 12, color = Tn.red) }
    }
}

// ───────────────────────── Pane layout ─────────────────────────

/** The fewest lines of output that the agent and terminal screens show, at each font size. */
private const val OUTPUT_MIN_LINES = 8

/** The line height of [TermLines]. It grows with the font size. */
private val TermLineHeight = 16.sp

/** The space above and below the lines in the output. */
private val OutputPadding = 10.dp

/** The part of a wide window that the controls take. The output takes the rest. */
private const val CONTROLS_PART = 0.4f

/** The narrowest controls pane on a wide window, unless that is more than half of the window. */
private val ControlsMinWidth = 320.dp

/** The space under the controls, above the bottom edge of the screen. */
private val ControlsEnd = 12.dp

/**
 * The part of the agent and terminal screens under the top bar: the
 * [header], the [output], and the [controls]. On a narrow window, the 3
 * parts stack. The output takes the free height, and at least
 * [OUTPUT_MIN_LINES] lines. When the parts do not fit, for example at a
 * large font size, the column scrolls, so that no part gets clipped. On a
 * wide window, the output takes the left pane, and the header and the
 * controls take the right pane.
 */
@Composable
internal fun PaneLayout(
    modifier: Modifier,
    header: @Composable () -> Unit,
    output: @Composable (Modifier) -> Unit,
    controls: @Composable () -> Unit,
) {
    if (rememberWideWindow()) {
        BoxWithConstraints(modifier.fillMaxWidth()) {
            val side = maxOf(maxWidth * CONTROLS_PART, minOf(ControlsMinWidth, maxWidth / 2))
            Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                output(Modifier.weight(1f).fillMaxHeight().padding(bottom = ControlsEnd))
                // The controls sit at the bottom of their pane, at thumb height.
                FillColumn(Modifier.width(side).fillMaxHeight(), minMiddle = 0.dp, top = header, middle = {}, bottom = controls)
            }
        }
    } else {
        val minOutput = with(LocalDensity.current) { TermLineHeight.toDp() } * OUTPUT_MIN_LINES + OutputPadding * 2
        FillColumn(modifier.fillMaxWidth(), minMiddle = minOutput, top = header, middle = { output(Modifier.fillMaxSize()) }, bottom = controls)
    }
}

/**
 * A column that scrolls, with [top], [middle], and [bottom]. The middle
 * takes the height that the other parts leave free, and at least
 * [minMiddle]. When the parts do not fit, the column is taller than its
 * place, and the user scrolls to the bottom part. [ControlsEnd] stays free
 * under the bottom part.
 */
@Composable
private fun FillColumn(
    modifier: Modifier,
    minMiddle: Dp,
    top: @Composable () -> Unit,
    middle: @Composable () -> Unit,
    bottom: @Composable () -> Unit,
) {
    BoxWithConstraints(modifier) {
        val viewport = if (constraints.hasBoundedHeight) constraints.maxHeight else 0
        Layout(
            contents = listOf(
                { Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(TileGap)) { top() } },
                { Box(propagateMinConstraints = true) { middle() } },
                { Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(TileGap)) { bottom() } },
            ),
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
        ) { (topSlot, middleSlot, bottomSlot), bounds ->
            val width = bounds.maxWidth
            val loose = Constraints(maxWidth = width)
            val gap = TileGap.roundToPx()
            val end = ControlsEnd.roundToPx()
            val head = topSlot.first().measure(loose)
            val foot = bottomSlot.first().measure(loose)
            // An empty part takes no gap.
            val headGap = if (head.height > 0) gap else 0
            val footGap = if (foot.height > 0) gap else 0
            val free = viewport - head.height - headGap - footGap - foot.height - end
            val height = maxOf(minMiddle.roundToPx(), free)
            val body = middleSlot.first().measure(Constraints.fixed(width, height))
            layout(width, head.height + headGap + height + footGap + foot.height + end) {
                head.placeRelative(0, 0)
                body.placeRelative(0, head.height + headGap)
                foot.placeRelative(0, head.height + headGap + height + footGap)
            }
        }
    }
}

// ───────────────────────── Live terminal ─────────────────────────

/** Why Live ends when the unlock ended or is not valid. */
internal const val LIVE_UNLOCK_ENDED = "The unlock ended. Tap Live to open the terminal again."

/** Why Live ends when the user cancels the unlock. */
internal const val LIVE_UNLOCK_CANCELED = "You canceled the unlock."

/** Why Live ends when the stream failed too many times, or the page of the terminal stopped. */
internal const val LIVE_FAILED = "The live terminal stopped. Tap Live to try again."

/** The texts over the live terminal while it does not show. */
private const val LIVE_OPENING = "Opening the terminal…"
private const val LIVE_RECONNECTING = "Reconnecting…"

/** How many times Live opens again after a failure, before it ends. */
internal const val LIVE_RETRIES = 4

/** The first wait before Live opens again. Each next wait is 2 times longer. */
internal const val LIVE_RETRY_MS = 1_000L

/** How long a stream must show before its end starts a new count of failures. */
internal const val LIVE_STABLE_MS = 30_000L

/** How long Live waits for an answer to its open. The open itself fails after 20 seconds. */
private const val LIVE_OPEN_WAIT_MS = 25_000L

/** How long Live waits for the close of a released stream on the same pane. */
private const val LIVE_CLOSE_WAIT_MS = 8_000L

/** How long a new stream can take to draw its first full screen. */
private const val LIVE_DRAW_WAIT_MS = 10_000L

/** How long a new grid of the view waits before the computer resizes the pane. */
private const val LIVE_RESIZE_DELAY_MS = 180L

/** How long the output waits after Live, so that the agent can draw the pane at the desktop size again. */
private const val LIVE_REDRAW_MS = 1_500L

/**
 * True when the wait for the answer to open [request] can end: the
 * answer arrived, or the slot lost the open. [seen] is true after the
 * slot showed this open. Before that, a published slot can still be the
 * slot from before the open, so only a newer request counts as lost.
 */
internal fun openSettled(slot: HerdrTerminalSession?, request: Long, seen: Boolean): Boolean = when {
    slot != null && slot.request > request -> true
    !seen -> false
    else -> slot == null || slot.request != request || !slot.sending
}

/**
 * The reason that ends Live when the computer closed the stream with
 * [code], or null when Live can open a new stream. [computer] is the name
 * of the computer.
 */
internal fun liveEndReason(code: String, computer: String): String? = when (code) {
    "agent_ended" -> "The agent in this pane ended."
    "pane_closed" -> "herdr closed this pane."
    "stopped" -> "$computer stopped the live terminal."
    else -> null
}

/** The reason that ends Live when the computer refused the open with [error]. */
internal fun liveOpenError(error: String): String = "The live terminal did not open: ${error.trimEnd('.')}."

/**
 * Counts the failures of the Live stream and gives the wait before the
 * next open. Each wait is 2 times longer than the last. After
 * [LIVE_RETRIES] failures, Live ends. Only a stream that showed for
 * [LIVE_STABLE_MS] starts a new count. Thus a stream that draws and then
 * fails each time does not open again without end.
 */
internal class LiveRetries {
    private var failures = 0
    private var wait = LIVE_RETRY_MS

    /** Counts a failure. It returns the wait before the next open, or null when Live must end. */
    fun fail(): Long? {
        failures++
        if (failures > LIVE_RETRIES) return null
        return wait.also { wait *= 2 }
    }

    /**
     * Counts an open that the link lost, for example when a new link
     * replaced the old one. The next open goes out at once. It returns
     * false when Live must end.
     */
    fun lost(): Boolean = ++failures <= LIVE_RETRIES

    /** A stream showed for [ms] milliseconds. A stream that showed for [LIVE_STABLE_MS] starts a new count. */
    fun ran(ms: Long) {
        if (ms < LIVE_STABLE_MS) return
        failures = 0
        wait = LIVE_RETRY_MS
    }
}

/**
 * The live terminal of one agent pane: the unlock, the control stream at
 * the grid of the phone, and the page that draws it. [rememberLiveTerminal]
 * keeps it above the layout, and [LiveTerminalView] shows it.
 */
private class LiveTerminal(val feeder: TerminalFeeder, active: Boolean) {
    /** True after the page loaded. */
    var ready by mutableStateOf(false)

    /** The grid that the view measured, in cells. */
    var grid by mutableStateOf(0 to 0)

    /** A new grid that waits for the resize of the pane, or null. */
    var pendingGrid by mutableStateOf<Pair<Int, Int>?>(null)

    /** The last grid that went to the computer, and its session. */
    var sentGrid = 0 to 0
    var sentSession = ""

    /** True after the unlock of this Live. */
    var authorized by mutableStateOf(false)

    /** True while the app is in the front. */
    var active by mutableStateOf(active)

    /** The session whose first full screen shows. */
    var drawn by mutableStateOf("")

    /** The text over the terminal while it does not show. */
    var message by mutableStateOf<String?>(null)

    /** True after the first open. A later open is a reconnect. */
    var opened = false

    /** The unlock prompt that shows, or null. */
    var prompt: CancellationSignal? = null

    /** True after Live ended. Later events do nothing. */
    var ended = false

    /** Turns Live off with a reason. The screen sets it. */
    var onExit: (String) -> Unit = {}

    /** Ends Live once with [reason]. The screen then shows the output and the reason. */
    fun exit(reason: String) {
        if (ended) return
        ended = true
        onExit(reason)
    }

    /** The view measured [next]. While control runs, a new grid resizes the pane. */
    fun grid(next: Pair<Int, Int>) {
        if (authorized && grid != next) pendingGrid = next
        grid = next
    }
}

/**
 * Starts the live terminal of [pane] after a tap on Live. It asks for the
 * phone lock when [ask] is true, and calls [onAsked] after the unlock
 * succeeds. Without a tap, for example after the computer connects again,
 * it opens only while the unlock is valid. A valid unlock of the last 5
 * minutes needs no new prompt. Then it takes control of the pane at the
 * grid of the phone, and opens the stream again after a short failure.
 * Live ends with a reason for [onExit] when the user cancels the unlock,
 * the unlock ends, the computer refuses the stream, the computer closes
 * the stream for the agent or the pane, the page of the terminal stops,
 * or the stream fails too often. The screen ends Live itself when the
 * agent leaves the pane. In the background, the terminal releases
 * control. On the return, it takes control again while the unlock is
 * valid. A [sample] draws with no unlock and no stream.
 */
@Composable
private fun rememberLiveTerminal(
    d: DeviceUi,
    pane: String,
    sample: TerminalSample?,
    ask: Boolean,
    onAsked: () -> Unit,
    onExit: (String) -> Unit,
): LiveTerminal {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val feeder = rememberTerminalFeeder(d.id)
    val t = remember { LiveTerminal(feeder, lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) }
    t.onExit = onExit
    val device by rememberUpdatedState(d)
    val asking by rememberUpdatedState(ask)
    val asked by rememberUpdatedState(onAsked)
    val stream = sample == null
    fun slot(): HerdrTerminalSession? = device.herdrTerminal?.takeIf { it.pane == pane }

    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> {
                    t.active = true
                    // The phone can change hands while the app is in the background.
                    if (stream && t.authorized && !ReplyLock.valid()) t.exit(LIVE_UNLOCK_ENDED)
                }
                Lifecycle.Event.ON_STOP -> {
                    t.active = false
                    t.drawn = ""
                    t.pendingGrid = null
                    if (stream) HerdrSync.terminalRelease(FluxCore, device.id, pane)
                }
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            t.ended = true
            t.prompt?.cancel()
            t.prompt = null
            if (stream) HerdrSync.terminalRelease(FluxCore, device.id, pane)
        }
    }
    // The unlock. A tap on Live asks for it, and a valid unlock opens at once.
    LaunchedEffect(t.active) {
        if (!stream || !t.active || t.authorized || t.prompt != null || t.ended) return@LaunchedEffect
        if (!asking && !ReplyLock.valid()) {
            t.exit(LIVE_UNLOCK_ENDED)
            return@LaunchedEffect
        }
        ReplyLock.run(
            context,
            action = {
                t.prompt = null
                if (!t.ended) {
                    t.authorized = true
                    // Only a finished unlock uses up the tap. A prompt that
                    // a lost link closed shows again after the reconnect.
                    asked()
                }
            },
            title = "Open the terminal",
            purpose = "control terminals",
            onCancel = {
                t.prompt = null
                t.exit(LIVE_UNLOCK_CANCELED)
            },
            onPrompt = { t.prompt = it },
            onError = {
                t.prompt = null
                t.exit(it)
            },
        )
    }
    // The unlock ends after its 5 minutes, also while the terminal shows.
    LaunchedEffect(t.authorized) {
        if (!t.authorized) return@LaunchedEffect
        while (ReplyLock.valid()) delay(ReplyLock.remainingMs().coerceAtLeast(1L))
        t.exit(LIVE_UNLOCK_ENDED)
    }
    // The stream: open it, wait while it runs, and open it again after a failure.
    LaunchedEffect(t.authorized, t.active, t.ready, t.grid.first > 0) {
        if (!stream || !t.authorized || !t.active || !t.ready || t.grid.first < 1) return@LaunchedEffect
        val retries = LiveRetries()
        var request = 0L
        // Counts a failure and waits before the next open. It returns false when Live ended.
        suspend fun retry(reason: String): Boolean {
            val wait = retries.fail()
            if (wait == null) {
                t.exit(reason)
                return false
            }
            t.message = LIVE_RECONNECTING
            delay(wait)
            return true
        }
        // The terminal exists only while the computer is online, so this
        // loop never waits for the computer. While the computer is
        // offline, the screen shows that it is not reachable. In the
        // background, the loop stops and opens nothing.
        while (!t.ended && t.active) {
            val herdr = device.herdr
            if (herdr != null && !herdr.liveTerminal) {
                t.exit("${device.name} does not allow terminal control now.")
                return@LaunchedEffect
            }
            val current = slot()
            val error = current?.error
            when {
                current?.open == true -> {
                    val id = current.session
                    if (t.drawn != id) {
                        val shown = withTimeoutOrNull(LIVE_DRAW_WAIT_MS) {
                            snapshotFlow { t.drawn == id || slot()?.let { it.session == id && it.open } != true }.first { it }
                        }
                        if (shown == null) {
                            HerdrSync.terminalRelease(FluxCore, device.id, pane)
                            if (!retry(LIVE_FAILED)) return@LaunchedEffect
                            continue
                        }
                    }
                    // The time at which the first full screen of the stream showed, or 0.
                    val shownAt = if (t.drawn == id) SystemClock.elapsedRealtime() else 0L
                    if (shownAt > 0L) t.message = null
                    val end = snapshotFlow { slot() }.first { it?.session != id || !it.open }
                    if (shownAt > 0L) retries.ran(SystemClock.elapsedRealtime() - shownAt)
                    t.message = LIVE_RECONNECTING
                    if (end != null && end.session == id && end.closed && end.code != "released") {
                        liveEndReason(end.code, device.name)?.let {
                            t.exit(it)
                            return@LaunchedEffect
                        }
                        if (!retry(LIVE_FAILED)) return@LaunchedEffect
                    }
                }
                terminalClosePending(current) -> {
                    // The computer keeps one controller for each pane, so the
                    // last stream of the pane must close first.
                    t.message = LIVE_RECONNECTING
                    val session = current?.session.orEmpty()
                    val closed = withTimeoutOrNull(LIVE_CLOSE_WAIT_MS) {
                        snapshotFlow { terminalClosePending(slot()) }.first { !it }
                    }
                    if (closed == null) HerdrSync.terminalDrop(FluxCore, device.id, pane, session)
                }
                current?.sending == true -> {
                    // Another open of the pane waits for its answer, which comes or times out.
                    snapshotFlow { slot() }.first { it?.request != current.request || !it.sending }
                }
                current != null && current.request == request && error != null -> {
                    if (!current.retry) {
                        t.exit(liveOpenError(error))
                        return@LaunchedEffect
                    }
                    if (!retry(liveOpenError(error))) return@LaunchedEffect
                    request = 0L
                }
                else -> {
                    t.message = if (t.opened) LIVE_RECONNECTING else LIVE_OPENING
                    t.opened = true
                    request = HerdrSync.terminalOpen(FluxCore, device.id, pane, "control", t.grid.first, t.grid.second)
                    val number = request
                    // The wait also ends when the slot loses this open, for
                    // example after a new link replaced the old one. Right
                    // after the open, the published slot can still be the
                    // old one, so openSettled waits until the slot shows it.
                    val settled = withTimeoutOrNull(LIVE_OPEN_WAIT_MS) {
                        var seen = false
                        snapshotFlow { slot() }.first {
                            if (it?.request == number) seen = true
                            openSettled(it, number, seen)
                        }
                        true
                    }
                    val answer = slot()
                    if (settled == null) {
                        request = 0L
                        if (!retry(LIVE_FAILED)) return@LaunchedEffect
                    } else if (answer == null || answer.request != number) {
                        // The link lost the open, so a new open goes out at once.
                        request = 0L
                        if (!retries.lost()) {
                            t.exit(LIVE_FAILED)
                            return@LaunchedEffect
                        }
                    }
                }
            }
        }
    }
    // A new grid of the view resizes the pane after a short pause, so that
    // a layout change that runs sends only its last grid.
    val session = slot()
    LaunchedEffect(t.pendingGrid, t.authorized, t.active, session?.session, session?.open) {
        val target = t.pendingGrid ?: return@LaunchedEffect
        if (!t.authorized || !t.active || session?.open != true || session.mode != "control") return@LaunchedEffect
        delay(LIVE_RESIZE_DELAY_MS)
        val sent = if (t.sentSession == session.session) t.sentGrid else session.width to session.height
        if (t.pendingGrid == target && target != sent) {
            HerdrSync.terminalResize(FluxCore, device.id, session.session, target.first, target.second)
            t.sentSession = session.session
            t.sentGrid = target
        }
        if (t.pendingGrid == target) t.pendingGrid = null
    }
    return t
}

/**
 * The live terminal in the place of the output. It stays covered until
 * the first full screen of its own stream drew, and the cover tells what
 * the terminal waits for. A drag scrolls the program on the computer, a
 * short tap clicks a cell, and two fingers zoom and pan the view.
 */
@Composable
private fun LiveTerminalView(
    t: LiveTerminal,
    d: DeviceUi,
    pane: String,
    sample: TerminalSample?,
    modifier: Modifier,
    input: TerminalInput,
) {
    val session = d.herdrTerminal?.takeIf { it.pane == pane }
    val current by rememberUpdatedState(session)
    val controlling = t.active && t.authorized && session?.open == true && session.mode == "control"
    val visible = sample != null || terminalControlReady(session, t.drawn, t.authorized, t.active)
    // Input needs a valid unlock. An unlock that ended ends Live.
    fun guardedInput(send: (HerdrTerminalSession) -> Unit) {
        val s = current
        if (!t.active || !t.authorized) return
        if (!ReplyLock.valid()) {
            t.exit(LIVE_UNLOCK_ENDED)
        } else if (s?.open == true && s.mode == "control") {
            send(s)
        }
    }
    // Typed input needs the drawn baseline of the current control session
    // and a valid unlock. A debug sample takes no input.
    val inputReady = controlling && visible && sample == null &&
        t.pendingGrid == null && d.herdr?.terminalInput == true
    // The gate and the send are read again at each event, so a stale
    // footer or a late speech result cannot type into a session that lost
    // control or changed.
    SideEffect {
        input.ready = inputReady
        input.pasteReady = inputReady && d.herdr?.terminalPaste == true
        input.imageReady = inputReady && d.herdr?.terminalImage == true
        input.session = session?.session.orEmpty()
        input.onText = { text ->
            if (terminalControlReady(current, t.drawn, t.authorized, t.active)) {
                guardedInput { s -> HerdrSync.terminalInput(FluxCore, d.id, s.session, text) }
            }
        }
        input.onKey = { key ->
            if (terminalControlReady(current, t.drawn, t.authorized, t.active)) {
                guardedInput { s -> HerdrSync.terminalInputKey(FluxCore, d.id, s.session, key) }
            }
        }
        input.onPaste = { text ->
            if (terminalControlReady(current, t.drawn, t.authorized, t.active)) {
                guardedInput { s -> HerdrSync.terminalPaste(FluxCore, d.id, s.session, text) }
            }
        }
        input.onImage = { uri, _ ->
            if (terminalControlReady(current, t.drawn, t.authorized, t.active)) {
                guardedInput { s -> HerdrSync.terminalPasteImage(FluxCore, d.id, s.session, uri) }
            }
        }
    }
    DisposableEffect(Unit) {
        onDispose {
            input.ready = false
            input.onText = null
            input.onKey = null
            input.onPaste = null
            input.onImage = null
        }
    }
    LaunchedEffect(session?.inputError) {
        session?.inputError?.let { FluxCore.toast(it) }
    }
    Box(modifier) {
        HerdrTerminalView(
            t.feeder,
            session,
            onReady = { t.ready = true },
            modifier = Modifier.fillMaxSize(),
            sample = sample,
            control = controlling && visible && t.pendingGrid == null,
            inputEnabled = visible,
            inputReady = inputReady,
            imageReady = inputReady && d.herdr?.terminalImage == true,
            onText = { input.type(it) },
            onKey = { input.key(it) },
            onPaste = { input.paste(it) },
            onImage = { uri, mime -> input.pasteImage(uri, mime) },
            input = input,
            theme = ComputerThemes.theme(d.id)?.theme,
            onGrid = { cols, rows -> t.grid(cols to rows) },
            onDrawn = { id -> if (current?.session == id) t.drawn = id },
            onWheel = { column, row, direction ->
                guardedInput { s ->
                    HerdrSync.terminalScroll(FluxCore, d.id, s.session, direction, column, row)
                }
            },
            onTap = { column, row ->
                guardedInput { s ->
                    HerdrSync.terminalMouse(FluxCore, d.id, s.session, "down", "left", column, row)
                    HerdrSync.terminalMouse(FluxCore, d.id, s.session, "up", "left", column, row)
                }
            },
            // The page of the terminal stopped, so Live ends and releases control.
            onGone = { t.exit(LIVE_FAILED) },
        )
        if (!visible) {
            Column(
                Modifier.fillMaxSize().background(Tn.tile),
                verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                T(
                    t.message ?: LIVE_OPENING,
                    Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                    size = 13,
                    color = Tn.sub,
                )
            }
        }
    }
}

// ───────────────────────── Output ─────────────────────────

/** How close to the end the output must be, in pixels, to follow new lines. */
private const val FOLLOW_SLACK_PX = 48

/**
 * The output of an agent or a terminal as a small terminal: dark, mono,
 * and in the colors of the pane. The view follows new lines at the end.
 * When the user scrolls up to read older lines, the view stays there, and
 * a key under the lines goes back to the newest lines.
 */
@Composable
internal fun AgentOutput(out: HerdrOutput?, modifier: Modifier) {
    val scroll = rememberScrollState()
    var follow by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()
    // Only the end of a scroll changes follow. A scroll by the user to the end follows again.
    // The first value is not the end of a scroll. With output from before, the view is still at the top then.
    LaunchedEffect(scroll) {
        snapshotFlow { scroll.isScrollInProgress }.drop(1).collect { moving ->
            if (!moving) follow = scroll.value >= scroll.maxValue - FOLLOW_SLACK_PX
        }
    }
    LaunchedEffect(out?.text) {
        if (out?.text.isNullOrEmpty() || !follow) return@LaunchedEffect
        snapshotFlow { scroll.maxValue }.first { it > 0 && it < Int.MAX_VALUE }
        scroll.scrollTo(scroll.maxValue)
    }
    // While the view follows, it stays at the end when the view changes its height,
    // for example when the keyboard opens or the choices show under it.
    LaunchedEffect(scroll) {
        snapshotFlow { scroll.maxValue }.collect { end ->
            if (follow && !scroll.isScrollInProgress && end in 1 until Int.MAX_VALUE) scroll.scrollTo(end)
        }
    }
    Box(modifier.fillMaxWidth()) {
        when {
            // The lines of the output load in the place where they show.
            out == null || (out.loading && out.lines.isEmpty()) -> Box(
                Modifier.fillMaxSize().clip(TileShape).background(TermBg).border(1.dp, Tn.line, TileShape).padding(horizontal = TermPad, vertical = 14.dp),
            ) {
                LineSkeleton("Reading the output", lines = listOf(0.62f, 0.9f, 0.48f, 0.84f, 0.7f, 0.36f, 0.78f, 0.55f))
            }
            // The empty state scrolls when a large font size makes it taller than its place.
            out.error != null && out.lines.isEmpty() -> EmptyState(
                Ic.error, "No output", out.error, Modifier.verticalScroll(rememberScrollState()).padding(top = 32.dp),
            )
            else -> BoxWithConstraints(Modifier.fillMaxSize().clip(TileShape).background(TermBg).border(1.dp, Tn.line, TileShape)) {
                val width = maxWidth
                Column(Modifier.fillMaxSize()) {
                    SelectionContainer(Modifier.weight(1f)) {
                        Column(Modifier.fillMaxSize().verticalScroll(scroll).padding(vertical = OutputPadding)) {
                            val pad = Modifier.padding(horizontal = TermPad)
                            if (out.truncated) T("Older lines are cut.", pad.padding(bottom = 6.dp), size = 11, color = Tn.sub, family = Mono)
                            out.error?.let { T(it, pad.padding(bottom = 6.dp), size = 12, color = Tn.red) }
                            if (out.lines.isEmpty()) {
                                T("No output yet.", pad, size = 12, color = Tn.sub, family = Mono)
                            } else {
                                TermLines(out.lines, width)
                            }
                        }
                    }
                    // The key takes its own row under the lines, so that it covers no output.
                    if (!follow && out.lines.isNotEmpty()) {
                        NewestLinesKey {
                            follow = true
                            scope.launch { scroll.animateScrollTo(scroll.maxValue) }
                        }
                    }
                }
            }
        }
    }
}

/**
 * The key under the output that goes back to the newest lines. It shows
 * while the user reads older lines. A line above it separates it from the
 * output.
 */
@Composable
private fun NewestLinesKey(onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().background(Tn.line).padding(top = 1.dp).background(TermBg)
            .heightIn(min = 48.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = TermPad),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        T("Show the newest lines", size = 13, color = Tn.blue, weight = FontWeight.SemiBold)
        Sym(Ic.up, modifier = Modifier.rotate(180f), tint = Tn.blue, size = 20.dp)
    }
}

/**
 * The close action of an agent or a terminal: a Close key, a confirmation
 * dialog, and the phone lock. The screen goes back when the computer
 * closed the pane. [error] is the last problem.
 */
internal class PaneCloser(
    private val onAsk: () -> Unit,
    private val dialog: @Composable (title: String, body: String) -> Unit,
    val error: String?,
) {
    /**
     * The Close key: an outlined button. It is not red, because red means
     * that something needs the user. The dialog asks before the pane closes.
     */
    @Composable
    fun Button() {
        FluxButton("Close", onAsk, kind = ButtonKind.Outlined)
    }

    @Composable
    fun Dialog(title: String, body: String) = dialog(title, body)
}

@Composable
internal fun rememberPaneCloser(d: DeviceUi, pane: String, onClosed: () -> Unit): PaneCloser {
    val context = LocalContext.current
    var asking by remember { mutableStateOf(false) }
    var lockError by remember { mutableStateOf<String?>(null) }
    // Only a close from this screen counts. Its sequence number is higher than the last action at the tap.
    var after by rememberSaveable(d.id, pane) { mutableLongStateOf(Long.MAX_VALUE) }
    val action = d.herdrAction?.takeIf { it.action == "close" && it.seq > after && it.pane == pane }
    LaunchedEffect(action) {
        if (action != null && !action.sending && action.error == null) {
            HerdrSync.clearAction(FluxCore, d.id, action.seq)
            onClosed()
        }
    }
    val lastSeq = d.herdrAction?.seq ?: 0L
    return PaneCloser(
        onAsk = {
            lockError = null
            asking = true
        },
        dialog = { title, body ->
            if (asking) {
                ConfirmDialog(
                    title, body, "Close",
                    onCancel = { asking = false },
                    onConfirm = {
                        asking = false
                        ReplyLock.run(context, {
                            after = lastSeq
                            HerdrSync.close(FluxCore, d.id, pane)
                        }, title = "Close a pane", purpose = "close agents and terminals") { lockError = it }
                    },
                    destructive = true,
                )
            }
        },
        error = lockError ?: action?.error,
    )
}

// ───────────────────────── Replies ─────────────────────────

/**
 * The reply controls of an agent: the choices of a dialog, a key bar, a
 * text field, and a mic key for dictation. Each reply asks for the phone
 * lock first, see [ReplyLock].
 */
@Composable
private fun ReplyControls(d: DeviceUi, agent: HerdrAgent, out: HerdrOutput?, reply: HerdrReply?, reviewPath: String? = null, reviewReady: Boolean = true) {
    val context = LocalContext.current
    var field by rememberSaveable(d.id, agent.pane, stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue()) }
    var lockError by remember { mutableStateOf<String?>(null) }
    // True while the large editor of the field shows.
    var editing by remember { mutableStateOf(false) }
    // The text of the last Send. When fluxd refuses it because the agent
    // waits for a choice, Send as answer sends the same text again.
    var lastPrompt by rememberSaveable(d.id, agent.pane) { mutableStateOf("") }
    var lastDraft by rememberSaveable(d.id, agent.pane) { mutableStateOf("") }
    var lastReviewPath by rememberSaveable(d.id, agent.pane) { mutableStateOf<String?>(null) }
    // A prompt that the computer accepted leaves the field.
    LaunchedEffect(reply) {
        if (reply != null && reply.action == "prompt" && !reply.sending && reply.error == null) field = TextFieldValue()
    }
    fun guarded(action: () -> Unit) {
        lockError = null
        ReplyLock.run(context, action) { lockError = it }
    }
    fun keys(vararg k: String) = guarded { HerdrSync.sendKeys(FluxCore, d.id, agent.pane, k.toList()) }
    // After an answer, the choices wait for the next output, so that a second tap does not answer the next question.
    var answered by remember(d.id, agent.pane) { mutableStateOf<HerdrOutput?>(null) }
    fun answer(key: String) = guarded {
        answered = out
        HerdrSync.sendKeys(FluxCore, d.id, agent.pane, listOf(key))
    }
    // After a reply that failed, the screen reads the output again. The choices then show the question that waits now.
    LaunchedEffect(reply) {
        if (answered != null && reply != null && !reply.sending && reply.error != null && !isDemo(d.id)) HerdrSync.read(FluxCore, d.id, agent.pane)
    }

    // Dictation: the phone turns speech into text at the cursor of the field.
    // The text waits there for Send, so a prompt still needs the phone lock.
    val dictation = rememberDictation()
    val demo = isDemo(d.id)
    val canDictate = demo || remember { Dictation.available(context) }
    val dictating = dictation.phase != Dictation.Phase.Idle
    var voiceError by remember { mutableStateOf<String?>(null) }
    // True after the user refused the microphone. The error then offers the app settings.
    var micRefused by remember { mutableStateOf(false) }
    var startAfterGrant by remember { mutableStateOf(false) }
    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        micRefused = !ok
        if (ok) startAfterGrant = true else voiceError = MIC_REFUSED
    }
    fun dictate(): Boolean {
        voiceError = null
        lockError = null
        if (MicSession.status.value.active) {
            voiceError = "Stop Flux Microphone to dictate"
            return false
        }
        if (!demo && ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            askMic.launch(Manifest.permission.RECORD_AUDIO)
            return false
        }
        val hints = listOf(agent.agent, agent.project, agent.workspace).filter { it.isNotBlank() }.distinct()
        return dictation.start(hints, demo) { spoken ->
            val e = DictationText.insert(field.text, field.selection.start, field.selection.end, spoken)
            field = TextFieldValue(e.text, TextRange(e.cursor))
        }
    }
    LaunchedEffect(startAfterGrant) {
        if (!startAfterGrant) return@LaunchedEffect
        startAfterGrant = false
        dictate()
    }
    // Android gives the microphone only to a visible app. The dictation
    // ends with its text when the app goes to the background.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, dictation) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) dictation.stopNow() }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    // The language picker. A tap on the language in the panel keeps the
    // words so far, and a selected language starts the next dictation.
    val models = rememberSpeechModels()
    var picking by remember { mutableStateOf(false) }
    var language by remember { mutableStateOf(DictationSettings.language(context)) }
    fun choose(tag: String) {
        DictationSettings.setLanguage(context, tag)
        language = tag
    }
    val view = LocalView.current
    DisposableEffect(dictating) {
        view.keepScreenOn = dictating
        onDispose { view.keepScreenOn = false }
    }

    // The choices take their full height. The screen scrolls when they do not fit, see [PaneLayout].
    // The grid gap keeps 8 dp between the choices, so that a tap does not hit the next choice.
    Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
        val choices = if (agent.status == AgentStatus.Blocked) out?.choices.orEmpty() else emptyList()
        val open = choicesOpen(out, answered, reply?.sending == true)
        for (c in choices) ChoiceTile(c, open) { answer(c.key) }
        KeyBar(
            listOf(
                BarKey("esc", "Escape") { keys("esc") },
                BarKey("tab", "Tab") { keys("tab") },
                BarKey("↑", "Up") { keys("up") },
                BarKey("↓", "Down") { keys("down") },
                BarKey("enter", "Enter", share = 1.4f, accent = agent.status == AgentStatus.Blocked && choices.isEmpty()) { keys("enter") },
            ),
        )
        val sendingPrompt = reply?.sending == true && reply.action == "prompt"
        fun sendPrompt() {
            if (!reviewReady) return
            lastDraft = field.text
            lastReviewPath = reviewPath
            val t = if (reviewPath != null) "Review feedback for ${reviewPath.ifBlank { "the working tree" }}:\n${field.text}" else field.text
            lastPrompt = t
            guarded { HerdrSync.sendPrompt(FluxCore, d.id, agent.pane, t) }
        }
        DictationBar(
            dictation,
            canDictate = canDictate,
            onStart = { dictate() },
            onLanguage = {
                dictation.stopNow()
                picking = true
            },
            field = { m ->
                OutlinedTextField(
                    value = field,
                    onValueChange = { field = it },
                    modifier = m,
                    placeholder = { T("Write to ${agent.agent}", color = Tn.sub) },
                    trailingIcon = { FieldKeys(field.text.isNotEmpty(), { field = TextFieldValue() }, { editing = true }) },
                    textStyle = TextStyle(color = Tn.text, fontSize = 14.sp),
                    shape = TileShape,
                    maxLines = 4,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                )
            },
            send = {
                FieldKey(
                    "Send",
                    onClick = ::sendPrompt,
                    enabled = field.text.isNotBlank() && reviewReady,
                    busy = sendingPrompt,
                ) { Sym(Ic.send, size = 22.dp) }
            },
        )
        if (editing) {
            FieldEditor(
                title = "Write to ${agent.agent}",
                value = field,
                onValueChange = { field = it },
                onDismiss = { editing = false },
                context = d.name,
                keyboard = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            ) {
                FluxButton("Send", {
                    editing = false
                    sendPrompt()
                }, icon = Ic.send, enabled = field.text.isNotBlank() && !sendingPrompt && reviewReady)
            }
        }
        val problem = lockError ?: voiceError ?: dictation.error ?: reply?.error
        // fluxd refused the text of the field as a prompt, because the agent
        // waits for a choice. The agent can take the same text as the answer
        // to its question, for example an answer that is not in the choices.
        val canAnswer = reply != null && problem == reply.error && reply.code == HERDR_BLOCKED && reply.action == "prompt" &&
            !reply.sending && lastPrompt.isNotBlank() && field.text == lastDraft && reviewPath == lastReviewPath
        if (problem != null) {
            Column(Modifier.padding(horizontal = 4.dp)) {
                T(problem, size = 12, color = Tn.red, lineHeight = 1.3f)
                // The buttons line up with the text. The padding of a text button holds the offset.
                FlowRow(Modifier.offset(x = (-12).dp)) {
                    if (canAnswer) {
                        FluxButton("Send as answer", {
                            val t = lastPrompt
                            guarded { HerdrSync.sendPrompt(FluxCore, d.id, agent.pane, t, answer = true) }
                        }, kind = ButtonKind.Text)
                    }
                    if (problem == dictation.error && dictation.languageError) {
                        FluxButton("Choose a language", { picking = true }, kind = ButtonKind.Text)
                    }
                    if (needsMicSettings(problem, micRefused && problem == voiceError)) {
                        FluxButton("Open app settings", { openAppSettings(context) }, kind = ButtonKind.Text, icon = Ic.settings)
                    }
                }
            }
        }
        if (picking) {
            LanguageSheet(
                models,
                selected = language,
                onSelect = { tag ->
                    choose(tag)
                    picking = false
                    dictate()
                },
                onDownloaded = ::choose,
                onDismiss = { picking = false },
            )
        }
    }
}

/**
 * The direct controls of the live terminal: the choices of a blocked agent
 * and one row with Esc, Tab, Up, Down, and the keyboard. Typed text and
 * named keys go straight to the terminal through [input], so the program
 * draws its own prompt and its own menus. The phone keyboard's own mic
 * dictates into the terminal, so this mode has no mic key of its own. The
 * phone-side draft of [ReplyControls] stays for the Changes tab and for
 * the later buffered mode.
 */
@Composable
private fun DirectTerminalControls(agent: HerdrAgent, out: HerdrOutput?, input: TerminalInput) {
    Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
        val choices = if (agent.status == AgentStatus.Blocked) out?.choices.orEmpty() else emptyList()
        for (c in choices) ChoiceTile(c, input.ready) { input.type(c.key) }
        DirectKeys(Modifier.fillMaxWidth(), input)
    }
}

/**
 * The one row of direct keys: Esc, Tab, Up, Down, and the keyboard. The
 * keyboard key only shows the phone keyboard, and Android hides it again.
 * The phone keyboard's own paste, mic, and dictation handle those, so the
 * row has no paste or mic key.
 */
@Composable
private fun DirectKeys(m: Modifier, input: TerminalInput) {
    KeyRow(m) {
        KeyTile("esc", "Escape", Modifier.weight(1f)) { input.key("esc") }
        KeyTile("tab", "Tab", Modifier.weight(1f)) { input.key("tab") }
        KeyTile("↑", "Up", Modifier.weight(1f)) { input.key("up") }
        KeyTile("↓", "Down", Modifier.weight(1f)) { input.key("down") }
        IconKey(Modifier.weight(1f), Ic.keyboard, "Show the keyboard") { input.showKeyboard() }
    }
}

/** A key of [DirectKeys] that shows an icon. [description] is what TalkBack reads. */
@Composable
private fun IconKey(m: Modifier, icon: Int, description: String, onClick: () -> Unit) {
    Box(
        m.fillMaxHeight().clip(RoundedCornerShape(8.dp)).background(Tn.tile)
            .border(1.dp, Tn.line, RoundedCornerShape(8.dp))
            .clickable(onClickLabel = description, role = Role.Button, onClick = onClick)
            .clearAndSetSemantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Sym(icon, tint = Tn.sub, size = 20.dp)
    }
}

/** A numbered choice of a dialog. A tap sends its digit. A choice that is not [enabled] takes no tap. */
@Composable
private fun ChoiceTile(c: AgentChoice, enabled: Boolean, onClick: () -> Unit) {
    // The agent marks 1 choice with its cursor. The tile shows it in the selection color.
    Tile(
        Modifier.fillMaxWidth().heightIn(min = 48.dp), onClick,
        accent = Tn.blue,
        container = choiceFill(c.selected),
        border = choiceBorder(c.selected),
        enabled = enabled,
        padding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            T(c.key, size = 14, color = Tn.blue, weight = FontWeight.Bold, family = Mono)
            T(c.label, Modifier.weight(1f), size = 14)
        }
    }
}

/**
 * A key of a [KeyBar]. [share] is its part of the row width. [accent] marks
 * the key that the dialog needs. TalkBack reads [description].
 */
internal class BarKey(
    val label: String,
    val description: String,
    val share: Float = 1f,
    val accent: Boolean = false,
    val onClick: () -> Unit,
)

/** The widest that a key gets for each share, so that the keys do not stretch across a wide row. */
private val KeyMaxWidth = 80.dp

/** The narrowest key: the touch target of 48 dp. */
private val KeyMinWidth = 48.dp

/**
 * The key bar of the agent and terminal screens. The keys share 1 row, up
 * to [KeyMaxWidth] for each share, and the free width stays at the end.
 * When the row is too narrow for keys of [KeyMinWidth], the keys go to 2
 * rows that fill the width.
 */
@Composable
internal fun KeyBar(keys: List<BarKey>) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val shares = keys.sumOf { it.share.toDouble() }.toFloat()
        val oneRow = KeyMinWidth * shares + TileGap * (keys.size - 1) <= maxWidth
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            if (oneRow) {
                KeyRow {
                    for (k in keys) {
                        val m = Modifier.weight(k.share, fill = false).widthIn(max = KeyMaxWidth * k.share).fillMaxWidth()
                        KeyTile(k.label, k.description, m, k.accent, k.onClick)
                    }
                }
            } else {
                for (row in keys.chunked((keys.size + 1) / 2)) {
                    KeyRow { for (k in row) KeyTile(k.label, k.description, Modifier.weight(k.share), k.accent, k.onClick) }
                }
            }
        }
    }
}

/**
 * A key of the key bar, with a mono label. [accent] marks the key that the
 * dialog needs. TalkBack reads [description].
 */
@Composable
internal fun KeyTile(label: String, description: String, modifier: Modifier, accent: Boolean = false, onClick: () -> Unit) {
    Box(
        modifier.fillMaxHeight().clip(RoundedCornerShape(8.dp)).background(if (accent) Tn.accentTile else Tn.tile)
            .border(1.dp, if (accent) Tn.blue else Tn.line, RoundedCornerShape(8.dp))
            .clickable(onClickLabel = description, role = Role.Button, onClick = onClick)
            .clearAndSetSemantics { contentDescription = description }
            .padding(horizontal = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        KeyLabel(label, if (accent) Tn.blue else Tn.sub)
    }
}

/** The error after the user refused the microphone for dictation. */
internal const val MIC_REFUSED = "Allow the microphone for Flux to dictate"

/**
 * True when a dictation [problem] needs the app settings: the user refused
 * the microphone, or the speech recognizer has no microphone access.
 */
internal fun needsMicSettings(problem: String, refused: Boolean): Boolean = refused || problem.endsWith("in the app settings")
