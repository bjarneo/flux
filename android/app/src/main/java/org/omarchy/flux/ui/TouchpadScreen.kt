package org.omarchy.flux.ui

import android.os.SystemClock
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.RemoteInput
import org.omarchy.flux.core.Shortcuts
import org.omarchy.flux.core.TextEdit
import org.omarchy.flux.voice.VoiceField
import org.omarchy.flux.voice.VoiceTyping
import org.omarchy.flux.voice.rememberVoiceTyping
import kotlin.math.hypot
import kotlin.math.max

/** A finger that stays this long without a motion starts a drag. */
private const val HOLD_MS = 450L

/** The scroll speed, in scroll units per dp of finger motion. */
private const val SCROLL_SPEED = 1.2f

/**
 * The first character of the text field. The phone keyboard deletes it
 * when the user presses backspace in an empty field, so that the computer
 * gets the backspace.
 */
private const val SENTINEL = "​"

/**
 * The touchpad and the keyboard for a computer. The computer runs the
 * input only while its remote_input setting is on.
 */
@Composable
fun TouchpadScreen(d: DeviceUi, onBack: () -> Unit) {
    var slides by remember { mutableStateOf(false) }
    // The touchpad takes input only after the phone lock, see rememberRemoteUnlock.
    val unlocked = rememberRemoteUnlock(
        d.online && d.inputSupported && d.remoteInput == true, "Use the touchpad", "use the touchpad", onBack, sample = isDemo(d.id),
    )
    val ready = d.online && d.inputSupported && d.remoteInput == true && unlocked
    // The volume keys change slides while the switch is on and the screen shows.
    DisposableEffect(d.id, slides, ready) {
        RemoteInput.volumeKeysDevice = if (slides && ready) d.id else null
        onDispose { RemoteInput.volumeKeysDevice = null }
    }
    val view = LocalView.current
    DisposableEffect(ready) {
        view.keepScreenOn = ready
        onDispose { view.keepScreenOn = false }
    }
    // The phone keyboard pushes the keys and the field up, and the touchpad gets smaller.
    Column(Modifier.fillMaxSize().imePadding().padding(horizontal = TiledGutter)) {
        TiledTopBar("touchpad · ${d.name}", onBack) {
            if (ready) {
                Box(
                    Modifier.clip(RoundedCornerShape(8.dp)).background(if (slides) Tn.tileHi else Tn.bg)
                        .border(1.dp, if (slides) Tn.green else Tn.bg, RoundedCornerShape(8.dp))
                        .clickable(onClickLabel = "Change slides with the volume keys") {
                            slides = !slides
                            FluxCore.toast(if (slides) "The volume keys change slides" else "The volume keys change the volume")
                        }.padding(8.dp),
                ) {
                    Sym(Ic.slides, "Slides", tint = if (slides) Tn.green else Tn.sub, size = 22.dp)
                }
            }
        }
        when {
            !d.online -> NotReachable(d, "The touchpad controls")
            !d.inputSupported -> EmptyState(
                Ic.touchpad, "Update Flux on ${d.name}",
                "This version of Flux on ${d.name} does not take input from the phone.",
                Modifier.padding(top = 48.dp),
            )
            d.remoteInput != true -> EmptyState(
                Ic.touchpad, "Remote input is off",
                "On ${d.name}, set remote_input = true in ~/.config/flux/config.toml, then run systemctl --user reload fluxd.",
                Modifier.padding(top = 48.dp),
            )
            !unlocked -> EmptyState(Ic.touchpad, "Unlock to continue", "Confirm with the phone lock to use the touchpad.", Modifier.padding(top = 48.dp))
            else -> Touchpad(d)
        }
    }
}

