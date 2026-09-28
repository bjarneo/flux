package org.omarchy.flux.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import org.omarchy.flux.core.AgentChoice
import org.omarchy.flux.core.AgentStatus
import org.omarchy.flux.core.DebugDemo
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.HerdrAgent
import org.omarchy.flux.core.HerdrOutput
import org.omarchy.flux.core.HerdrReply
import org.omarchy.flux.core.HerdrTerminal
import org.omarchy.flux.core.HerdrSync
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

@Composable
@ReadOnlyComposable
private fun statusColor(s: AgentStatus): Color = when (s) {
    AgentStatus.Blocked -> Tn.red
    AgentStatus.Done -> Tn.green
    AgentStatus.Working -> Tn.blue
    AgentStatus.Idle, AgentStatus.Unknown -> Tn.dim
}

private fun statusLabel(s: AgentStatus): String = when (s) {
    AgentStatus.Blocked -> "Needs input"
    AgentStatus.Done -> "Done"
    AgentStatus.Working -> "Working"
    AgentStatus.Idle -> "Idle"
    AgentStatus.Unknown -> "Unknown"
}

/** The status dot and the mono status label of an agent. */
@Composable
private fun StatusLine(s: AgentStatus) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        Dot(statusColor(s), 7.dp)
        TileLabel(statusLabel(s), color = statusColor(s))
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
        TiledTopBar("agents · ${d.name}", onBack) {
            if (d.online && herdr?.running == true && herdr.control) SquareButton(Ic.add, "New agent or terminal", onNew)
            if (d.online) SquareButton(Ic.refresh, "Refresh", { HerdrSync.request(FluxCore, d.id) })
        }
        when {
            !d.online -> NotReachable(d, "The agents")
            herdr == null -> Row(Modifier.padding(4.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Tn.magenta)
                T("Loading the agents of ${d.name}", color = Tn.sub)
            }
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
                    "Select + to start an agent on ${d.name}, or start one in a herdr pane there."
                } else {
                    "Start a coding agent in a herdr pane on ${d.name}. It shows here."
                },
                Modifier.padding(top = 48.dp),
            )
            else -> Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
                for (a in herdr.sorted) AgentTile(a) { onOpen(a.pane) }
                if (herdr.panes.isNotEmpty()) {
                    TileLabel("Terminals", Modifier.padding(start = 4.dp, top = 12.dp))
                    for (t in herdr.panes) TerminalTile(t) { onOpenTerminal(t.pane) }
                }
            }
        }
        Spacer(Modifier.height(96.dp))
    }
}

@Composable
private fun AgentTile(a: HerdrAgent, onClick: () -> Unit) {
    val blocked = a.status == AgentStatus.Blocked
    Tile(
        Modifier.fillMaxWidth().height(96.dp), onClick,
        accent = statusColor(a.status),
        container = if (blocked) Tn.tileHi else Tn.tile,
        border = BorderStroke(1.dp, if (blocked) Tn.red else Tn.line),
        padding = PaddingValues(14.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            StatusLine(a.status)
            Spacer(Modifier.weight(1f))
            T(a.agent, size = 10, color = Tn.dim, family = Mono, maxLines = 1)
        }
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Bottom) {
                T(a.project.ifEmpty { a.pane }, Modifier.weight(1f, fill = false), size = 15, weight = FontWeight.SemiBold, maxLines = 1)
                if (a.workspace.isNotEmpty() && a.workspace != a.project) T(a.workspace, size = 10, color = Tn.dim, family = Mono, maxLines = 1)
            }
            T(a.title.ifEmpty { a.pane }, size = 11, color = Tn.sub, maxLines = 1)
        }
    }
}

/** A herdr terminal: its folder, its workspace, and the terminal title. */
@Composable
private fun TerminalTile(t: HerdrTerminal, onClick: () -> Unit) {
    Tile(Modifier.fillMaxWidth().height(72.dp), onClick, accent = Tn.green, padding = PaddingValues(horizontal = 14.dp, vertical = 12.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(Ic.terminal, tint = Tn.green, size = 18.dp)
            T(t.project.ifEmpty { t.pane }, Modifier.weight(1f), size = 14, weight = FontWeight.SemiBold, maxLines = 1)
            if (t.workspace.isNotEmpty() && t.workspace != t.project) T(t.workspace, size = 10, color = Tn.dim, family = Mono, maxLines = 1)
            T(t.pane, size = 10, color = Tn.dim, family = Mono, maxLines = 1)
        }
        T(t.title.ifEmpty { "shell" }, size = 11, color = Tn.sub, family = Mono, maxLines = 1)
    }
}

