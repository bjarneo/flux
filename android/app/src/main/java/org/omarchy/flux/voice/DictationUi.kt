package org.omarchy.flux.voice

import android.os.SystemClock
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.Mono
import org.omarchy.flux.ui.Sym
import org.omarchy.flux.ui.T
import org.omarchy.flux.ui.TileGap
import org.omarchy.flux.ui.TileLabel
import org.omarchy.flux.ui.TileShape
import org.omarchy.flux.ui.Tn
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin
import kotlin.random.Random

/** A press on the mic key that lasts this long is push to talk. The release then stops the dictation. */
private const val HOLD_MS = 350L

/** The size of the mic key and the send key. */
private val KeySize = 56.dp

/** The inner margin of the listening panel. The stop key sits this far from its corner. */
private val PanelPad = 14.dp

/** The inner margin of the listening panel at its right edge, for the cancel button. */
private val PanelEnd = 8.dp

/** The left part of the wave where the old bars fade out. */
private const val FADE_PART = 0.35f

/**
 * The reply bar with dictation. At rest it shows [field], the mic key, and
 * [send] when it is set. While the phone listens, 1 panel takes the full
 * width: the time, the live wave, the words, and the stop key in its
 * corner. The mic key is the same element in both layouts and slides into
 * the panel, so a long press keeps working while the panel opens.
 * [onStart] asks for the microphone and starts the dictation. It returns
 * false when the dictation did not start.
 */
@Composable
fun DictationBar(
    d: Dictation,
    canDictate: Boolean,
    onStart: () -> Boolean,
    field: @Composable (Modifier) -> Unit,
    modifier: Modifier = Modifier,
    send: (@Composable () -> Unit)? = null,
    onLanguage: (() -> Unit)? = null,
) {
    val active = d.phase != Dictation.Phase.Idle
    Box(modifier.fillMaxWidth()) {
        AnimatedContent(
            active,
            transitionSpec = {
                (fadeIn(tween(220, delayMillis = 60)) + scaleIn(tween(260), initialScale = 0.96f, transformOrigin = TransformOrigin(1f, 1f))) togetherWith
                    fadeOut(tween(120)) using SizeTransform(clip = false)
            },
            contentAlignment = Alignment.BottomStart,
            label = "dictationBar",
        ) { listening ->
            if (listening) {
                ListeningPanel(d, onCancel = { d.cancel() }, onLanguage = onLanguage, modifier = Modifier.fillMaxWidth())
            } else {
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                    field(Modifier.weight(1f))
                    // The mic key lies over this place.
                    if (canDictate) Spacer(Modifier.size(KeySize))
                    send?.invoke()
                }
            }
        }
        if (canDictate) {
            val spring = spring<Dp>(dampingRatio = 0.72f, stiffness = Spring.StiffnessMediumLow)
            val rest = if (send == null) 0.dp else -(KeySize + TileGap)
            val x = animateDpAsState(if (active) -PanelPad else rest, spring, label = "micX")
            val y = animateDpAsState(if (active) -PanelPad else 0.dp, spring, label = "micY")
            MicKey(
                d, onStart,
                Modifier.align(Alignment.BottomEnd).offset { IntOffset(x.value.roundToPx(), y.value.roundToPx()) },
            )
        }
    }
}

/**
 * The key that starts and stops a dictation. A tap starts it, and the next
 * tap stops it. A long press is push to talk: the dictation stops when the
 * finger leaves the key. While the phone listens, the key is red and sends
 * rings out with the voice.
 */
