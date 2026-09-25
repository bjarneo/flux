package org.omarchy.flux.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.graphics.drawscope.clipRect

val Mono = FontFamily.Monospace

@Composable
fun T(
    text: String,
    modifier: Modifier = Modifier,
    size: Int = 14,
    color: Color = Palette.text,
    weight: FontWeight = FontWeight.Normal,
    family: FontFamily = FontFamily.Default,
    align: TextAlign? = null,
    maxLines: Int = Int.MAX_VALUE,
    letterSpacing: Float = 0f,
    lineHeight: Float = 0f,
) {
    BasicText(
        text = text,
        modifier = modifier,
        style = TextStyle(
            color = color,
            fontSize = size.sp,
            fontWeight = weight,
            fontFamily = family,
            textAlign = align ?: TextAlign.Unspecified,
            letterSpacing = letterSpacing.sp,
            lineHeight = if (lineHeight > 0) (size * lineHeight).sp else androidx.compose.ui.unit.TextUnit.Unspecified,
        ),
        maxLines = maxLines,
        overflow = if (maxLines == Int.MAX_VALUE) TextOverflow.Clip else TextOverflow.Ellipsis,
    )
}

/** The top bar of an inner screen: a back arrow, the title, and optional content at the end. */
@Composable
fun TopBar(title: String, onBack: () -> Unit, trailing: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            Modifier.size(44.dp).clip(CircleShape).clickable(onClick = onBack),
            contentAlignment = Alignment.Center,
        ) { T("←", size = 20) }
        T(title, Modifier.weight(1f), size = 20, maxLines = 1)
        trailing()
    }
}

@Composable
fun SectionHeader(text: String, top: Int = 6) {
    T(text, Modifier.padding(start = 20.dp, end = 20.dp, top = top.dp, bottom = 6.dp), size = 13, color = Palette.accent, weight = FontWeight.Medium)
}

@Composable
fun Avatar(label: String, on: Boolean) {
    Box(
        Modifier.size(44.dp).clip(CircleShape).background(if (on) Palette.accent else Palette.avatarOff),
        contentAlignment = Alignment.Center,
    ) { T(label, color = if (on) Palette.onAccent else Palette.secondary, weight = FontWeight.Bold) }
}

/** A glyph in a rounded primary container square, used by tiles and list rows. */
@Composable
fun GlyphBox(glyph: String, mono: Boolean = false) {
    val accent = Palette.accent
    Box(
        Modifier.size(40.dp).clip(RoundedCornerShape(12.dp)).background(Palette.accentContainer),
        contentAlignment = Alignment.Center,
    ) { T(glyph, size = 18, color = Palette.onAccentContainer, family = if (mono) Mono else FontFamily.Default) }
}

/** A row that changes its background while pressed. */
@Composable
fun PressRow(
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)?,
    onLongClick: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    var m = modifier.fillMaxWidth()
    if (onClick != null || onLongClick != null) {
        m = m.background(if (pressed) Palette.rowPressed else Color.Transparent)
            .combinedClickable(interactionSource = source, indication = null, onClick = { onClick?.invoke() }, onLongClick = onLongClick)
    }
    Box(m) { content() }
}

@Composable
fun Tile(glyph: String, label: String, enabled: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    Column(
        modifier
            .clip(RoundedCornerShape(20.dp))
            .background(if (pressed) Palette.tilePressed else Palette.tile)
            .clickable(interactionSource = source, indication = null, onClick = onClick)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        GlyphBox(glyph)
        T(label, size = 15, color = if (enabled) Palette.text else Palette.secondary)
    }
}

/** The Material 3 style switch of the design: a 52 by 32 track with a 24 dp thumb. */
@Composable
fun FluxSwitch(checked: Boolean) {
    val accent = Palette.accent
    Box(
        Modifier.size(52.dp, 32.dp).clip(RoundedCornerShape(16.dp)).background(if (checked) accent else Palette.track).padding(horizontal = 4.dp),
        contentAlignment = if (checked) Alignment.CenterEnd else Alignment.CenterStart,
    ) {
        Box(Modifier.size(24.dp).clip(CircleShape).background(if (checked) Palette.onAccent else Palette.thumbOff))
    }
}

@Composable
fun SwitchRow(title: String, subtitle: String, checked: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            T(title, size = 16)
            T(subtitle, size = 13, color = Palette.secondary)
        }
        Spacer(Modifier.width(12.dp))
        FluxSwitch(checked)
    }
}

@Composable
fun Chip(text: String, filled: Boolean) {
    val accent = Palette.accent
    val m = if (filled) {
        Modifier.clip(RoundedCornerShape(8.dp)).background(Palette.accentContainer)
    } else {
        Modifier.border(1.dp, Palette.border, RoundedCornerShape(8.dp))
    }
    Box(m.padding(horizontal = 12.dp, vertical = 6.dp)) {
        T(text, size = 13, color = if (filled) Palette.onAccentContainer else Palette.text)
    }
}

/** The diagonal stripes that stand in for album art. */
fun Modifier.stripes(a: Color, b: Color, stripe: Float = 10f): Modifier = drawBehind {
    drawRect(b)
    val step = stripe * 2 * density
    val w = stripe * density * 1.4142f
    clipRect {
        var x = -size.height
        while (x < size.width + size.height) {
            drawLine(a, Offset(x, size.height), Offset(x + size.height, 0f), strokeWidth = w)
            x += step * 1.4142f
        }
    }
}