// ───────────────────────── One agent ─────────────────────────

/**
 * The recent output of one herdr agent in terminal colors, with the newest
 * lines at the bottom. The screen reads the output again when the status
 * changes, and every few seconds while the agent works. When the computer
 * allows it, the screen also sends keys and text to the agent.
 */
@Composable
fun TiledAgentScreen(d: DeviceUi, pane: String, onBack: () -> Unit) {
    val agent = d.herdr?.agent(pane)
    val status = agent?.status
    val demo = DebugDemo.isDemo(d.id)
    LaunchedEffect(d.id, pane, d.online, status) {
        if (!d.online || demo) return@LaunchedEffect
        HerdrSync.read(FluxCore, d.id, pane)
        while (status == AgentStatus.Working) {
            delay(WORKING_REFRESH_MS)
            HerdrSync.read(FluxCore, d.id, pane)
        }
    }
    DisposableEffect(d.id, pane) { onDispose { HerdrSync.closeOutput(FluxCore, d.id, pane) } }

    val out = d.herdrOutput?.takeIf { it.pane == pane }
    val closer = rememberPaneCloser(d, pane, onBack)
    val label = if (agent != null) "${agent.agent} · ${agent.project.ifEmpty { pane }}" else pane
    Column(Modifier.fillMaxSize().imePadding().padding(horizontal = TiledGutter)) {
        TiledTopBar(label, onBack) {
            if (out?.loading == true && out.lines.isNotEmpty()) {
                Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Tn.magenta)
                }
            } else if (d.online && agent != null && !demo) {
                SquareButton(Ic.refresh, "Refresh", { HerdrSync.read(FluxCore, d.id, pane) })
            }
        }
        when {
            !d.online -> NotReachable(d, "The agent output")
            agent == null && d.herdr != null -> EmptyState(
                Ic.agent,
                "The agent is gone",
                "The agent in $pane on ${d.name} stopped or moved to another pane.",
                Modifier.padding(top = 48.dp),
            )
            else -> {
                if (agent != null) AgentHeader(agent, closer.takeIf { d.herdr?.control == true })
                Spacer(Modifier.height(TileGap))
                AgentOutput(out, Modifier.weight(1f))
                if (agent != null) {
                    Spacer(Modifier.height(TileGap))
                    if (d.herdr?.control == true) {
                        ReplyControls(d, agent, out, d.herdrReply?.takeIf { it.pane == pane })
                    } else {
                        T(
                            "To answer from this phone, set herdr_control = true on ${d.name}.",
                            Modifier.padding(horizontal = 4.dp), size = 11, color = Tn.dim,
                        )
                    }
                }
                Spacer(Modifier.height(12.dp))
            }
        }
    }
    closer.Dialog("Close ${agent?.agent ?: "the agent"}?", "herdr closes $pane on ${d.name}, and the agent in it stops.")
}

@Composable
private fun AgentHeader(a: HerdrAgent, closer: PaneCloser?) {
    Tile(Modifier.fillMaxWidth(), padding = PaddingValues(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            StatusLine(a.status)
            Spacer(Modifier.weight(1f))
            T(a.pane, size = 10, color = Tn.dim, family = Mono, maxLines = 1)
            closer?.Button()
        }
        if (a.title.isNotEmpty()) T(a.title, size = 13, weight = FontWeight.SemiBold, maxLines = 1)
        closer?.error?.let { T(it, size = 11, color = Tn.red) }
    }
}

/** How close to the end the output must be, in pixels, to follow new lines. */
private const val FOLLOW_SLACK_PX = 48

/**
 * The output of an agent or a terminal as a small terminal: dark, mono,
 * and in the colors of the pane. The view follows new lines at the end.
 * When the user scrolls up to read older lines, the view stays there, and
 * a button goes back to the newest lines.
 */