@Composable
private fun MicKey(d: Dictation, onStart: () -> Boolean, modifier: Modifier = Modifier) {
    val haptic = LocalHapticFeedback.current
    val start by rememberUpdatedState(onStart)
    val listening = d.phase == Dictation.Phase.Listening
    val finishing = d.phase == Dictation.Phase.Finishing
    val red = Tn.red
    val fill by animateColorAsState(if (listening) Tn.red else if (finishing) Tn.tile else Tn.tile, tween(200), label = "micFill")
    val edge by animateColorAsState(if (listening) Tn.red else Tn.line, tween(200), label = "micEdge")
    val voice by animateFloatAsState(if (listening) d.level else 0f, tween(110), label = "micLevel")
    val rings = rememberInfiniteTransition(label = "micRings")
    val ring = rings.animateFloat(0f, 1f, infiniteRepeatable(tween(1500, easing = LinearEasing)), label = "micRing")

    fun stop() {
        haptic.performHapticFeedback(HapticFeedbackType.ToggleOff)
        d.stop()
    }

    Box(
        modifier.size(KeySize)
            // The rings draw before the clip, so they spread past the key.
            .drawBehind {
                if (!listening) return@drawBehind
                val reach = 4.dp.toPx() + voice * 8.dp.toPx()
                for (k in 0..1) {
                    val p = (ring.value + k * 0.5f) % 1f
                    val grow = p * reach
                    drawRoundRect(
                        color = red.copy(alpha = (1f - p) * (0.3f + 0.6f * voice)),
                        topLeft = Offset(-grow, -grow),
                        size = Size(size.width + grow * 2, size.height + grow * 2),
                        cornerRadius = CornerRadius(12.dp.toPx() + grow),
                        style = Stroke(2.dp.toPx()),
                    )
                }
            }
            .graphicsLayer {
                val s = 1f + voice * 0.05f
                scaleX = s
                scaleY = s
            }
            .clip(TileShape)
            .background(fill)
            .border(1.dp, edge, TileShape)
            .semantics {
                role = Role.Button
                contentDescription = if (listening) "Stop dictation" else "Dictate"
                onClick {
                    when (d.phase) {
                        Dictation.Phase.Idle -> if (start()) haptic.performHapticFeedback(HapticFeedbackType.ToggleOn)
                        Dictation.Phase.Listening -> stop()
                        Dictation.Phase.Finishing -> {}
                    }
                    true
                }
            }
            .pointerInput(d) {
                detectTapGestures(onPress = {
                    when (d.phase) {
                        Dictation.Phase.Finishing -> return@detectTapGestures
                        Dictation.Phase.Listening -> {
                            if (tryAwaitRelease()) stop()
                            return@detectTapGestures
                        }
                        Dictation.Phase.Idle -> {}
                    }
                    if (!start()) return@detectTapGestures
                    haptic.performHapticFeedback(HapticFeedbackType.ToggleOn)
                    val down = SystemClock.uptimeMillis()
                    tryAwaitRelease()
                    if (SystemClock.uptimeMillis() - down >= HOLD_MS && d.phase == Dictation.Phase.Listening) stop()
                })
            },
        contentAlignment = Alignment.Center,
    ) {
        AnimatedContent(
            d.phase,
            transitionSpec = { (fadeIn(tween(160)) + scaleIn(tween(160), 0.6f)) togetherWith (fadeOut(tween(120)) + scaleOut(tween(120), 0.6f)) },
            label = "micIcon",
        ) { phase ->
            when (phase) {
                Dictation.Phase.Idle -> Sym(Ic.mic, tint = Tn.sub, size = 24.dp)
                Dictation.Phase.Listening -> Sym(Ic.stop, tint = Tn.onAccent, size = 24.dp)
                Dictation.Phase.Finishing -> CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Tn.magenta)
            }
        }
    }
}

/**
 * The full-width panel of a dictation: a header with the state, the
 * language, and the time, then the live voice wave, then the words. The
 * final words are bright, and the words that the recognizer still hears
 * are dim. The stop key lies over the lower right corner. The border runs
 * in the gradient of the active window on Omarchy.
 */
