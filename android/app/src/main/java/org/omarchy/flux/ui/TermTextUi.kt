package org.omarchy.flux.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextIndent
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import org.omarchy.flux.core.BlockShape
import org.omarchy.flux.core.CellRect
import org.omarchy.flux.core.TermColor
import org.omarchy.flux.core.TermLine
import org.omarchy.flux.core.TermStyle
import org.omarchy.flux.core.TermTone
import org.omarchy.flux.core.blockShape
import org.omarchy.flux.core.fitLines
import org.omarchy.flux.core.fixedRgb
import org.omarchy.flux.core.hangingIndent
import org.omarchy.flux.core.invertLightness
import org.omarchy.flux.core.termTone
import kotlin.math.roundToInt

/** The background of the agent output, a little darker than a tile. */
val TermBg: Color
    @Composable @ReadOnlyComposable get() = Tn.offTile

/**
 * The 16 theme colors of the terminal in the Tiled colors, so the agent
 * output matches the app. The bright colors use the same hues. ANSI blue
 * is the blue of the theme and not the accent, as in the terminal on the
 * computer.
 */
private fun TiledColors.termPalette() = listOf(
    bg, red, green, yellow, termBlue, magenta, cyan, sub,
    dim, red, green, yellow, termBlue, magenta, cyan, text,
)

/** The alpha of dim text. */
private const val DIM_ALPHA = 0.6f

/**
 * The Compose color of a terminal color. With [invert], the colors that do
 * not come from the theme get the opposite lightness, see [invertLightness].
 */
fun termColor(c: TermColor, colors: TiledColors, invert: Boolean = false): Color {
    if (c is TermColor.Indexed) colors.termPalette().getOrNull(c.index)?.let { return it }
    val rgb = fixedRgb(c) ?: 0xC0CAF5
    return rgbColor(if (invert) invertLightness(rgb) else rgb)
}

private fun rgbColor(rgb: Int) = Color(0xFF000000.toInt() or rgb)

/** The brightest channel of a background that counts as black. */
private const val BLACK_MAX = 0x10

/**
 * The Compose color of a background, or null for the background of the
 * view. With [invert], a black background is the background of the view and
 * not white, because the agent drew it for a dark terminal. An example is
 * the logo of Claude Code.
 */
private fun termBg(c: TermColor, colors: TiledColors, invert: Boolean): Color? {
    val rgb = fixedRgb(c)
    if (invert && rgb != null && (rgb shr 16 and 0xFF) <= BLACK_MAX && (rgb shr 8 and 0xFF) <= BLACK_MAX && (rgb and 0xFF) <= BLACK_MAX) return null
    return termColor(c, colors, invert)
}

