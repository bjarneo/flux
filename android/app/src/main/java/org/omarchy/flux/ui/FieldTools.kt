package org.omarchy.flux.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

/** The key in a text field that empties the field. TalkBack reads [description]. */
@Composable
fun ClearKey(onClear: () -> Unit, description: String = "Clear") {
    IconButton(onClick = onClear) { Sym(Ic.close, description, tint = Tn.sub, size = 20.dp) }
}

/** The key in a text field that opens the large editor. TalkBack reads [description]. */
@Composable
fun ExpandKey(onExpand: () -> Unit, description: String = "Open the large editor") {
    IconButton(onClick = onExpand) { Sym(Ic.openFull, description, tint = Tn.sub, size = 18.dp) }
}

/**
 * The keys at the end of a text field: Clear while the field has text,
 * and Expand when [onExpand] is set.
 */
@Composable
fun FieldKeys(hasText: Boolean, onClear: () -> Unit, onExpand: (() -> Unit)? = null) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (hasText) ClearKey(onClear)
        if (onExpand != null) ExpandKey(onExpand)
    }
}

/** Returns this value with at most [max] characters. A longer text is cut, and the cursor stays in the text. */
fun TextFieldValue.limited(max: Int): TextFieldValue {
    if (text.length <= max) return this
    val cut = text.substring(0, max).let { if (it.isNotEmpty() && it.last().isHighSurrogate()) it.dropLast(1) else it }
    return TextFieldValue(cut, TextRange(selection.start.coerceAtMost(cut.length), selection.end.coerceAtMost(cut.length)))
}

/**
 * A large editor on the full screen for the text of a field. It edits
 * the same [value] as the field, so Close keeps the text. Clear empties
 * it. [action] draws the main key, such as Send, at the right of the
 * bottom bar. Without [action], the bar has Done. [hint] shows under the
 * text, and [maxLength] limits the text. On a short screen, the keys
 * move to the top row, and the hint hides.
 */
@Composable
fun FieldEditor(
    title: String,
    value: TextFieldValue,
    onValueChange: (TextFieldValue) -> Unit,
    onDismiss: () -> Unit,
    context: String? = null,
    placeholder: String = "",
    mono: Boolean = false,
    keyboard: KeyboardOptions = KeyboardOptions.Default,
    maxLength: Int = Int.MAX_VALUE,
    hint: String? = null,
    action: (@Composable RowScope.() -> Unit)? = null,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(Modifier.fillMaxSize(), color = Tn.bg, contentColor = Tn.text) {
            BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding().imePadding().padding(horizontal = TiledGutter)) {
                // A phone in landscape with the keyboard open has little height. The keys then move to the top row, so that the text keeps the room.
                val compact = maxHeight < 320.dp
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(if (compact) 4.dp else TileGap)) {
                    Row(
                        Modifier.fillMaxWidth().padding(top = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(TileGap),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f).padding(start = 4.dp)) {
                            T(title, Modifier.semantics { heading() }, size = 18, weight = FontWeight.SemiBold, lineHeight = 1.2f, maxLines = if (compact) 1 else Int.MAX_VALUE)
                            if (!context.isNullOrEmpty() && !compact) T(context, size = 12, color = Tn.sub, family = Mono)
                        }
                        if (compact) {
                            // A word, not a second close icon next to Close.
                            if (value.text.isNotEmpty()) FluxButton("Clear", { onValueChange(TextFieldValue("")) }, kind = ButtonKind.Text)
                            if (action != null) action() else FluxButton("Done", onDismiss)
                        }
                        SquareButton(Ic.close, "Close the editor", onDismiss)
                    }
                    val focus = remember { FocusRequester() }
                    // The editor opens with the cursor at the end, ready for the keyboard.
                    LaunchedEffect(Unit) {
                        if (value.selection.collapsed && value.selection.start == 0 && value.text.isNotEmpty()) {
                            onValueChange(value.copy(selection = TextRange(value.text.length)))
                        }
                        focus.requestFocus()
                    }
                    OutlinedTextField(
                        value = value,
                        onValueChange = { onValueChange(it.limited(maxLength)) },
                        modifier = Modifier.weight(1f).fillMaxWidth().focusRequester(focus),
                        placeholder = { T(placeholder, color = Tn.sub, family = if (mono) Mono else FontFamily.Default) },
                        textStyle = TextStyle(
                            color = Tn.text,
                            fontFamily = if (mono) Mono else FontFamily.Default,
                            fontSize = if (mono) 14.sp else 16.sp,
                            lineHeight = if (mono) 20.sp else 24.sp,
                        ),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Tn.blue, unfocusedBorderColor = Tn.dim),
                        shape = TileShape,
                        keyboardOptions = keyboard,
                    )
                    if (!compact) {
                        val count = value.text.length
                        val near = maxLength != Int.MAX_VALUE && count > maxLength * 9 / 10
                        if (hint != null || near) {
                            T(
                                listOfNotNull(hint, if (near) "$count of $maxLength characters" else null).joinToString(" · "),
                                Modifier.padding(horizontal = 4.dp), size = 12, color = if (count >= maxLength) Tn.red else Tn.sub,
                            )
                        }
                        Row(
                            Modifier.fillMaxWidth().padding(bottom = 10.dp),
                            horizontalArrangement = Arrangement.spacedBy(TileGap),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            FluxButton("Clear", { onValueChange(TextFieldValue("")) }, kind = ButtonKind.Outlined, icon = Ic.close, enabled = value.text.isNotEmpty())
                            Spacer(Modifier.weight(1f).size(0.dp))
                            if (action != null) action() else FluxButton("Done", onDismiss)
                        }
                    } else {
                        Spacer(Modifier.size(4.dp))
                    }
                }
            }
        }
    }
}
