package org.omarchy.flux.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import org.omarchy.flux.core.TermColor
import org.omarchy.flux.core.TermLine
import org.omarchy.flux.core.TermStyle
import org.omarchy.flux.core.paletteRgb

/** The background of the agent output, a little darker than a tile. */
val TermBg = Tn.offTile

/**
 * The 16 theme colors of the terminal in Tokyo Night, so the agent output
 * matches the app. The bright colors use the same hues.
 */
private val themePalette = listOf(
    Tn.bg, Tn.red, Tn.green, Tn.yellow, Tn.blue, Tn.magenta, Tn.cyan, Tn.sub,
    Tn.dim, Tn.red, Tn.green, Tn.yellow, Tn.blue, Tn.magenta, Tn.cyan, Tn.text,
)

/** The alpha of dim text. */
private const val DIM_ALPHA = 0.6f

fun termColor(c: TermColor): Color = when (c) {
    is TermColor.Indexed -> themePalette.getOrNull(c.index) ?: rgbColor(paletteRgb(c.index) ?: 0xC0CAF5)
    is TermColor.Rgb -> rgbColor(c.rgb)
}

private fun rgbColor(rgb: Int) = Color(0xFF000000.toInt() or rgb)

/** Returns the Compose style of a terminal style, or null for the default style. */
private fun spanStyle(s: TermStyle, background: Color): SpanStyle? {
    if (s == TermStyle()) return null
    var fg = s.fg?.let(::termColor) ?: Tn.text
    var bg = s.bg?.let(::termColor)
    if (s.inverse) {
        val f = fg
        fg = bg ?: background
        bg = f
    }
    if (s.dim) fg = fg.copy(alpha = fg.alpha * DIM_ALPHA)
    val decorations = listOfNotNull(
        TextDecoration.Underline.takeIf { s.underline },
        TextDecoration.LineThrough.takeIf { s.strike },
    )
    return SpanStyle(
        color = fg,
        background = bg ?: Color.Unspecified,
        fontWeight = if (s.bold) FontWeight.Bold else null,
        fontStyle = if (s.italic) FontStyle.Italic else null,
        textDecoration = if (decorations.isEmpty()) null else TextDecoration.combine(decorations),
    )
}

/** Turns terminal lines into styled text. [background] is the color behind the text, for inverse text. */
fun termAnnotated(lines: List<TermLine>, background: Color = TermBg): AnnotatedString = buildAnnotatedString {
    lines.forEachIndexed { i, line ->
        if (i > 0) append('\n')
        for (span in line.spans) {
            val style = spanStyle(span.style, background)
            if (style == null) append(span.text) else withStyle(style) { append(span.text) }
        }
    }
}
