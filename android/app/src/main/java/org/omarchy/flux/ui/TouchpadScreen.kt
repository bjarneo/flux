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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.hypot
import kotlin.math.max
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.RemoteInput
import org.omarchy.flux.core.Shortcuts
import org.omarchy.flux.core.TypeMirror
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.voice.VoiceField
import org.omarchy.flux.voice.VoiceTyping
import org.omarchy.flux.voice.rememberVoiceTyping

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

/** The length after which the type field starts again for a computer without repeat, see [RemoteTyping.change]. */
private const val RESTART_LENGTH = 48

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
        TiledTopBar("Touchpad and keyboard", onBack, context = d.name) {
            if (ready) {
                SlidesSwitch(slides) {
                    slides = it
                    FluxCore.toast(if (it) "The volume keys change slides" else "The volume keys change the volume")
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
    fun send(p: Packet) {
        if (!RemoteInput.send(FluxCore, d.id, p)) FluxCore.toast("${d.name} is not reachable")
    }
    // A click or a dictation moves the cursor of the computer, so the type field starts again.
    val typing = remember(d.id) { RemoteTyping() }
    // Dictation types its words on the computer. A dictation right after another starts with a space.
    var afterVoice by remember { mutableStateOf(false) }
    val voice = rememberVoiceTyping { spoken ->
        typing.end()
        send(RemoteInput.text(if (afterVoice) " $spoken" else spoken))
        afterVoice = true
    }
    fun sendKey(p: Packet) {
        afterVoice = false
        send(p)
    }

    Column(Modifier.fillMaxSize().padding(bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(TileGap)) {
        Box(
            Modifier.weight(1f).fillMaxWidth().clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)
                .touchpad(
                    onMove = { dx, dy -> send(RemoteInput.move(dx, dy)) },
                    onScroll = { dx, dy -> send(RemoteInput.scroll(dx, dy)) },
                    onClick = {
                        typing.end()
                        send(RemoteInput.click(it))
                    },
                    onHold = { down ->
                        if (down) {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            typing.end()
                        }
                        send(RemoteInput.hold(down))
                    },
                ),
            contentAlignment = Alignment.Center,
        ) {
            T(
                "1 finger moves · tap clicks\n2 fingers scroll · tap for the right button\nHold still to drag",
                size = 12, color = Tn.sub, align = TextAlign.Center, lineHeight = 1.5f,
            )
        }
        KeyRow(Modifier.heightIn(min = 52.dp), gap = TileGap) {
            HoldButton("Left button", Modifier.weight(1f)) { down ->
                if (down) typing.end()
                send(RemoteInput.hold(down))
            }
            PadKey("right", "Right button", Modifier.weight(1f)) {
                typing.end()
                send(RemoteInput.click(RemoteInput.Click.Right))
            }
        }
        KeyPanel(d, typing, ::sendKey, voice = voice)
    }
}

/**
 * The keys and the text field for the phone keyboard: Escape, Tab, the
 * arrows, the modifiers, Backspace, and Enter. A modifier holds for the
 * next key or text. With [voice], a mic key next to the field dictates,
 * and the Enter key moves next to the field, so that the panel has 1
 * Enter key. [typing] holds the text of the field and the draft.
 */
@Composable
fun KeyPanel(
    d: DeviceUi,
    typing: RemoteTyping,
    send: (Packet) -> Unit,
    modifier: Modifier = Modifier,
    voice: VoiceTyping? = null,
) {
    var mods by remember { mutableStateOf(RemoteInput.Mods()) }
    fun key(k: RemoteInput.Key) {
        // Backspace deletes the last character of the field, so that the field keeps the text of the computer.
        if (k == RemoteInput.Key.Backspace && !mods.any && typing.backspace(d.keyRepeat, send)) return
        // Another key can move the cursor of the computer, so the field starts again.
        typing.end()
        send(RemoteInput.key(k, mods))
        mods = RemoteInput.Mods()
    }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(TileGap)) {
        KeyRow {
            for (k in listOf(RemoteInput.Key.Escape, RemoteInput.Key.Tab, RemoteInput.Key.Left, RemoteInput.Key.Up, RemoteInput.Key.Down, RemoteInput.Key.Right)) {
                PadKey(k.label, k.name, Modifier.weight(1f)) { key(k) }
            }
        }
        KeyRow {
            ModKey("ctrl", "Control", mods.ctrl) { mods = mods.copy(ctrl = !mods.ctrl) }
            ModKey("alt", "Alt", mods.alt) { mods = mods.copy(alt = !mods.alt) }
            ModKey("shift", "Shift", mods.shift) { mods = mods.copy(shift = !mods.shift) }
            ModKey("super", "Super", mods.meta) { mods = mods.copy(meta = !mods.meta) }
            PadKey(RemoteInput.Key.Backspace.label, "Backspace", Modifier.weight(1f)) { key(RemoteInput.Key.Backspace) }
            // With voice, the Enter key is next to the field.
            if (voice == null) PadKey(RemoteInput.Key.Enter.label, "Enter", Modifier.weight(1f)) { key(RemoteInput.Key.Enter) }
        }
        if (voice == null) {
            TypeField(d, typing, mods, onSend = send, onModsUsed = { mods = RemoteInput.Mods() }, onEnter = { key(RemoteInput.Key.Enter) }, Modifier.fillMaxWidth())
        } else {
            VoiceField(
                voice,
                // The mic key sits before this key. Dictate, then press Enter.
                send = {
                    FieldKey("Enter", onClick = { key(RemoteInput.Key.Enter) }, filled = false) {
                        KeyLabel(RemoteInput.Key.Enter.label, LocalContentColor.current, size = 18)
                    }
                },
            ) { m ->
                TypeField(d, typing, mods, onSend = send, onModsUsed = { mods = RemoteInput.Mods() }, onEnter = { key(RemoteInput.Key.Enter) }, m, 56.dp)
            }
        }
    }
    if (typing.editing) {
        FieldEditor(
            title = "Type on ${d.name}",
            value = typing.draft,
            onValueChange = { v ->
                val text = RemoteInput.draftLines(v.text)
                typing.draft = if (text == v.text) v else TextFieldValue(text, TextRange(text.length))
            },
            onDismiss = { typing.editing = false },
            placeholder = "Write and correct the text here. It goes to ${d.name} when you select Type.",
            keyboard = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            maxLength = RemoteInput.MAX_DRAFT,
            hint = "Each line break goes as Shift+Enter. A draft holds at most ${RemoteInput.MAX_DRAFT_LINES} lines.",
        ) {
            FluxButton("Type", {
                mods = RemoteInput.Mods()
                typing.typeDraft(send)
            }, icon = Ic.keyboard, enabled = typing.draft.text.isNotBlank())
        }
    }
}

/** The empty type field: the sentinel with the cursor after it. */
private val EmptyField = TextFieldValue(SENTINEL, TextRange(SENTINEL.length))

/**
 * The type field of the keys and the draft of 1 screen. The field holds
 * the text that it typed on the computer since the last click, key, or
 * dictation, so that Clear can delete that text there. See [TypeMirror].
 * The draft goes to the computer only when the user selects Type.
 */
@Stable
class RemoteTyping {
    var input by mutableStateOf(EmptyField)
        private set
    private val mirror = TypeMirror()

    /** The text of the draft editor. */
    var draft by mutableStateOf(TextFieldValue(""))

    /** True while the draft editor shows. */
    var editing by mutableStateOf(false)

    /** The text of the field, with the text that the keyboard composes. */
    val text: String get() = input.text.removePrefix(SENTINEL)

    /** Forgets the text of the field. The computer keeps the text. */
    fun end() {
        mirror.reset()
        input = EmptyField
    }

    /**
     * Sends a change of the field to the computer as backspaces and new
     * text. A word goes only after the keyboard stops composing it. With
     * [repeat], 1 packet holds the backspaces. While [mods] holds a
     * modifier, new text goes as a shortcut, and [shortcut] can turn it
     * into another packet. It returns true when the shortcut used the
     * modifiers.
     */
    fun change(
        v: TextFieldValue,
        mods: RemoteInput.Mods,
        repeat: Boolean,
        shortcut: (String) -> Packet?,
        send: (Packet) -> Unit,
    ): Boolean {
        val composing = v.composition
        val stable = if (composing != null && composing.end == v.text.length) v.text.substring(0, composing.start) else v.text
        if (!stable.startsWith(SENTINEL)) {
            val rest = stable.replace(SENTINEL, "")
            if (rest.isEmpty() && mirror.sent.isEmpty()) {
                // Backspace in the empty field deletes the sentinel: the computer gets the backspace.
                send(RemoteInput.key(RemoteInput.Key.Backspace))
                input = EmptyField
                return false
            }
            // The keyboard replaced the text or deleted the sentinel at the start. The rest is the new text.
            return change(TextFieldValue(SENTINEL + rest, TextRange(SENTINEL.length + rest.length)), mods, repeat, shortcut, send)
        }
        val body = stable.substring(SENTINEL.length)
        val line = body.indexOf('\n')
        if (line >= 0) {
            // A line break, for example from a paste, presses Enter.
            change(TextFieldValue(SENTINEL + body.substring(0, line), TextRange(SENTINEL.length + line)), mods, repeat, shortcut, send)
            send(RemoteInput.key(RemoteInput.Key.Enter))
            end()
            return false
        }
        return when (val c = mirror.change(body, mods.any)) {
            is TypeMirror.Change.Shortcut -> {
                // A shortcut such as ctrl+c. The letter does not stay in the field.
                send(shortcut(c.text) ?: RemoteInput.text(c.text, mods))
                input = EmptyField
                true
            }
            is TypeMirror.Change.Edit -> {
                RemoteInput.keys(RemoteInput.Key.Backspace, c.backspaces, repeat).forEach(send)
                if (c.text.isNotEmpty()) send(RemoteInput.text(c.text))
                // A computer without repeat gets 1 packet for each backspace, and it drops packets after
                // 256 waiting actions. For it, a long line starts again after a word, so that Clear stays short.
                if (!repeat && composing == null && body.length > RESTART_LENGTH && body.endsWith(" ")) end() else input = v
                false
            }
        }
    }

    /** Deletes the text of the field on the computer, then empties the field. */
    fun clear(repeat: Boolean, send: (Packet) -> Unit) {
        RemoteInput.keys(RemoteInput.Key.Backspace, mirror.clear(), repeat).forEach(send)
        input = EmptyField
    }

    /**
     * The Backspace key of the keys: it deletes the last character of the
     * field, also on the computer. It returns false when the field is empty.
     */
    fun backspace(repeat: Boolean, send: (Packet) -> Unit): Boolean {
        val body = text
        if (body.isEmpty()) return false
        val shorter = body.substring(0, body.offsetByCodePoints(body.length, -1))
        change(TextFieldValue(SENTINEL + shorter, TextRange(SENTINEL.length + shorter.length)), RemoteInput.Mods(), repeat, { null }, send)
        return true
    }

    /** Types the draft on the computer, then empties the draft and closes the editor. */
    fun typeDraft(send: (Packet) -> Unit) {
        end()
        RemoteInput.draft(draft.text).forEach(send)
        draft = TextFieldValue("")
        editing = false
    }
}

/**
 * The text field for the phone keyboard. Each change goes to the computer
 * as backspaces and new text, see [RemoteTyping.change]. The key at the
 * start opens the draft editor, and the key at the end deletes the text
 * of the field on the computer.
 */
@Composable
private fun TypeField(
    d: DeviceUi,
    typing: RemoteTyping,
    mods: RemoteInput.Mods,
    onSend: (Packet) -> Unit,
    onModsUsed: () -> Unit,
    onEnter: () -> Unit,
    modifier: Modifier = Modifier,
    height: Dp = 48.dp,
) {
    // Omarchy binds super and a digit to a key code, which the keys of the phone cannot press, so the computer switches the workspace.
    fun shortcut(text: String): Packet? = if (d.shortcutsSupported) Shortcuts.forDigit(text, mods) else null
    BasicTextField(
        value = typing.input,
        onValueChange = { if (typing.change(it, mods, d.keyRepeat, ::shortcut, onSend)) onModsUsed() },
        modifier = modifier.height(height).clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape),
        textStyle = TextStyle(color = Tn.text, fontSize = 15.sp),
        cursorBrush = SolidColor(Tn.blue),
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
        // Enter ends the text of the field, see KeyPanel.
        keyboardActions = KeyboardActions(onSend = { onEnter() }),
        decorationBox = { inner ->
            Row(Modifier.fillMaxSize().padding(end = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                ExpandKey({ typing.editing = true }, "Open the draft editor")
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                    if (typing.text.isEmpty()) T("Type on ${d.name}", color = Tn.sub, maxLines = 1)
                    inner()
                }
                if (typing.text.isNotEmpty()) ClearKey({ typing.clear(d.keyRepeat, onSend) }, "Clear the text on ${d.name}")
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

/** A key of the touchpad, with a mono label. TalkBack reads [description]. */
@Composable
private fun PadKey(label: String, description: String, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier.fillMaxHeight().clip(RoundedCornerShape(8.dp)).background(Tn.tile)
            .border(1.dp, Tn.line, RoundedCornerShape(8.dp))
            .clickable(onClickLabel = description, role = Role.Button, onClick = onClick)
            .clearAndSetSemantics { contentDescription = description }
            .padding(horizontal = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        KeyLabel(label, Tn.sub, size = 13)
    }
}

/**
 * A modifier key. It stays on for the next key or text. TalkBack reads it
 * as a switch: [name], on or off.
 */
@Composable
private fun RowScope.ModKey(label: String, name: String, on: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(8.dp)).background(if (on) Tn.accentTile else Tn.tile)
            .border(1.dp, if (on) Tn.blue else Tn.line, RoundedCornerShape(8.dp))
            .toggleable(value = on, role = Role.Switch, onValueChange = { onClick() })
            .clearAndSetSemantics { contentDescription = "$name for the next key" }
            .padding(horizontal = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        KeyLabel(label, if (on) Tn.blue else Tn.sub)
    }
}

/**
 * The switch that lets the volume keys change the slides on the computer.
 * It shows an icon and a label, and TalkBack reads it as a switch.
 */
@Composable
private fun SlidesSwitch(on: Boolean, onChange: (Boolean) -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    Row(
        Modifier.minimumInteractiveComponentSize().heightIn(min = 40.dp).clip(shape).background(choiceFill(on)).border(choiceBorder(on), shape)
            .toggleable(value = on, role = Role.Switch, onValueChange = onChange)
            // TalkBack reads the label 1 time, with the switch role and its state.
            .clearAndSetSemantics { contentDescription = "Volume keys change slides" }
            .padding(horizontal = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(Ic.slides, tint = if (on) Tn.blue else Tn.sub, size = 20.dp)
        T("Slides", size = 13, color = if (on) Tn.text else Tn.sub, weight = FontWeight.SemiBold)
    }
}

/** The left button: it stays pressed while the finger is on it, for a drag with the other hand. */
@Composable
private fun HoldButton(description: String, modifier: Modifier, onChange: (Boolean) -> Unit) {
    var pressed by remember { mutableStateOf(false) }
    Box(
        modifier.fillMaxHeight().clip(RoundedCornerShape(8.dp)).background(if (pressed) Tn.accentTile else Tn.tile)
            .border(1.dp, if (pressed) Tn.blue else Tn.line, RoundedCornerShape(8.dp))
            // TalkBack cannot hold the button, so its action clicks: a press and a release.
            .clearAndSetSemantics {
                contentDescription = description
                role = Role.Button
                onClick {
                    onChange(true)
                    onChange(false)
                    true
                }
            }
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
        KeyLabel("left", if (pressed) Tn.blue else Tn.sub, size = 13)
    }
}