@Composable
private fun ListeningPanel(d: Dictation, onCancel: () -> Unit, onLanguage: (() -> Unit)?, modifier: Modifier = Modifier) {
    val listening = d.phase == Dictation.Phase.Listening
    val colors = listOf(Tn.blue, Tn.cyan, Tn.magenta, Tn.blue)
    val flow = rememberInfiniteTransition(label = "panel")
    val shift = flow.animateFloat(0f, 1f, infiniteRepeatable(tween(2600, easing = LinearEasing)), label = "panelBorder")
    val blink = flow.animateFloat(1f, 0.25f, infiniteRepeatable(tween(700), RepeatMode.Reverse), label = "panelDot")

    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    LaunchedEffect(d.phase) {
        while (isActive && d.phase != Dictation.Phase.Idle) {
            now = SystemClock.elapsedRealtime()
            delay(250)
        }
    }

    Column(
        modifier
            .clip(TileShape)
            .background(Tn.tileHi)
            .drawWithContent {
                drawContent()
                val w = size.width
                val brush = Brush.linearGradient(
                    colors,
                    start = Offset(shift.value * w, 0f),
                    end = Offset(shift.value * w + w, size.height * 0.4f),
                    tileMode = TileMode.Repeated,
                )
                val stroke = 1.5.dp.toPx()
                drawRoundRect(
                    brush,
                    topLeft = Offset(stroke / 2, stroke / 2),
                    size = Size(size.width - stroke, size.height - stroke),
                    cornerRadius = CornerRadius(12.dp.toPx() - stroke / 2),
                    style = Stroke(stroke),
                )
            }
            .padding(start = PanelPad, end = PanelEnd, top = 8.dp, bottom = PanelPad),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(8.dp).graphicsLayer { alpha = if (listening) blink.value else 1f }.clip(CircleShape).background(if (listening) Tn.red else Tn.magenta))
            TileLabel(if (listening) "listening" else "transcribing", color = if (listening) Tn.red else Tn.magenta)
            if (onLanguage != null) LanguageChip(d.language, onLanguage) else if (d.language.isNotEmpty()) TileLabel(d.language)
            Spacer(Modifier.weight(1f))
            T(DictationText.clock(now - d.startedAt), size = 12, color = Tn.sub, family = Mono, maxLines = 1)
            Box(
                Modifier.size(32.dp).clip(RoundedCornerShape(8.dp)).clickable(onClickLabel = "Cancel dictation", onClick = onCancel),
                contentAlignment = Alignment.Center,
            ) { Sym(Ic.close, "Cancel dictation", tint = Tn.dim, size = 18.dp) }
        }
        VoiceWave(d, Modifier.fillMaxWidth().height(40.dp).padding(end = 6.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Transcript(d, Modifier.weight(1f))
            // The stop key lies over this place: its width, its margin to the edge, and a gap.
            Spacer(Modifier.size(KeySize + PanelPad - PanelEnd + 10.dp, KeySize))
        }
    }
}