@Composable
private fun Touchpad(d: DeviceUi) {
    val haptic = LocalHapticFeedback.current
    fun send(p: org.omarchy.flux.protocol.Packet) {
        if (!RemoteInput.send(FluxCore, d.id, p)) FluxCore.toast("${d.name} is not reachable")
    }
    // Dictation types its words on the computer. A dictation right after another starts with a space.
    var afterVoice by remember { mutableStateOf(false) }
    val voice = rememberVoiceTyping { spoken ->
        send(RemoteInput.text(if (afterVoice) " $spoken" else spoken))
        afterVoice = true
    }
    fun sendKey(p: org.omarchy.flux.protocol.Packet) {
        afterVoice = false
        send(p)
    }

    Column(Modifier.fillMaxSize().padding(bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(TileGap)) {
        Box(
            Modifier.weight(1f).fillMaxWidth().clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)
                .touchpad(
                    onMove = { dx, dy -> send(RemoteInput.move(dx, dy)) },
                    onScroll = { dx, dy -> send(RemoteInput.scroll(dx, dy)) },
                    onClick = { send(RemoteInput.click(it)) },
                    onHold = { down ->
                        if (down) haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        send(RemoteInput.hold(down))
                    },
                ),
            contentAlignment = Alignment.Center,
        ) {
            T(
                "1 finger moves · tap clicks\n2 fingers scroll · tap for the right button\nHold still to drag",
                size = 12, color = Tn.dim, align = TextAlign.Center, lineHeight = 1.5f,
            )
        }
        Row(Modifier.fillMaxWidth().height(52.dp), horizontalArrangement = Arrangement.spacedBy(TileGap)) {
            HoldButton("Left button", Modifier.weight(1f)) { down -> send(RemoteInput.hold(down)) }
            PadKey("right", "Right button", Modifier.weight(1f)) { send(RemoteInput.click(RemoteInput.Click.Right)) }
        }
        KeyPanel(d, ::sendKey, voice = voice)
    }
}

/**
 * The keys and the text field for the phone keyboard: Escape, Tab, the
 * arrows, the modifiers, Backspace, and Enter. A modifier holds for the
 * next key or text. With [voice], a mic key next to the field dictates.
 */
@Composable
fun KeyPanel(
    d: DeviceUi,
    send: (org.omarchy.flux.protocol.Packet) -> Unit,
    modifier: Modifier = Modifier,
    voice: VoiceTyping? = null,
) {
    var mods by remember { mutableStateOf(RemoteInput.Mods()) }
    fun key(k: RemoteInput.Key) {
        send(RemoteInput.key(k, mods))
        mods = RemoteInput.Mods()
    }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(TileGap)) {
        Row(Modifier.fillMaxWidth().height(40.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (k in listOf(RemoteInput.Key.Escape, RemoteInput.Key.Tab, RemoteInput.Key.Left, RemoteInput.Key.Up, RemoteInput.Key.Down, RemoteInput.Key.Right)) {
                PadKey(k.label, k.name, Modifier.weight(1f)) { key(k) }
            }
        }
        Row(Modifier.fillMaxWidth().height(40.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            ModKey("ctrl", mods.ctrl) { mods = mods.copy(ctrl = !mods.ctrl) }
            ModKey("alt", mods.alt) { mods = mods.copy(alt = !mods.alt) }
            ModKey("shift", mods.shift) { mods = mods.copy(shift = !mods.shift) }
            ModKey("super", mods.meta) { mods = mods.copy(meta = !mods.meta) }
            PadKey(RemoteInput.Key.Backspace.label, "Backspace", Modifier.weight(1f)) { key(RemoteInput.Key.Backspace) }
            PadKey(RemoteInput.Key.Enter.label, "Enter", Modifier.weight(1f)) { key(RemoteInput.Key.Enter) }
        }
        if (voice == null) {
            TypeField(d, mods, onSend = send, onModsUsed = { mods = RemoteInput.Mods() }, onEnter = { key(RemoteInput.Key.Enter) }, Modifier.fillMaxWidth())
        } else {
            VoiceField(
                voice,
                // The mic key sits before this key. Dictate, then press Enter.
                send = {
                    Box(
                        Modifier.size(56.dp).clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)
                            .clickable(onClickLabel = "Enter") { key(RemoteInput.Key.Enter) },
                        contentAlignment = Alignment.Center,
                    ) { T(RemoteInput.Key.Enter.label, size = 16, color = Tn.sub, weight = FontWeight.SemiBold, family = Mono) }
                },
            ) { m ->
                TypeField(d, mods, onSend = send, onModsUsed = { mods = RemoteInput.Mods() }, onEnter = { key(RemoteInput.Key.Enter) }, m, 56.dp)
            }
        }
    }
}

