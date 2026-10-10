package org.omarchy.flux.ui

import androidx.annotation.DrawableRes
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.omarchy.flux.core.AgentAsk
import org.omarchy.flux.core.AgentChoice
import org.omarchy.flux.core.AgentStatus
import org.omarchy.flux.core.DiffFile
import org.omarchy.flux.core.DiffLineKind
import org.omarchy.flux.core.HerdrAgent
import org.omarchy.flux.core.TermLine
import org.omarchy.flux.core.ThreadBlock

/*
 * The parts of the agent thread design: the Inbox master of an agent and
 * the agent screen use them. The sizes come from the design in dp and sp.
 */

// ───────────────────────── Text ─────────────────────────

/** The line boxes of the design: each line takes its full line height, also the first and the last line. */
internal val FullLines = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)

/**
 * Text with the line boxes of the design: [lineHeight] times the font size
 * for each line, with no trim at the top and the bottom of the text.
 */
@Composable
internal fun LineText(
    text: AnnotatedString,
    modifier: Modifier = Modifier,
    size: Float = 14f,
    lineHeight: Float,
    color: Color = Tn.text,
    weight: FontWeight = FontWeight.Normal,
    family: FontFamily = FontFamily.Default,
    maxLines: Int = Int.MAX_VALUE,
) {
    BasicText(
        text, modifier,
        style = TextStyle(
            color = color, fontSize = size.sp, lineHeight = (size * lineHeight).sp, fontWeight = weight, fontFamily = family,
            lineHeightStyle = FullLines,
        ),
        maxLines = maxLines,
        overflow = if (maxLines == Int.MAX_VALUE) TextOverflow.Clip else TextOverflow.Ellipsis,
    )
}

/** [LineText] for plain text. */
@Composable
internal fun LineText(
    text: String,
    modifier: Modifier = Modifier,
    size: Float = 14f,
    lineHeight: Float,
    color: Color = Tn.text,
    weight: FontWeight = FontWeight.Normal,
    family: FontFamily = FontFamily.Default,
    maxLines: Int = Int.MAX_VALUE,
) = LineText(AnnotatedString(text), modifier, size, lineHeight, color, weight, family, maxLines)

/** The line height of the mono font of the design, Roboto Mono, as a part of the font size. */
internal const val MONO_LINE = 1.32f

// ───────────────────────── Marks ─────────────────────────

/**
 * A ring of 3 quarters that turns, for work that runs, such as a working
 * agent or a tool call. With Remove animations on, the ring stands still.
 */
@Composable
internal fun RingSpinner(size: Dp, modifier: Modifier = Modifier, color: Color = Tn.blue, stroke: Dp = 2.dp) {
    val reduce = LocalReduceMotion.current
    val turn = if (reduce) {
        null
    } else {
        rememberInfiniteTransition(label = "ring").animateFloat(0f, 360f, infiniteRepeatable(tween(900, easing = LinearEasing)), label = "ringTurn")
    }
    Spacer(
        modifier.size(size).drawBehind {
            val w = stroke.toPx()
            // The open quarter is at the right, as in the design, and turns with the ring.
            drawArc(
                color, startAngle = 45f + (turn?.value ?: 0f), sweepAngle = 270f, useCenter = false,
                topLeft = Offset(w / 2, w / 2), size = Size(this.size.width - w, this.size.height - w), style = Stroke(w),
            )
        },
    )
}