/** The language of the dictation. A tap opens the language picker. */
@Composable
private fun LanguageChip(tag: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(6.dp)
    Row(
        Modifier.height(26.dp).clip(shape).background(Tn.tile).border(1.dp, Tn.line, shape)
            .clickable(onClickLabel = "Choose the dictation language", onClick = onClick)
            .padding(start = 8.dp, end = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        TileLabel(tag.ifEmpty { "language" }, color = Tn.sub)
        Sym(Ic.chevron, null, Modifier.graphicsLayer { rotationZ = 90f }, tint = Tn.dim, size = 16.dp)
    }
}

/**
 * The words of the dictation, with a blinking caret at the end while the
 * phone listens. The newest words stay in view: older lines scroll up.
 */
@Composable
private fun Transcript(d: Dictation, modifier: Modifier = Modifier) {
    val listening = d.phase == Dictation.Phase.Listening
    var caret by remember { mutableStateOf(true) }
    LaunchedEffect(listening) {
        caret = true
        while (isActive && listening) {
            delay(530)
            caret = !caret
        }
    }
    val scroll = rememberScrollState()
    LaunchedEffect(scroll) { snapshotFlow { scroll.maxValue }.collect { scroll.scrollTo(it) } }

    val settled = d.settled
    val pending = d.pending
    val empty = settled.isEmpty() && pending.isEmpty()
    val text = buildAnnotatedString {
        if (empty) {
            withStyle(SpanStyle(color = Tn.dim)) {
                append(if (d.onDevice) "Speak now. This phone transcribes on the device." else "Speak now.")
            }
        } else {
            withStyle(SpanStyle(color = Tn.text)) { append(settled) }
            if (pending.isNotEmpty()) {
                if (settled.isNotEmpty()) append(" ")
                withStyle(SpanStyle(color = Tn.sub)) { append(pending) }
            }
        }
        if (listening) withStyle(SpanStyle(color = if (caret) Tn.magenta else Tn.magenta.copy(alpha = 0f))) { append(" ▍") }
    }
    Box(
        modifier
            .heightIn(min = KeySize, max = 96.dp)
            .verticalScroll(scroll)
            .semantics { liveRegion = LiveRegionMode.Polite },
        contentAlignment = Alignment.TopStart,
    ) {
        BasicText(text, Modifier.fillMaxWidth(), style = TextStyle(fontSize = 15.sp, lineHeight = 21.sp))
    }
}

/**
 * The live voice wave: rounded bars that scroll from right to left, with
 * the newest level at the right edge. Older bars fade. When the recognizer
 * reports no level, or the user is quiet, the bars breathe, so the wave
 * still shows that the phone listens.
 */
@Composable
private fun VoiceWave(d: Dictation, modifier: Modifier = Modifier) {
    val colors = listOf(Tn.blue, Tn.cyan, Tn.magenta)
    val wave = remember { WaveState() }
    LaunchedEffect(wave) {
        while (isActive) withFrameNanos { wave.step(it, d) }
    }
    Canvas(modifier) {
        val frame = wave.frame // A new frame draws again.
        if (frame == 0L) return@Canvas
        val barW = 3.dp.toPx()
        val step = barW + 3.dp.toPx()
        val mid = size.height / 2
        val minH = 3.dp.toPx()
        val breath = 2.5.dp.toPx()
        val brush = Brush.horizontalGradient(colors, 0f, size.width)
        val t = wave.clockSec
        val count = minOf(WaveState.BARS, (size.width / step).toInt() + 2)
        for (i in 0 until count) {
            val x = size.width - barW / 2 - (i + wave.progress) * step
            if (x < -barW) break
            val v = wave.value(i)
            val rest = minH + breath * (0.5f + 0.5f * sin((t * 2 * PI * 0.8 + i * 0.45).toFloat()))
            val h = maxOf(rest, v * (size.height - 2.dp.toPx()))
            // The newest bars are at full strength. The oldest fade out at the left edge.
            val fade = (x / (size.width * FADE_PART)).coerceIn(0f, 1f)
            drawLine(
                brush,
                Offset(x, mid - h / 2),
                Offset(x, mid + h / 2),
                strokeWidth = barW,
                cap = StrokeCap.Round,
                alpha = 0.12f + 0.88f * fade,
            )
        }
    }
}

/**
 * The state of [VoiceWave] between frames: a ring of bar heights and a
 * smoothed level. [step] runs once per frame and changes [frame], which
 * makes the canvas draw again without a new composition.
 */
private class WaveState {
    private val bars = FloatArray(BARS)
    private var head = 0
    private var smooth = 0f
    private var last = 0L
    private var pushedAt = 0L
    private var start = 0L

    var frame by mutableLongStateOf(0L)
        private set

    /** The part of the next bar step that has passed, from 0 to 1, for a smooth scroll. */
    var progress = 0f
        private set

    /** The seconds since the first frame, for the breath of the bars. */
    var clockSec = 0.0
        private set

    fun step(nanos: Long, d: Dictation) {
        if (start == 0L) {
            start = nanos
            last = nanos
            pushedAt = nanos
        }
        val dt = ((nanos - last) / 1e9f).coerceIn(0f, 0.1f)
        last = nanos
        clockSec = (nanos - start) / 1e9
        val live = d.phase == Dictation.Phase.Listening && SystemClock.elapsedRealtime() - d.levelAt < STALE_MS
        val target = if (live) d.level else 0f
        // A fast rise and a slow fall, as a level meter moves.
        val rate = if (target > smooth) ATTACK else RELEASE
        smooth += (target - smooth) * (1f - exp(-rate * dt))
        var elapsed = nanos - pushedAt
        while (elapsed >= SAMPLE_NS) {
            head = (head + 1) % BARS
            // A small random part makes the bars look like a voice, not a meter.
            bars[head] = (smooth * (0.7f + 0.5f * Random.nextFloat())).coerceIn(0f, 1f)
            pushedAt += SAMPLE_NS
            elapsed -= SAMPLE_NS
        }
        progress = (elapsed.toFloat() / SAMPLE_NS).coerceIn(0f, 1f)
        frame = nanos
    }

    /** The height of bar [i] from 0 to 1. Bar 0 is the newest. */
    fun value(i: Int): Float = bars[Math.floorMod(head - i, BARS)]

    companion object {
        const val BARS = 128
        private const val SAMPLE_NS = 70_000_000L
        private const val STALE_MS = 400L
        private const val ATTACK = 28f
        private const val RELEASE = 7f
    }
}