@Composable
internal fun AgentOutput(out: HerdrOutput?, modifier: Modifier) {
    val scroll = rememberScrollState()
    var follow by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()
    // Only the end of a scroll changes follow. A scroll by the user to the end follows again.
    LaunchedEffect(scroll) {
        snapshotFlow { scroll.isScrollInProgress }.collect { moving ->
            if (!moving) follow = scroll.value >= scroll.maxValue - FOLLOW_SLACK_PX
        }
    }
    LaunchedEffect(out?.text) {
        if (out?.text.isNullOrEmpty() || !follow) return@LaunchedEffect
        snapshotFlow { scroll.maxValue }.first { it > 0 && it < Int.MAX_VALUE }
        scroll.scrollTo(scroll.maxValue)
    }
    Box(modifier.fillMaxWidth()) {
        when {
            out == null || (out.loading && out.lines.isEmpty()) -> Row(
                Modifier.padding(4.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Tn.magenta)
                T("Reading the output", color = Tn.sub)
            }
            out.error != null && out.lines.isEmpty() -> EmptyState(Ic.error, "No output", out.error, Modifier.padding(top = 32.dp))
            else -> {
                val colors = Tn
                val text = remember(out.lines, colors) { termAnnotated(out.lines, colors) }
                Box(Modifier.fillMaxSize().clip(TileShape).background(TermBg).border(1.dp, Tn.line, TileShape)) {
                    SelectionContainer {
                        Column(Modifier.fillMaxSize().verticalScroll(scroll).padding(horizontal = 12.dp, vertical = 10.dp)) {
                            if (out.truncated) T("Older lines are cut.", Modifier.padding(bottom = 6.dp), size = 10, color = Tn.dim, family = Mono)
                            out.error?.let { T(it, Modifier.padding(bottom = 6.dp), size = 11, color = Tn.red) }
                            if (out.lines.isEmpty()) {
                                T("No output yet.", size = 11, color = Tn.dim, family = Mono)
                            } else {
                                BasicText(text, style = TextStyle(color = Tn.text, fontFamily = Mono, fontSize = 11.5.sp, lineHeight = 16.sp))
                            }
                        }
                    }
                    if (!follow && out.lines.isNotEmpty()) {
                        Box(
                            Modifier.align(Alignment.BottomEnd).padding(10.dp).size(40.dp).clip(RoundedCornerShape(8.dp))
                                .background(Tn.tileHi).border(1.dp, Tn.blue, RoundedCornerShape(8.dp))
                                .clickable(onClickLabel = "Show the newest lines") {
                                    follow = true
                                    scope.launch { scroll.animateScrollTo(scroll.maxValue) }
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            Sym(Ic.up, "Show the newest lines", Modifier.rotate(180f), tint = Tn.blue, size = 20.dp)
                        }
                    }
                }
            }
        }
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
    @Composable
    fun Button() {
        T(
            "Close",
            Modifier.clip(RoundedCornerShape(6.dp)).clickable(onClickLabel = "Close the pane", onClick = onAsk)
                .padding(horizontal = 8.dp, vertical = 4.dp),
            size = 12, color = Tn.red, weight = FontWeight.SemiBold,
        )
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

/** The highest part of the screen that the choices of a dialog can take. More choices scroll. */
private val ChoicesMaxHeight = 196.dp

/**
 * The reply controls of an agent: the choices of a dialog, a key bar, a
 * text field, and a mic key for dictation. Each reply asks for the phone
 * lock first, see [ReplyLock].
 */
@Composable
private fun ReplyControls(d: DeviceUi, agent: HerdrAgent, out: HerdrOutput?, reply: HerdrReply?) {
    val context = LocalContext.current
    var field by rememberSaveable(d.id, agent.pane, stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue()) }
    var lockError by remember { mutableStateOf<String?>(null) }
    // A prompt that the computer accepted leaves the field.
    LaunchedEffect(reply) {
        if (reply != null && reply.action == "prompt" && !reply.sending && reply.error == null) field = TextFieldValue()
    }
    fun guarded(action: () -> Unit) {
        lockError = null
        ReplyLock.run(context, action) { lockError = it }
    }
    fun keys(vararg k: String) = guarded { HerdrSync.sendKeys(FluxCore, d.id, agent.pane, k.toList()) }

    // Dictation: the phone turns speech into text at the cursor of the field.
    // The text waits there for Send, so a prompt still needs the phone lock.
    val dictation = rememberDictation()
    val demo = DebugDemo.isDemo(d.id)
    val canDictate = demo || remember { Dictation.available(context) }
    val dictating = dictation.phase != Dictation.Phase.Idle
    var voiceError by remember { mutableStateOf<String?>(null) }
    var startAfterGrant by remember { mutableStateOf(false) }
    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) startAfterGrant = true else voiceError = "Allow the microphone for Flux to dictate"
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

    Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
        val choices = if (agent.status == AgentStatus.Blocked) out?.choices.orEmpty() else emptyList()
        if (choices.isNotEmpty()) {
            Column(
                Modifier.heightIn(max = ChoicesMaxHeight).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                for (c in choices) ChoiceTile(c) { keys(c.key) }
            }
        }
        Row(Modifier.fillMaxWidth().height(40.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            KeyTile("esc", "Escape", Modifier.weight(1f)) { keys("esc") }
            KeyTile("tab", "Tab", Modifier.weight(1f)) { keys("tab") }
            KeyTile("↑", "Up", Modifier.weight(1f)) { keys("up") }
            KeyTile("↓", "Down", Modifier.weight(1f)) { keys("down") }
            KeyTile("enter", "Enter", Modifier.weight(1.4f), accent = agent.status == AgentStatus.Blocked && choices.isEmpty()) { keys("enter") }
        }
        val sendingPrompt = reply?.sending == true && reply.action == "prompt"
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
                    placeholder = { T("Write to ${agent.agent}", color = Tn.dim) },
                    textStyle = TextStyle(color = Tn.text, fontSize = 14.sp),
                    shape = TileShape,
                    maxLines = 4,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                )
            },
            send = {
                val canSend = field.text.isNotBlank() && !sendingPrompt
                Box(
                    Modifier.size(56.dp).clip(TileShape).background(if (canSend) Tn.blue else Tn.tile)
                        .clickable(enabled = canSend, onClickLabel = "Send") {
                            val t = field.text
                            guarded { HerdrSync.sendPrompt(FluxCore, d.id, agent.pane, t) }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    if (sendingPrompt) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Tn.magenta)
                    } else {
                        Sym(Ic.send, "Send", tint = if (canSend) Tn.onAccent else Tn.dim, size = 22.dp)
                    }
                }
            },
        )
        val problem = lockError ?: voiceError ?: dictation.error ?: reply?.error
        if (problem != null) {
            Row(Modifier.padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                T(problem, Modifier.weight(1f), size = 11, color = Tn.red)
                if (problem == dictation.error && dictation.languageError) {
                    T(
                        "Choose a language",
                        Modifier.clip(RoundedCornerShape(6.dp)).clickable(onClickLabel = "Choose the dictation language") { picking = true }
                            .padding(horizontal = 6.dp, vertical = 4.dp),
                        size = 12, color = Tn.blue, weight = FontWeight.SemiBold,
                    )
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

/** A numbered choice of a dialog. A tap sends its digit. */
@Composable
private fun ChoiceTile(c: AgentChoice, onClick: () -> Unit) {
    Tile(
        Modifier.fillMaxWidth(), onClick,
        accent = Tn.blue,
        container = if (c.selected) Tn.tileHi else Tn.tile,
        border = BorderStroke(1.dp, if (c.selected) Tn.blue else Tn.line),
        padding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            T(c.key, size = 13, color = Tn.blue, weight = FontWeight.Bold, family = Mono)
            T(c.label, Modifier.weight(1f), size = 13, maxLines = 2)
        }
    }
}

/** A key of the key bar, with a mono label. [accent] marks the key that the dialog needs. */
@Composable
internal fun KeyTile(label: String, description: String, modifier: Modifier, accent: Boolean = false, onClick: () -> Unit) {
    Box(
        modifier.fillMaxHeight().clip(RoundedCornerShape(8.dp)).background(if (accent) Tn.tileHi else Tn.tile)
            .border(1.dp, if (accent) Tn.blue else Tn.line, RoundedCornerShape(8.dp))
            .clickable(onClickLabel = description, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        T(label, size = 12, color = if (accent) Tn.blue else Tn.sub, weight = FontWeight.SemiBold, family = Mono, maxLines = 1)
    }
}