/** A status dot. With [pulse], it fades to 30% and back in 1.6 s, for what waits for the user. */
@Composable
internal fun PulseDot(color: Color, size: Dp = 8.dp, pulse: Boolean = true) {
    val reduce = LocalReduceMotion.current
    val fade = if (pulse && !reduce) {
        rememberInfiniteTransition(label = "pulse").animateFloat(
            1f, 0.3f, infiniteRepeatable(tween(800, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "pulseAlpha",
        )
    } else {
        null
    }
    Box(Modifier.size(size).graphicsLayer { alpha = fade?.value ?: 1f }.clip(CircleShape).background(color))
}

/** The mark of an agent status: a ring that turns while it works, a dot that pulses while it waits, else a dot. */
@Composable
internal fun StatusMark(status: AgentStatus, dot: Dp = 8.dp, ring: Dp = 11.dp) {
    when (status) {
        AgentStatus.Working -> RingSpinner(ring, color = Tn.blue)
        AgentStatus.Blocked -> PulseDot(Tn.red, dot)
        AgentStatus.Done -> PulseDot(Tn.green, dot, pulse = false)
        AgentStatus.Idle, AgentStatus.Unknown -> PulseDot(Tn.dim, dot, pulse = false)
    }
}

/**
 * A progress bar with no end: 40% of the width slides from the left edge
 * to the right edge in 1.4 s. With Remove animations on, it stands at the
 * middle.
 */
@Composable
internal fun SlideBar(color: Color, modifier: Modifier = Modifier) {
    val reduce = LocalReduceMotion.current
    val move = if (reduce) {
        null
    } else {
        rememberInfiniteTransition(label = "slide").animateFloat(0f, 1f, infiniteRepeatable(tween(1400, easing = FastOutSlowInEasing)), label = "slideX")
    }
    Spacer(
        modifier.fillMaxWidth().clipToBounds().drawBehind {
            val w = size.width * 0.4f
            // From -100% to 260% of the width of the bar, as the design moves it.
            val x = move?.let { -w + it.value * (w * 3.6f) } ?: ((size.width - w) / 2)
            drawRoundRect(color, Offset(x, 0f), Size(w, size.height), CornerRadius(2.dp.toPx()))
        },
    )
}

// ───────────────────────── Actions ─────────────────────────

/**
 * Gives a small action a touch area that is [extra] taller above and
 * below, and keeps its layout height. The parent must not clip the extra
 * area.
 */
internal fun Modifier.overhang(extra: Dp): Modifier = layout { measurable, constraints ->
    val e = extra.roundToPx()
    val grown = if (constraints.hasBoundedHeight) constraints.copy(maxHeight = constraints.maxHeight + 2 * e) else constraints
    val p = measurable.measure(grown.copy(minHeight = (constraints.minHeight + 2 * e).coerceAtMost(grown.maxHeight)))
    layout(p.width, (p.height - 2 * e).coerceAtLeast(0)) { p.place(0, -e) }
}

/**
 * A text action in the accent color, such as Later or Open thread. It is
 * [height] high and takes taps on 48 dp. [leading] and [trailing] are
 * icons before and after the label.
 */
@Composable
internal fun TextAction(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    @DrawableRes leading: Int? = null,
    @DrawableRes trailing: Int? = null,
    size: Int = 14,
    height: Dp = 36.dp,
    iconSize: Dp = 18.dp,
    gap: Dp = 6.dp,
    pad: Dp = 4.dp,
    color: Color = Tn.blue,
    enabled: Boolean = true,
) {
    val extra = ((48.dp - height) / 2).coerceAtLeast(0.dp)
    Row(
        modifier.overhang(extra).alpha(if (enabled) 1f else DimAlpha).clip(RoundedCornerShape(8.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(vertical = extra).heightIn(min = height).padding(horizontal = pad),
        horizontalArrangement = Arrangement.spacedBy(gap),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leading != null) Sym(leading, tint = color, size = iconSize)
        T(label, size = size, color = color, weight = FontWeight.SemiBold, maxLines = 1)
        if (trailing != null) Sym(trailing, tint = color, size = iconSize)
    }
}

/**
 * A numbered choice of a dialog. The [primary] choice has the accent fill,
 * and the others have the tonal fill. A tap sends its keys. The description
 * of a choice shows under its label. [height] is the least height, and
 * [size] is the font size.
 */
@Composable
internal fun AskChoice(c: AgentChoice, primary: Boolean, enabled: Boolean, height: Dp, size: Float, onClick: () -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    val ink = if (primary) Tn.onAccent else Tn.text
    val line = (size * 1.3f).sp
    Row(
        Modifier.fillMaxWidth().heightIn(min = height).alpha(if (enabled) 1f else DimAlpha).clip(shape)
            .background(if (primary) Tn.blue else Tn.line)
            .clickable(enabled = enabled, onClickLabel = "Answer ${c.key}", role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(c.key, style = TextStyle(color = ink.copy(alpha = 0.65f), fontSize = size.sp, lineHeight = line, fontFamily = Mono, fontWeight = FontWeight.Bold, lineHeightStyle = FullLines))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            BasicText(c.label, style = TextStyle(color = ink, fontSize = size.sp, lineHeight = line, fontWeight = FontWeight.Medium, lineHeightStyle = FullLines))
            // The description of a choice of a question, under its label.
            if (c.detail.isNotEmpty()) {
                BasicText(c.detail, style = TextStyle(color = ink.copy(alpha = 0.72f), fontSize = (size - 1.5f).sp, lineHeight = ((size - 1.5f) * 1.3f).sp, lineHeightStyle = FullLines))
            }
        }
    }
}

/** Lines of a command or a question in mono on the page color: the first line in the body ink, the others in the second ink. */
@Composable
internal fun CodeLines(lines: List<String>, modifier: Modifier = Modifier) {
    val text = Tn.text
    val sub = Tn.sub
    val styled = remember(lines, text, sub) {
        buildAnnotatedString {
            lines.forEachIndexed { i, l ->
                if (i > 0) append("\n")
                withStyle(SpanStyle(color = if (i == 0) text else sub)) { append(l) }
            }
        }
    }
    LineText(
        styled, modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(Tn.bg).padding(horizontal = 10.dp, vertical = 8.dp),
        size = 12f, lineHeight = 1.45f, family = Mono,
    )
}

/** The question of a blocked agent: the question line, then the lines above the choices. */
@Composable
internal fun AskText(ask: AgentAsk, questionSize: Int, questionWeight: FontWeight, gap: Dp) {
    Column(verticalArrangement = Arrangement.spacedBy(gap)) {
        if (ask.question.isNotEmpty()) T(ask.question, size = questionSize, weight = questionWeight)
        if (ask.lines.isNotEmpty()) CodeLines(ask.lines)
    }
}

// ───────────────────────── Top of the agent screen ─────────────────────────

/**
 * The top bar of the agent screen: Back, the task of the agent, its
 * agent, pane, and computer in mono, and the [actions] at the end.
 */
@Composable
internal fun AgentTopBar(task: String, context: String, onBack: () -> Unit, actions: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(start = 2.dp, end = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(48.dp).clip(CircleShape).clickable(onClickLabel = "Back", role = Role.Button, onClick = onBack)
                .semantics { contentDescription = "Back" },
            contentAlignment = Alignment.Center,
        ) { Sym(Ic.back, tint = Tn.text, size = 24.dp) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(task, Modifier.semantics { heading() }, size = 16, weight = FontWeight.SemiBold, maxLines = 1)
            LineText(context, size = 11f, lineHeight = MONO_LINE, color = Tn.sub, family = Mono, maxLines = 1)
        }
        actions()
    }
}

/** The Live key of the top bar: a pill that has the accent color while [on]. */
@Composable
internal fun LivePill(on: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(18.dp)
    val ink = if (on) Tn.blue else Tn.text
    val description = if (on) "Stop the live terminal" else "Show the live terminal"
    Row(
        Modifier.overhang(6.dp).clip(shape).clickable(onClickLabel = description, role = Role.Button, onClick = onClick)
            .padding(vertical = 6.dp).height(36.dp).clip(shape)
            .background(if (on) Tn.accentTile else Tn.tile).border(1.dp, if (on) Tn.blue else Tn.line, shape)
            .clearAndSetSemantics { contentDescription = description }
            .padding(start = 10.dp, end = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(Ic.terminal, tint = ink, size = 18.dp)
        T("Live", size = 13, color = ink, weight = FontWeight.SemiBold)
    }
}

/**
 * The agents of the computer as pills that scroll to the side. The pill of
 * the agent on screen has the accent. A tap opens another agent.
 */
@Composable
internal fun AgentStrip(agents: List<HerdrAgent>, pane: String, elapsed: String, onPick: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = 10.dp, end = 10.dp, bottom = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        for (a in agents) {
            val on = a.pane == pane
            val shape = RoundedCornerShape(18.dp)
            Row(
                Modifier.overhang(6.dp).clip(shape)
                    .clickable(onClickLabel = "Open ${a.project.ifEmpty { a.agent }}", role = Role.Tab) { if (!on) onPick(a.pane) }
                    .semantics { stateDescription = if (on) "Shown, ${statusWord(a.status)}" else statusWord(a.status) }
                    .padding(vertical = 6.dp).height(36.dp).clip(shape)
                    .background(if (on) Tn.accentTile else Tn.tile).border(1.dp, if (on) Tn.blue else Tn.line, shape)
                    .padding(start = 11.dp, end = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                StatusMark(a.status)
                T(a.project.ifEmpty { a.title.ifEmpty { a.pane } }, size = 13, weight = FontWeight.Medium, maxLines = 1)
                // The agent on screen shows the time of its step when its output shows one.
                val meta = when {
                    a.status == AgentStatus.Done -> "done"
                    on && elapsed.isNotEmpty() -> elapsed
                    else -> a.agent
                }
                T(meta, size = 11, color = Tn.sub, family = Mono, maxLines = 1)
            }
        }
    }
}

/** The status of an agent as a short word for TalkBack. */
internal fun statusWord(s: AgentStatus): String = when (s) {
    AgentStatus.Blocked -> "needs input"
    AgentStatus.Done -> "done"
    AgentStatus.Working -> "working"
    AgentStatus.Idle -> "idle"
    AgentStatus.Unknown -> "unknown"
}

// ───────────────────────── Thread ─────────────────────────

/** A token that looks like a file path or a file name, or code in backticks. */
private val codeToken = Regex("""`[^`\n]+`|(?<![\w/.-])(?:[\w.-]+/)+[\w.-]*\w|(?<![\w/.-])[\w-]+(?:\.[\w-]+)*\.(?:sql|rb|ts|tsx|js|jsx|mjs|py|go|rs|kt|kts|swift|java|c|h|cpp|md|json|toml|yaml|yml|sh|css|scss|html|txt|lock|xml|qml)\b""")

/** A message of the agent: body text, with paths and code in mono on a tile. */
@Composable
internal fun ThreadMessage(text: String) {
    val tile = Tn.tile
    val styled = remember(text, tile) {
        buildAnnotatedString {
            var at = 0
            for (m in codeToken.findAll(text)) {
                append(text.substring(at, m.range.first))
                withStyle(SpanStyle(fontFamily = Mono, fontSize = 12.sp, background = tile)) {
                    append(" " + m.value.removeSurrounding("`") + " ")
                }
                at = m.range.last + 1
            }
            append(text.substring(at))
        }
    }
    SelectionContainer {
        LineText(styled, Modifier.fillMaxWidth().padding(horizontal = 2.dp), size = 14f, lineHeight = 1.5f)
    }
}

/**
 * A tool call: a mark, the name of the tool, and its arguments in 1 row,
 * and the result under it while [open]. A tap opens and closes the result.
 * A tool that [running] shows a turning ring.
 */
@Composable
internal fun ThreadTool(b: ThreadBlock.Tool, running: Boolean, open: Boolean, onToggle: () -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    val hasResult = b.result.isNotEmpty()
    val args = b.args.ifBlank { b.result.firstOrNull().orEmpty() }
    Column(
        Modifier.fillMaxWidth().clip(shape).background(Tn.offTile).border(1.dp, Tn.line, shape)
            .clickable(enabled = hasResult, onClickLabel = if (open) "Hide the result" else "Show the result", role = Role.Button, onClick = onToggle)
            .padding(horizontal = 12.dp),
    ) {
        Row(Modifier.fillMaxWidth().heightIn(min = 42.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            when {
                running -> RingSpinner(13.dp, color = Tn.blue)
                b.failed -> Sym(Ic.close, "Failed", tint = Tn.red, size = 16.dp)
                else -> Sym(Ic.check, "Done", tint = Tn.green, size = 16.dp)
            }
            T(b.name, size = 12, weight = FontWeight.Bold, family = Mono, maxLines = 1)
            T(args, Modifier.weight(1f), size = 12, color = Tn.sub, family = Mono, maxLines = 1)
            if (hasResult) Sym(if (open) Ic.collapse else Ic.expand, tint = Tn.sub, size = 18.dp)
        }
        if (open && hasResult) {
            SelectionContainer {
                LineText(b.result.joinToString("\n"), Modifier.padding(start = 26.dp, bottom = 12.dp), size = 12f, lineHeight = 1.45f, color = Tn.sub, family = Mono)
            }
        }
    }
}

/** The summary of a run of file edits: the files with their counts. A tap opens the changes when [onReview] is set. */
@Composable
internal fun ThreadChanges(b: ThreadBlock.Changes, onReview: (() -> Unit)?) {
    val shape = RoundedCornerShape(12.dp)
    var m = Modifier.fillMaxWidth().clip(shape).background(Tn.tile).border(1.dp, Tn.line, shape)
    if (onReview != null) m = m.clickable(onClickLabel = "Review the changes", role = Role.Button, onClick = onReview)
    Column(m.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // The row is as high as the line box of the icon in the design.
        Row(Modifier.fillMaxWidth().heightIn(min = 22.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(Ic.diff, tint = Tn.magenta, size = 18.dp)
            T(if (b.files.size == 1) "Changed 1 file" else "Changed ${b.files.size} files", Modifier.weight(1f), size = 13, weight = FontWeight.SemiBold)
            T("+${b.added}", size = 12, color = Tn.green, family = Mono)
            T("−${b.removed}", size = 12, color = Tn.red, family = Mono)
        }
        for (f in b.files) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                LineText(f.path, Modifier.weight(1f), size = 11f, lineHeight = MONO_LINE, color = Tn.sub, family = Mono, maxLines = 1)
                LineText("+${f.added}", size = 11f, lineHeight = MONO_LINE, color = Tn.green, family = Mono)
                if (f.removed > 0) LineText("−${f.removed}", size = 11f, lineHeight = MONO_LINE, color = Tn.red, family = Mono)
            }
        }
        if (onReview != null) T("Review changes", size = 13, color = Tn.blue, weight = FontWeight.SemiBold)
    }
}

/** A prompt or an answer of the user: a bubble at the right, and [meta] under it when it is set. */
@Composable
internal fun ThreadYou(text: String, meta: String?) {
    BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
        Column(Modifier.widthIn(max = maxWidth * 0.8f), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            val shape = RoundedCornerShape(16.dp, 16.dp, 4.dp, 16.dp)
            SelectionContainer {
                LineText(
                    text, Modifier.clip(shape).background(Tn.accentTile).border(1.dp, Tn.lineHi, shape).padding(horizontal = 14.dp, vertical = 8.dp),
                    size = 14f, lineHeight = 1.4f,
                )
            }
            if (meta != null) LineText(meta, size = 10.5f, lineHeight = MONO_LINE, color = Tn.sub, family = Mono)
        }
    }
}

/** The line at the end of the thread of an agent that waits for the user. */
@Composable
internal fun ThreadWaiting() {
    Row(
        Modifier.fillMaxWidth().padding(top = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PulseDot(Tn.red)
        T("Waiting for you", size = 12, color = Tn.red)
        Box(Modifier.height(20.dp), contentAlignment = Alignment.Center) { Sym(Ic.south, tint = Tn.red, size = 16.dp) }
    }
}

/** The line at the end of the thread of an agent that finished, with the time of its turn when the output shows it. */
@Composable
internal fun ThreadDone(worked: String) {
    Row(
        Modifier.fillMaxWidth().padding(top = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.height(20.dp), contentAlignment = Alignment.Center) { Sym(Ic.checkCircle, tint = Tn.green, size = 16.dp) }
        T(doneText(worked), size = 12, color = Tn.green)
    }
}

/** "Done", with the time of the last turn when it is known. */
internal fun doneText(worked: String): String = if (worked.isEmpty()) "Done" else "Done in $worked"

/** Output lines that the thread does not know, as a small terminal. */
@Composable
internal fun ThreadRaw(lines: List<TermLine>) {
    val shape = RoundedCornerShape(12.dp)
    BoxWithConstraints(Modifier.fillMaxWidth().clip(shape).background(Tn.offTile).border(1.dp, Tn.line, shape).padding(vertical = 10.dp)) {
        val width = maxWidth
        SelectionContainer { Column { TermLines(lines, width) } }
    }
}

// ───────────────────────── Changes sheet ─────────────────────────

/**
 * The changes of the repository of an agent in a sheet: each file with its
 * counts and its diff lines in color. [files] is null while the diff loads.
 * [problem] tells why no diff shows.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ChangesSheet(files: List<DiffFile>?, problem: String?, truncated: Boolean, onDismiss: () -> Unit) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheet,
        shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
        containerColor = Tn.tile,
        contentColor = Tn.text,
        scrimColor = Color(0x99080808),
        dragHandle = {
            Box(Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 4.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.size(32.dp, 4.dp).clip(RoundedCornerShape(2.dp)).background(Tn.lineHi))
            }
        },
    ) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.82f)) {
            Row(
                Modifier.fillMaxWidth().padding(start = 18.dp, end = 8.dp, top = 4.dp, bottom = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                T("Changes", Modifier.weight(1f).semantics { heading() }, size = 17, weight = FontWeight.SemiBold)
                if (!files.isNullOrEmpty()) {
                    T("+${files.sumOf { it.added }}", size = 12, color = Tn.green, family = Mono)
                    T("−${files.sumOf { it.removed }}", size = 12, color = Tn.red, family = Mono)
                }
                Box(
                    Modifier.size(44.dp).clip(CircleShape).clickable(onClickLabel = "Close", role = Role.Button, onClick = onDismiss)
                        .semantics { contentDescription = "Close" },
                    contentAlignment = Alignment.Center,
                ) { Sym(Ic.close, tint = Tn.sub, size = 22.dp) }
            }
            Column(
                Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 12.dp, end = 12.dp, bottom = 16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                when {
                    files == null -> LineSkeleton("Reading the changes", Modifier.padding(6.dp), lines = listOf(0.7f, 0.9f, 0.5f, 0.8f))
                    files.isEmpty() -> T(problem ?: "No changes in this repository.", Modifier.padding(horizontal = 6.dp), size = 14, color = Tn.sub)
                    else -> {
                        if (truncated) T("The diff is longer than the preview limit. Older files are cut.", Modifier.padding(horizontal = 6.dp), size = 12, color = Tn.sub)
                        for (f in files) DiffCard(f)
                    }
                }
            }
        }
    }
}

/** A file of the changes: its path and counts, then its diff lines. */
@Composable
private fun DiffCard(f: DiffFile) {
    val shape = RoundedCornerShape(12.dp)
    val style = TextStyle(fontFamily = Mono, fontSize = 11.sp, lineHeight = 17.sp, lineHeightStyle = FullLines)
    Column(Modifier.fillMaxWidth().clip(shape).background(Tn.bg).border(1.dp, Tn.line, shape)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 9.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            BasicText(f.path, Modifier.weight(1f), style = style.copy(color = Tn.text, fontWeight = FontWeight.Medium))
            BasicText("+${f.added}", style = style.copy(color = Tn.green, fontWeight = FontWeight.Medium))
            if (f.removed > 0) BasicText("−${f.removed}", style = style.copy(color = Tn.red, fontWeight = FontWeight.Medium))
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(Tn.line))
        val colors = Tn
        val text = remember(f, colors) {
            buildAnnotatedString {
                f.lines.forEachIndexed { i, l ->
                    if (i > 0) append("\n")
                    val c = when (l.kind) {
                        DiffLineKind.Hunk -> colors.cyan
                        DiffLineKind.Added -> colors.green
                        DiffLineKind.Removed -> colors.red
                        DiffLineKind.Context -> colors.sub
                    }
                    withStyle(SpanStyle(color = c)) { append(l.text) }
                }
            }
        }
        SelectionContainer {
            BasicText(text, Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), style = style.copy(color = Tn.sub))
        }
    }
}

// ───────────────────────── Keys ─────────────────────────

/** A key of the key rows of the agent screen: mono on a small tile. [accent] marks the digits of the choices. */
@Composable
internal fun SmallKey(
    label: String,
    description: String,
    modifier: Modifier,
    accent: Boolean = false,
    enabled: Boolean = true,
    fill: Color = Tn.tile,
    weight: FontWeight = FontWeight.SemiBold,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(8.dp)
    Box(
        modifier.fillMaxHeight().alpha(if (enabled) 1f else DimAlpha).clip(shape)
            .background(if (accent) Tn.accentTile else fill)
            .border(1.dp, if (accent) Tn.blue else Tn.line, shape)
            .clickable(enabled = enabled, onClickLabel = description, role = Role.Button, onClick = onClick)
            .clearAndSetSemantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        T(label, size = 12, color = if (accent) Tn.blue else Tn.sub, weight = weight, family = Mono, maxLines = 1, fit = true)
    }
}

/** The space of the design between the keys of a key row. */
internal val SmallKeyGap = 6.dp

/** The padding of the dock of the agent screen. */
internal val DockPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 14.dp, bottom = 8.dp)