/** Returns the Compose style of a terminal style, or null for the default style. */
private fun spanStyle(s: TermStyle, colors: TiledColors, background: Color, invert: Boolean): SpanStyle? {
    if (s == TermStyle()) return null
    var fg = s.fg?.let { termColor(it, colors, invert) } ?: colors.text
    var bg = s.bg?.let { termBg(it, colors, invert) }
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

/** The width of a panel bar, in cells: the heavy bar of opencode, then a light bar. */
private const val HEAVY_BAR = 0.25f
private const val LIGHT_BAR = 0.12f

/** A vertical bar at the start of a row, which the view draws over the full height of the row. */
private class RowBar(val col: Int, val color: Color, val width: Float)

/** A block element at [offset] of the text, which the view draws in [color]. */
private class RowBlock(val offset: Int, val shape: BlockShape, val color: Color)

/**
 * How 1 output line looks. The [fill] starts at column [fillCol]. When it
 * starts at column 0, the left padding and the first [edgeCols] columns get
 * [edge], the background of the first cell. The wrapped rows of the line
 * then keep the background of a panel under its bar.
 */
private class TermRow(
    val text: AnnotatedString,
    val fill: Color?,
    val fillCol: Int,
    val edge: Color?,
    val edgeCols: Int,
    val bar: RowBar?,
    val blocks: List<RowBlock>,
    val hang: Int,
)

/** The background of a cell with this style, or null for the default background. */
private fun cellBg(s: TermStyle, colors: TiledColors, invert: Boolean): Color? =
    if (s.inverse) null else s.bg?.let { termBg(it, colors, invert) }

/**
 * Returns the shape of a rule character: 1 light, 1 heavy, or 2 light
 * lines across the middle of the cell. The mono font of Android has no
 * glyphs for these characters, and the glyphs of a fallback font are wider
 * than a cell, so a rule that fills the screen would wrap. The view draws
 * the lines instead.
 */
private fun ruleShape(c: Char): BlockShape? = when (c) {
    '─' -> BlockShape(listOf(CellRect(0f, 15f / 32, 1f, 17f / 32)))
    '━' -> BlockShape(listOf(CellRect(0f, 14f / 32, 1f, 18f / 32)))
    '═' -> BlockShape(listOf(CellRect(0f, 12f / 32, 1f, 14f / 32), CellRect(0f, 18f / 32, 1f, 20f / 32)))
    else -> null
}

/**
 * Turns 1 terminal line into a row in [colors]. [invert] is for [termColor].
 * The glyphs of a bar at the start of the row and of block elements get no
 * color, because the font draws them shorter than the row. The bar and the
 * rule characters become blanks, because a fallback font draws them wider
 * than a cell. The view draws all of them instead, as a terminal does.
 */
private fun termRow(line: TermLine, colors: TiledColors, invert: Boolean): TermRow {
    val fill = line.fill?.let { termBg(it, colors, invert) }
    val background = fill ?: colors.offTile
    val plain = line.text
    // The fill starts at the first cell with a background, as in the terminal.
    var fillCol = 0
    for (span in line.spans) {
        if (cellBg(span.style, colors, invert) != null) break
        fillCol += span.text.length
    }
    val edge = line.spans.firstOrNull()?.let { cellBg(it.style, colors, invert) } ?: fill.takeIf { line.spans.isEmpty() }
    var edgeCols = 0
    for (span in line.spans) {
        if (edge == null || cellBg(span.style, colors, invert) != edge) break
        edgeCols += span.text.length
    }
    val col = plain.indexOfFirst { it != ' ' }
    val barWidth = when (plain.getOrNull(col)) {
        '┃' -> HEAVY_BAR
        '│' -> LIGHT_BAR
        else -> 0f
    }
    var bar: RowBar? = null
    val blocks = ArrayList<RowBlock>()
    val text = buildAnnotatedString {
        var at = 0
        for (span in line.spans) {
            val style = spanStyle(span.style, colors, background, invert)
            val color = style?.color ?: colors.text
            if (barWidth > 0f && col in at until at + span.text.length) bar = RowBar(col, color, barWidth)
            var drawn = false
            span.text.forEachIndexed { i, c ->
                blockShape(c)?.let { blocks += RowBlock(at + i, it, color) }
                ruleShape(c)?.let {
                    blocks += RowBlock(at + i, it, color)
                    drawn = true
                }
            }
            val barCol = if (barWidth > 0f) col else -1
            val shown = if (drawn || barCol in at until at + span.text.length) {
                String(CharArray(span.text.length) { i -> if (at + i == barCol || ruleShape(span.text[i]) != null) ' ' else span.text[i] })
            } else {
                span.text
            }
            if (style == null) append(shown) else withStyle(style) { append(shown) }
            at += span.text.length
        }
        if (bar != null) addStyle(SpanStyle(color = Color.Transparent), col, col + 1)
        for (b in blocks) addStyle(SpanStyle(color = Color.Transparent), b.offset, b.offset + 1)
    }
    return TermRow(text, fill, if (fill == null) 0 else fillCol.coerceAtMost(plain.length), edge, edgeCols, bar, blocks, hangingIndent(plain))
}

/** The side padding of each output line. The fill of a line goes under it. */
val TermPad = 12.dp

/** The fewest columns that the output view assumes, for a very narrow screen. */
private const val MIN_COLS = 20

/** The text that measures the width of 1 cell. */
private const val CELL_SAMPLE = "0000000000"

/**
 * Terminal lines in the colors of the app, in a view that is [width] wide.
 * A long line wraps, and its wrapped rows line up with its text, see
 * [hangingIndent]. A line with a fill shows the fill up to the right edge,
 * so the panels of an agent look like panels. When the text colors suit the
 * other tone than the app, the view inverts their lightness, see [termTone].
 */
@Composable
fun TermLines(lines: List<TermLine>, width: Dp) {
    val colors = Tn
    val density = LocalDensity.current
    val style = TextStyle(
        color = colors.text,
        fontFamily = Mono,
        fontSize = 11.5.sp,
        lineHeight = 16.sp,
        lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None),
    )
    val measurer = rememberTextMeasurer()
    val cell = remember(measurer, density) {
        measurer.measure(CELL_SAMPLE, style, softWrap = false).size.width / CELL_SAMPLE.length.toFloat()
    }
    val cols = with(density) { ((width - TermPad * 2).toPx() / cell).toInt() }.coerceAtLeast(MIN_COLS)
    val cellEm = cell / with(density) { style.fontSize.toPx() }
    val rowHeight = with(density) { style.lineHeight.toDp() }
    val shown = remember(lines, cols) { fitLines(lines, cols) }
    val invert = remember(lines, colors) { termTone(lines)?.let { (it == TermTone.Dark) != colors.dark } ?: false }
    val pad = with(density) { TermPad.toPx() }
    Column {
        // A row keeps its key when the output moves, so that only new lines build their rows and their layout again.
        for (line in shown) key(line) {
            val row = remember(line, colors, invert) { termRow(line, colors, invert) }
            val hang = row.hang.takeIf { it <= cols / 2 } ?: 0
            // The layout gives the place of each block element. Only the drawing reads it.
            val layout = remember(row) { mutableStateOf<TextLayoutResult?>(null) }
            BasicText(
                row.text,
                Modifier
                    .fillMaxWidth()
                    .drawWithContent {
                        row.fill?.let { fill ->
                            val x = minOf(size.width, pad + (if (row.fillCol == 0) row.edgeCols else row.fillCol) * cell)
                            if (row.fillCol == 0) drawRect(row.edge ?: fill, size = Size(x, size.height))
                            drawRect(fill, Offset(x, 0f), Size(size.width - x, size.height))
                        }
                        drawContent()
                        row.bar?.let { bar ->
                            val w = maxOf(1f, cell * bar.width)
                            drawRect(bar.color, Offset(pad + bar.col * cell + (cell - w) / 2, 0f), Size(w, size.height))
                        }
                        // A rule in the blanks after the last word can reach past the edge.
                        layout.value?.let { l -> clipRect { for (b in row.blocks) drawBlock(b, l.getBoundingBox(b.offset), pad) } }
                    }
                    .heightIn(min = rowHeight)
                    .padding(horizontal = TermPad),
                style = if (hang == 0) style else style.copy(textIndent = TextIndent(restLine = (hang * cellEm).em)),
                onTextLayout = { if (row.blocks.isNotEmpty()) layout.value = it },
            )
        }
    }
}

/**
 * Draws the shape of a block element in the cell [box] of the text, which
 * starts [pad] from the left. The edges snap to whole pixels, so the blocks
 * of a drawing join with no seams.
 */
private fun DrawScope.drawBlock(b: RowBlock, box: Rect, pad: Float) {
    val color = b.color.copy(alpha = b.color.alpha * b.shape.alpha)
    for (r in b.shape.rects) {
        val left = (pad + box.left + r.left * box.width).roundToInt()
        val right = (pad + box.left + r.right * box.width).roundToInt()
        val top = (box.top + r.top * box.height).roundToInt()
        val bottom = (box.top + r.bottom * box.height).roundToInt()
        drawRect(color, Offset(left.toFloat(), top.toFloat()), Size((right - left).toFloat(), (bottom - top).toFloat()))
    }
}