/** The snackbar of the design, at the bottom with a 16 dp margin. */
@Composable
fun BoxScope.Snack(message: String?) {
    AnimatedVisibility(
        visible = message != null,
        enter = fadeIn(),
        exit = fadeOut(),
        modifier = Modifier.align(Alignment.BottomCenter).padding(start = 16.dp, end = 16.dp, bottom = 40.dp),
    ) {
        Box(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).background(Palette.snackbar).padding(horizontal = 16.dp, vertical = 14.dp),
        ) { T(message ?: "", color = Palette.snackbarText) }
    }
}

/** The pairing dialog with the verification key. */
@Composable
fun PairDialog(name: String, key: String, waiting: Boolean, onCancel: () -> Unit, onPair: () -> Unit) {
    val accent = Palette.accent
    Box(
        Modifier.fillMaxSize().background(Palette.scrim).clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.width(312.dp).clip(RoundedCornerShape(28.dp)).background(Palette.dialog).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            T("Pair with $name?", size = 22)
            T(
                if (waiting) "Confirm the same code on $name." else "Check that this code matches the one shown on the computer.",
                color = Palette.body, lineHeight = 1.45f,
            )
            T(
                key.ifEmpty { "…" },
                Modifier.fillMaxWidth().padding(vertical = 8.dp),
                size = 30, color = accent, align = TextAlign.Center, letterSpacing = 6f, maxLines = 1,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                Box(Modifier.clip(RoundedCornerShape(20.dp)).clickable(onClick = onCancel).padding(horizontal = 14.dp, vertical = 10.dp)) {
                    T("Cancel", color = accent, weight = FontWeight.Medium)
                }
                Box(
                    Modifier.clip(RoundedCornerShape(20.dp)).background(if (waiting) Palette.accentContainer else accent)
                        .clickable(enabled = !waiting, onClick = onPair).padding(horizontal = 18.dp, vertical = 10.dp),
                ) { T(if (waiting) "Waiting…" else "Pair", color = if (waiting) Palette.onAccentContainer else Palette.onAccent, weight = FontWeight.Medium) }
            }
        }
    }
}

/** A simple confirmation dialog in the style of the pairing dialog. */
@Composable
fun ConfirmDialog(title: String, body: String, confirm: String, onCancel: () -> Unit, onConfirm: () -> Unit) {
    val accent = Palette.accent
    Box(
        Modifier.fillMaxSize().background(Palette.scrim).clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onCancel),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.width(312.dp).clip(RoundedCornerShape(28.dp)).background(Palette.dialog).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            T(title, size = 22)
            T(body, color = Palette.body, lineHeight = 1.45f)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                Box(Modifier.clip(RoundedCornerShape(20.dp)).clickable(onClick = onCancel).padding(horizontal = 14.dp, vertical = 10.dp)) {
                    T("Cancel", color = accent, weight = FontWeight.Medium)
                }
                Box(Modifier.clip(RoundedCornerShape(20.dp)).background(accent).clickable(onClick = onConfirm).padding(horizontal = 18.dp, vertical = 10.dp)) {
                    T(confirm, color = Palette.onAccent, weight = FontWeight.Medium)
                }
            }
        }
    }
}

/** The full-screen Find my phone overlay. */
@Composable
fun RingOverlay(from: String, onStop: () -> Unit) {
    val accent = Palette.accent
    Column(
        Modifier.fillMaxSize().background(accent).clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        T("FLUX · FIND MY PHONE", size = 14, color = Palette.onAccent, weight = FontWeight.Medium, letterSpacing = 2f)
        T("Ringing from\n$from", size = 40, color = Palette.onAccent, align = TextAlign.Center, lineHeight = 1.1f)
        Spacer(Modifier.size(24.dp))
        Box(
            Modifier.clip(RoundedCornerShape(40.dp)).background(Palette.onAccent).clickable(onClick = onStop).padding(horizontal = 44.dp, vertical = 18.dp),
        ) { T("I found it", size = 18, color = accent) }
    }
}

/**
 * The Flux mark, variant 4a: an accent square with an outline square over it.
 * The geometry uses an 8-unit box: the fill sits at 2.6 units and is 4.9
 * units wide. The outline sits at 0.5 units, is 4.9 units wide, and has a
 * 0.75-unit stroke inside its edge.
 */
@Composable
fun FluxMark(size: androidx.compose.ui.unit.Dp, fg: Color = Palette.text, accent: Color = Palette.accent) {
    androidx.compose.foundation.Canvas(Modifier.size(size)) {
        val u = this.size.minDimension / 8f
        drawRect(accent, topLeft = Offset(2.6f * u, 2.6f * u), size = androidx.compose.ui.geometry.Size(4.9f * u, 4.9f * u))
        val stroke = 0.75f * u
        drawRect(
            fg,
            topLeft = Offset(0.5f * u + stroke / 2, 0.5f * u + stroke / 2),
            size = androidx.compose.ui.geometry.Size(4.9f * u - stroke, 4.9f * u - stroke),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke),
        )
    }
}