/**
 * The text field for the phone keyboard. Each change goes to the computer
 * as backspaces and new text, see [TextEdit]. The field sends a word only
 * after the keyboard stops composing it.
 */
@Composable
private fun TypeField(
    d: DeviceUi,
    mods: RemoteInput.Mods,
    onSend: (org.omarchy.flux.protocol.Packet) -> Unit,
    onModsUsed: () -> Unit,
    onEnter: () -> Unit,
    modifier: Modifier = Modifier,
    height: Dp = 48.dp,
) {
    val empty = TextFieldValue(SENTINEL, TextRange(SENTINEL.length))
    var field by remember { mutableStateOf(empty) }
    // The text after the sentinel that the computer has.
    var sent by remember { mutableStateOf("") }

    fun reset() {
        field = empty
        sent = ""
    }

    fun change(v: TextFieldValue) {
        val composing = v.composition
        val stable = if (composing != null && composing.end == v.text.length) v.text.substring(0, composing.start) else v.text
        if (!stable.startsWith(SENTINEL)) {
            // The keyboard deleted the sentinel: 1 backspace more than the text.
            repeat(sent.codePointCount(0, sent.length) + 1) { onSend(RemoteInput.key(RemoteInput.Key.Backspace)) }
            reset()
            return
        }
        val body = stable.substring(SENTINEL.length)
        val edit = TextEdit.between(sent, body)
        if (mods.any && edit.text.isNotEmpty()) {
            // A shortcut such as ctrl+c. The letter does not stay in the field.
            // Omarchy binds super and a digit to a key code, which the keys of
            // the phone cannot press, so the computer switches the workspace.
            val workspace = if (d.shortcutsSupported) Shortcuts.forDigit(edit.text, mods) else null
            onSend(workspace ?: RemoteInput.text(edit.text, mods))
            onModsUsed()
            reset()
            return
        }
        repeat(edit.backspaces) { onSend(RemoteInput.key(RemoteInput.Key.Backspace)) }
        if (edit.text.isNotEmpty()) onSend(RemoteInput.text(edit.text))
        sent = body
        // A long line starts again after a word, so the field stays short.
        field = if (composing == null && body.length > 48 && body.endsWith(" ")) {
            sent = ""
            empty
        } else {
            v
        }
    }

    BasicTextField(
        value = field,
        onValueChange = ::change,
        modifier = modifier.height(height).clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape),
        textStyle = TextStyle(color = Tn.text, fontSize = 15.sp),
        cursorBrush = SolidColor(Tn.blue),
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
        keyboardActions = KeyboardActions(onSend = {
            onEnter()
            reset()
        }),
        decorationBox = { inner ->
            Row(Modifier.fillMaxSize().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Sym(Ic.keyboard, tint = Tn.sub, size = 20.dp)
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                    if (field.text == SENTINEL) T("Type on ${d.name}", color = Tn.dim, maxLines = 1)
                    inner()
                }
            }
        },
    )
}

/**
 * The gestures of the touchpad. 1 finger moves the pointer, and a tap
 * clicks. 2 fingers scroll, and a tap with 2 fingers clicks the right
 * button. A tap with 3 fingers clicks the middle button. A finger that
 * holds still starts a drag, which ends when the finger lifts.
 */
private fun Modifier.touchpad(
    onMove: (Float, Float) -> Unit,
    onScroll: (Float, Float) -> Unit,
    onClick: (RemoteInput.Click) -> Unit,
    onHold: (Boolean) -> Unit,
): Modifier = pointerInput(Unit) {
    val slop = viewConfiguration.touchSlop
    val dpPerPx = 1f / 1.dp.toPx()
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false)
        val holdAt = SystemClock.uptimeMillis() + HOLD_MS
        var fingers = 1
        var travel = 0f
        var holding = false
        // The motion before the finger passes the touch slop.
        var pending = Offset.Zero
        while (true) {
            val waitForHold = !holding && fingers == 1 && travel < slop
            val event = if (waitForHold) {
                val left = holdAt - SystemClock.uptimeMillis()
                if (left > 0) withTimeoutOrNull(left) { awaitPointerEvent() } else null
            } else {
                awaitPointerEvent()
            }
            if (event == null) {
                holding = true
                onHold(true)
                continue
            }
            val down = event.changes.filter { it.pressed }
            if (down.isEmpty()) break
            fingers = max(fingers, down.size)
            if (fingers == 1) {
                val delta = down[0].positionChange()
                travel += delta.getDistance()
                pending += delta
                if (travel >= slop || holding) {
                    val dx = pending.x * dpPerPx
                    val dy = pending.y * dpPerPx
                    val scale = RemoteInput.pointerScale(hypot(dx, dy))
                    onMove(dx * scale, dy * scale)
                    pending = Offset.Zero
                }
            } else if (down.size >= 2) {
                var sum = Offset.Zero
                for (c in down) sum += c.positionChange()
                val delta = sum / down.size.toFloat()
                travel += delta.getDistance()
                // Natural scrolling: the content follows the fingers.
                if (travel >= slop) onScroll(-delta.x * dpPerPx * SCROLL_SPEED, -delta.y * dpPerPx * SCROLL_SPEED)
            }
            event.changes.forEach { it.consume() }
        }
        when {
            holding -> onHold(false)
            travel < slop -> onClick(
                when (fingers) {
                    1 -> RemoteInput.Click.Left
                    2 -> RemoteInput.Click.Right
                    else -> RemoteInput.Click.Middle
                },
            )
        }
    }
}

/** A key of the touchpad, with a mono label. */
@Composable
private fun PadKey(label: String, description: String, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier.fillMaxHeight().clip(RoundedCornerShape(8.dp)).background(Tn.tile)
            .border(1.dp, Tn.line, RoundedCornerShape(8.dp))
            .clickable(onClickLabel = description, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        T(label, size = 13, color = Tn.sub, weight = FontWeight.SemiBold, family = Mono, maxLines = 1)
    }
}

/** A modifier key. It stays on for the next key or text. */
@Composable
private fun RowScope.ModKey(label: String, on: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(8.dp)).background(if (on) Tn.tileHi else Tn.tile)
            .border(1.dp, if (on) Tn.blue else Tn.line, RoundedCornerShape(8.dp))
            .clickable(onClickLabel = if (on) "Release $label" else "Hold $label for the next key", onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        T(label, size = 12, color = if (on) Tn.blue else Tn.sub, weight = FontWeight.SemiBold, family = Mono, maxLines = 1)
    }
}

/** The left button: it stays pressed while the finger is on it, for a drag with the other hand. */
@Composable
private fun HoldButton(description: String, modifier: Modifier, onChange: (Boolean) -> Unit) {
    var pressed by remember { mutableStateOf(false) }
    Box(
        modifier.fillMaxHeight().clip(RoundedCornerShape(8.dp)).background(if (pressed) Tn.tileHi else Tn.tile)
            .border(1.dp, if (pressed) Tn.green else Tn.line, RoundedCornerShape(8.dp))
            .semantics { contentDescription = description }
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown()
                    pressed = true
                    onChange(true)
                    waitForUpOrCancellation()
                    pressed = false
                    onChange(false)
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        T("left", size = 13, color = if (pressed) Tn.green else Tn.sub, weight = FontWeight.SemiBold, family = Mono, maxLines = 1)
    }
}
