package org.omarchy.flux.core

/**
 * Terminal text with ANSI SGR styles, for the output of a herdr agent. The
 * parser has no Android imports, so the JVM tests can load it. The UI turns
 * the lines into styled text.
 */

/** A color of terminal text. */
sealed interface TermColor {
    /** An entry of the 256-color palette. 0 to 15 are the theme colors. */
    data class Indexed(val index: Int) : TermColor

    /** A 24-bit color as 0xRRGGBB. */
    data class Rgb(val rgb: Int) : TermColor
}

/** The style of a run of terminal text. A null color is the default color. */
data class TermStyle(
    val fg: TermColor? = null,
    val bg: TermColor? = null,
    val bold: Boolean = false,
    val dim: Boolean = false,
    val italic: Boolean = false,
    val underline: Boolean = false,
    val inverse: Boolean = false,
    val strike: Boolean = false,
)

/** A run of text with one style. */
data class TermSpan(val text: String, val style: TermStyle = TermStyle())

/**
 * One line of terminal text. [fill] is the background of the blank cells
 * after the text, for example the background of a panel. A null fill is the
 * default background.
 */
data class TermLine(val spans: List<TermSpan>, val fill: TermColor? = null) {
    val text: String get() = spans.joinToString("") { it.text }
}

private const val ESC = '\u001b'
private const val BEL = '\u0007'
private const val TAB_WIDTH = 8

/**
 * Parses text with ANSI SGR sequences into lines of styled spans. It drops
 * other escape sequences, carriage returns, and other control characters.
 * It expands tabs to the next multiple of 8 columns.
 */
fun parseAnsi(text: String): List<TermLine> {
    val lines = ArrayList<TermLine>()
    var spans = ArrayList<TermSpan>()
    val run = StringBuilder()
    var style = TermStyle()
    var column = 0

    fun flush() {
        if (run.isEmpty()) return
        val last = spans.lastOrNull()
        if (last != null && last.style == style) {
            spans[spans.size - 1] = last.copy(text = last.text + run)
        } else {
            spans += TermSpan(run.toString(), style)
        }
        run.setLength(0)
    }

    var i = 0
    while (i < text.length) {
        val c = text[i]
        when {
            c == '\n' -> {
                flush()
                lines += TermLine(spans)
                spans = ArrayList()
                column = 0
                i++
            }
            c == '\t' -> {
                val n = TAB_WIDTH - column % TAB_WIDTH
                repeat(n) { run.append(' ') }
                column += n
                i++
            }
            c == ESC -> {
                flush()
                val next = text.getOrNull(i + 1)
                i = when {
                    next == '[' -> {
                        // CSI: parameters and intermediates, then 1 final byte from 0x40 to 0x7E.
                        var j = i + 2
                        while (j < text.length && text[j].code !in 0x40..0x7E) j++
                        if (j < text.length && text[j] == 'm') style = applySgr(style, text.substring(i + 2, j))
                        j + 1
                    }
                    next == ']' -> {
                        // OSC: ends with BEL or with ESC and a backslash.
                        var j = i + 2
                        while (j < text.length && text[j] != BEL && !(text[j] == ESC && text.getOrNull(j + 1) == '\\')) j++
                        if (j < text.length && text[j] == ESC) j + 2 else j + 1
                    }
                    // A character set selection, for example ESC ( B.
                    next != null && next in "()*+" -> i + 3
                    // A 2-byte sequence, for example ESC 7 to save the cursor.
                    next != null && next.code in 0x30..0x7E -> i + 2
                    else -> i + 1
                }
            }
            c == '\r' || c.code < 0x20 || c.code == 0x7F -> i++
            else -> {
                run.append(if (c == ' ') ' ' else c)
                column++
                i++
            }
        }
    }
    flush()
    if (spans.isNotEmpty()) lines += TermLine(spans)
    return lines
}

/** Applies the SGR parameters, for example "1;38;5;6", to [start]. */
internal fun applySgr(start: TermStyle, params: String): TermStyle {
    // Private and other non-SGR forms, for example ESC [ > 4 m, change nothing.
    if (params.any { it !in "0123456789;:" }) return start
    var s = start
    val parts = if (params.isEmpty()) listOf("0") else params.split(';')
    var i = 0
    while (i < parts.size) {
        val p = parts[i]
        if (':' in p) {
            // The colon form keeps the color in 1 parameter, for example 38:2::215:119:87.
            s = applyColonForm(s, p.split(':'))
            i++
            continue
        }
        when (val code = p.toIntOrNull() ?: 0) {
            0 -> s = TermStyle()
            1 -> s = s.copy(bold = true)
            2 -> s = s.copy(dim = true)
            3 -> s = s.copy(italic = true)
            4, 21 -> s = s.copy(underline = true)
            7 -> s = s.copy(inverse = true)
            9 -> s = s.copy(strike = true)
            22 -> s = s.copy(bold = false, dim = false)
            23 -> s = s.copy(italic = false)
            24 -> s = s.copy(underline = false)
            27 -> s = s.copy(inverse = false)
            29 -> s = s.copy(strike = false)
            in 30..37 -> s = s.copy(fg = TermColor.Indexed(code - 30))
            39 -> s = s.copy(fg = null)
            in 40..47 -> s = s.copy(bg = TermColor.Indexed(code - 40))
            49 -> s = s.copy(bg = null)
            in 90..97 -> s = s.copy(fg = TermColor.Indexed(code - 90 + 8))
            in 100..107 -> s = s.copy(bg = TermColor.Indexed(code - 100 + 8))
            38, 48 -> {
                val (color, used) = extendedColor(parts, i + 1)
                // An unknown color form has an unknown length, so the rest of the parameters go.
                if (used == 0) return s
                if (color != null) s = if (code == 38) s.copy(fg = color) else s.copy(bg = color)
                i += used
            }
        }
        i++
    }
    return s
}

/** Reads a 5;N or 2;R;G;B color that starts at [from]. It returns the color and the count of parameters that it used. */
private fun extendedColor(parts: List<String>, from: Int): Pair<TermColor?, Int> {
    return when (parts.getOrNull(from)) {
        "5" -> {
            val n = parts.getOrNull(from + 1)?.toIntOrNull()
            (if (n != null && n in 0..255) TermColor.Indexed(n) else null) to 2
        }
        "2" -> {
            val rgb = (1..3).map { parts.getOrNull(from + it)?.toIntOrNull() }
            (if (rgb.all { it != null && it in 0..255 }) rgbOf(rgb[0]!!, rgb[1]!!, rgb[2]!!) else null) to 4
        }
        else -> null to 0
    }
}

private fun applyColonForm(s: TermStyle, sub: List<String>): TermStyle {
    val code = sub[0].toIntOrNull() ?: return s
    if (code == 4) return s.copy(underline = sub.getOrNull(1)?.toIntOrNull() != 0)
    if (code != 38 && code != 48) return s
    val color = when (sub.getOrNull(1)) {
        "5" -> sub.getOrNull(2)?.toIntOrNull()?.takeIf { it in 0..255 }?.let { TermColor.Indexed(it) }
        "2" -> {
            // 38:2:R:G:B or 38:2:ID:R:G:B. The last 3 values are the color.
            val rgb = sub.drop(2).takeLast(3).map { it.toIntOrNull() }
            if (rgb.size == 3 && rgb.all { it != null && it in 0..255 }) rgbOf(rgb[0]!!, rgb[1]!!, rgb[2]!!) else null
        }
        else -> null
    } ?: return s
    return if (code == 38) s.copy(fg = color) else s.copy(bg = color)
}

private fun rgbOf(r: Int, g: Int, b: Int) = TermColor.Rgb((r shl 16) or (g shl 8) or b)

/**
 * Returns the 0xRRGGBB value of a palette entry from 16 to 255: the
 * 6 × 6 × 6 color cube, then the 24 grays. Entries 0 to 15 come from the
 * theme, so the result is null for them.
 */
fun paletteRgb(index: Int): Int? {
    if (index !in 16..255) return null
    if (index >= 232) {
        val v = 8 + 10 * (index - 232)
        return (v shl 16) or (v shl 8) or v
    }
    val n = index - 16
    val levels = intArrayOf(0, 95, 135, 175, 215, 255)
    return (levels[n / 36] shl 16) or (levels[n / 6 % 6] shl 8) or levels[n % 6]
}

/** The longest rule line that the output view shows. A phone screen is narrower than a terminal. */
private const val RULE_WIDTH = 32

private val ruleChars = setOf('─', '━', '═', '-', '_', '=')

/** True when the line has only rule characters, so it is a horizontal rule. */
fun isRule(line: String, min: Int = 8): Boolean {
    val t = line.trim()
    return t.length >= min && t.all { it in ruleChars }
}

/** The bars at the left side of a panel, for example of a message in opencode. */
private const val BARS = "┃│║▌▎▏"

/** A lone block after this many blanks at the end of a line is the thumb of a scroll bar. */
private const val SCROLL_BAR_GAP = 4

/** The top or bottom edge of a box that half blocks draw, for example the prompt box of opencode. */
private val edgeLine = Regex("^[╵╷╹╻]?(▀{8,}|▄{8,})[╵╷╹╻]?$")

/**
 * Makes terminal lines fit a phone screen. It removes the blanks at the end
 * of each line, scroll bars, and the edges of boxes. It shortens lines of
 * box rules, because they fill the width of the terminal. It also removes
 * the blank columns that all lines share at the start, and the extra empty
 * rows, because full-screen agents such as opencode fill the terminal with them.
 */
fun tidyLines(lines: List<TermLine>): List<TermLine> {
    val out = ArrayList<TermLine>()
    for (line in dropSidebar(lines)) {
        val trimmed = trimEnd(dropScrollBar(line))
        val text = trimmed.text
        when {
            edgeLine.matches(text.trim()) -> {}
            text.length > RULE_WIDTH && text.all { it in ruleChars } -> out += take(trimmed, RULE_WIDTH)
            else -> out += trimmed
        }
    }
    return dropEmptyRows(dedent(out))
}

/** A sidebar starts at this column or later, see [dropSidebar]. */
private const val SIDEBAR_MIN_COL = 40

/** The widest sidebar, in columns. */
private const val SIDEBAR_MAX_WIDTH = 60

/** The fewest lines that end in a sidebar. */
private const val SIDEBAR_MIN_ROWS = 4

/**
 * Removes the sidebar at the right of a full-screen agent, for example the
 * sidebar that opencode shows in a wide terminal. Each line holds a row of
 * the conversation and a row of the sidebar, so on a narrow screen the two
 * mix. A sidebar is a column of cells with one background, from the same
 * column to the end of the lines. At least [SIDEBAR_MIN_ROWS] lines must
 * end in it, and no line can have other cells there.
 */
private fun dropSidebar(lines: List<TermLine>): List<TermLine> {
    val ends = HashMap<Pair<Int, TermColor>, Int>()
    for (line in lines) endRun(line)?.let { ends.merge(it, 1, Int::plus) }
    val (start, count) = ends.maxByOrNull { it.value } ?: return lines
    val (col, bg) = start
    if (count < SIDEBAR_MIN_ROWS || col < SIDEBAR_MIN_COL) return lines
    if (lines.maxOf { it.text.length } - col > SIDEBAR_MAX_WIDTH) return lines
    for (line in lines) {
        var at = 0
        for (s in line.spans) {
            if (at + s.text.length > col && (s.style.inverse || s.style.bg != bg)) return lines
            at += s.text.length
        }
    }
    return lines.map { take(it, col) }
}

/**
 * Returns the start column and the background of the run of cells with one
 * background at the end of a line, or null when the last cell has no background.
 */
private fun endRun(line: TermLine): Pair<Int, TermColor>? {
    val last = line.spans.lastOrNull() ?: return null
    val bg = last.style.bg?.takeIf { !last.style.inverse } ?: return null
    var start = line.text.length
    for (s in line.spans.asReversed()) {
        if (s.style.inverse || s.style.bg != bg) break
        start -= s.text.length
    }
    return start to bg
}

/** True when a blank cell with this style shows no color. */
private fun plain(s: TermStyle) = s.bg == null && !s.inverse

/**
 * Removes the blanks at the end of a line. The background of the first blank
 * after the text becomes the fill of the line. A line with no text gets the
 * first background of its blanks.
 */
private fun trimEnd(line: TermLine): TermLine {
    val spans = line.spans.toMutableList()
    var fill: TermColor? = null
    var blankFill: TermColor? = null
    while (spans.isNotEmpty()) {
        val last = spans.last()
        val t = last.text.trimEnd()
        if (t.length < last.text.length) {
            fill = if (plain(last.style)) null else last.style.bg
            if (fill != null) blankFill = fill
        }
        if (t.isNotEmpty()) {
            spans[spans.size - 1] = last.copy(text = t)
            return TermLine(spans, fill)
        }
        spans.removeAt(spans.size - 1)
    }
    return TermLine(spans, blankFill)
}

/**
 * Removes the thumb of a scroll bar: a lone block at the end of a line, after
 * text and a gap of blanks. The cell becomes a blank with the same style, so
 * the line keeps its fill. A block with no text before it stays, because it
 * is part of a drawing, for example the logo of opencode.
 */
private fun dropScrollBar(line: TermLine): TermLine {
    val text = line.text
    val end = text.indexOfLast { it != ' ' }
    if (end <= SCROLL_BAR_GAP || text[end] !in '\u2580'..'\u259F') return line
    if ((end - SCROLL_BAR_GAP until end).any { text[it] != ' ' } || text.substring(0, end).isBlank()) return line
    var offset = 0
    return TermLine(
        line.spans.map { s ->
            val i = end - offset
            offset += s.text.length
            if (i in s.text.indices) s.copy(text = s.text.replaceRange(i, i + 1, " ")) else s
        },
        line.fill,
    )
}

/** The number of blank cells with no color at the start of a line. */
private fun leadingBlanks(line: TermLine): Int {
    var n = 0
    for (s in line.spans) {
        if (!plain(s.style)) return n
        for (c in s.text) {
            if (c != ' ') return n
            n++
        }
    }
    return n
}

/** Removes the blank columns that all lines with text share at the start. */
private fun dedent(lines: List<TermLine>): List<TermLine> {
    val n = lines.filter { it.spans.isNotEmpty() }.minOfOrNull(::leadingBlanks) ?: 0
    return if (n == 0) lines else lines.map { dropColumns(it, n) }
}

/** Removes the first [n] cells of a line. */
private fun dropColumns(line: TermLine, n: Int): TermLine {
    val out = ArrayList<TermSpan>()
    var left = n
    for (s in line.spans) {
        if (left >= s.text.length) {
            left -= s.text.length
            continue
        }
        out += s.copy(text = s.text.substring(left))
        left = 0
    }
    return TermLine(out, line.fill)
}

/** True when a row shows no text. The bar of an empty panel row is not text. */
private fun isEmptyRow(line: TermLine): Boolean {
    val t = line.text.trim()
    return t.isEmpty() || t.length == 1 && t[0] in BARS
}

/**
 * Removes the blank rows at the start and at the end, and keeps 1 row of
 * each run of equal empty rows.
 */
private fun dropEmptyRows(lines: List<TermLine>): List<TermLine> {
    val out = ArrayList<TermLine>()
    for (line in lines) {
        val blank = line.spans.isEmpty() && line.fill == null
        if (blank && out.isEmpty() || isEmptyRow(line) && out.lastOrNull() == line) continue
        out += line
    }
    return out.dropLastWhile { it.spans.isEmpty() && it.fill == null }
}

private fun take(line: TermLine, n: Int): TermLine {
    val out = ArrayList<TermSpan>()
    var left = n
    for (s in line.spans) {
        if (left <= 0) break
        val t = s.text.take(left)
        out += s.copy(text = t)
        left -= t.length
    }
    return TermLine(out, line.fill)
}

/** A block must start at this column or later to move, see [fitLines]. Text in a column near the left keeps its place. */
private const val FIT_MIN_LEAD = 8

/**
 * Moves the centered blocks of lines that are wider than [cols] columns to
 * the left when they fit without some of the blanks before them. An example
 * is the logo of opencode. A block is a run of lines between blank rows. It
 * is centered when it starts at column [FIT_MIN_LEAD] or later, and when it
 * has at least half as many blank columns at the left as at the right. The
 * block keeps its place relative to the width of the output, so it stays
 * centered.
 */
fun fitLines(lines: List<TermLine>, cols: Int): List<TermLine> {
    val width = lines.maxOfOrNull { it.text.length } ?: 0
    if (width <= cols) return lines
    val out = lines.toMutableList()
    var start = 0
    while (start < lines.size) {
        var end = start
        while (end < lines.size && lines[end].spans.isNotEmpty()) end++
        if (end > start) {
            val block = lines.subList(start, end)
            val lead = block.minOf(::leadingBlanks)
            val right = block.maxOf { it.text.length }
            val size = right - lead
            if (right > cols && size <= cols && lead >= FIT_MIN_LEAD && 2 * lead >= width - right) {
                // The share of the free columns at the left stays the same.
                val shift = lead - lead * (cols - size) / (width - size)
                for (i in start until end) out[i] = dropColumns(lines[i], shift)
            }
        }
        start = end + 1
    }
    return out
}

private val listMarker = Regex("""^(?:[-*+•·◦▪‣⏺●⎿→←✓✔✗✘△▣■□]|\[[ x✓•]]|\d{1,3}[.)])\s+""")

/**
 * Returns the column where the wrapped rows of a line start, so that they
 * line up with its text. The column is after the blanks at the start, the
 * bar of a panel, and a list marker.
 */
fun hangingIndent(text: String): Int {
    var i = text.indexOfFirst { it != ' ' }
    if (i < 0) return 0
    if (text[i] in BARS) {
        i++
        while (i < text.length && text[i] == ' ') i++
    }
    listMarker.find(text.substring(i))?.let { i += it.value.length }
    return i
}

/** A rectangle in a cell, in fractions of the cell width and height from the top left corner. */
data class CellRect(val left: Float, val top: Float, val right: Float, val bottom: Float)

/** How a block element fills its cell: rectangles in the text color, with [alpha] for a shade. */
data class BlockShape(val rects: List<CellRect>, val alpha: Float = 1f)

private val fullCell = CellRect(0f, 0f, 1f, 1f)

/** The quadrants of the elements from ▖ to ▟. Bit 1 is the top left, 2 the top right, 4 the bottom left, and 8 the bottom right. */
private val quadrants = intArrayOf(4, 8, 1, 13, 9, 7, 11, 2, 6, 14)

/**
 * Returns the shape of a block element from ▀ to ▟, or null for another
 * character. A terminal fills the cell with these elements, but a font draws
 * them shorter than a row of the output view, so the view draws the shapes.
 */
fun blockShape(c: Char): BlockShape? = when (c) {
    '▀' -> BlockShape(listOf(CellRect(0f, 0f, 1f, 0.5f)))
    in '▁'..'█' -> BlockShape(listOf(CellRect(0f, 1f - (c - '▀') / 8f, 1f, 1f)))
    in '▉'..'▏' -> BlockShape(listOf(CellRect(0f, 0f, ('▐' - c) / 8f, 1f)))
    '▐' -> BlockShape(listOf(CellRect(0.5f, 0f, 1f, 1f)))
    '░' -> BlockShape(listOf(fullCell), 0.25f)
    '▒' -> BlockShape(listOf(fullCell), 0.5f)
    '▓' -> BlockShape(listOf(fullCell), 0.75f)
    '▔' -> BlockShape(listOf(CellRect(0f, 0f, 1f, 1f / 8)))
    '▕' -> BlockShape(listOf(CellRect(7f / 8, 0f, 1f, 1f)))
    in '▖'..'▟' -> {
        val bits = quadrants[c - '▖']
        BlockShape(
            listOfNotNull(
                CellRect(0f, 0f, 0.5f, 0.5f).takeIf { bits and 1 != 0 },
                CellRect(0.5f, 0f, 1f, 0.5f).takeIf { bits and 2 != 0 },
                CellRect(0f, 0.5f, 0.5f, 1f).takeIf { bits and 4 != 0 },
                CellRect(0.5f, 0.5f, 1f, 1f).takeIf { bits and 8 != 0 },
            ),
        )
    }
    else -> null
}

/** The tone of the background that the colors of an output suit. */
enum class TermTone { Dark, Light }

/** Text with a luminance of at least this value is light. */
private const val LIGHT_TEXT = 0.3

/** Text with a luminance of at most this value is dark. */
private const val DARK_TEXT = 0.1

/**
 * Finds the tone of the background that the fixed text colors suit.
 * Full-screen agents such as opencode give all text a color from the
 * desktop theme, so light text means a dark background. Text in a theme
 * color does not count, because the view shows it in the colors of the app.
 * An example is the plain history that fluxd puts above the screen. The
 * result is null when there are no fixed colors, or when light and dark
 * text colors are close in number.
 */
fun termTone(lines: List<TermLine>): TermTone? {
    var light = 0
    var dark = 0
    for (line in lines) for (s in line.spans) {
        val rgb = s.style.fg?.let(::fixedRgb) ?: continue
        if (s.style.inverse) continue
        val n = s.text.count { it != ' ' }
        val l = luminance(rgb)
        if (l >= LIGHT_TEXT) light += n else if (l <= DARK_TEXT) dark += n
    }
    return when {
        light > 2 * dark -> TermTone.Dark
        dark > 2 * light -> TermTone.Light
        else -> null
    }
}

/** Returns the 0xRRGGBB value of a color that does not come from the theme, or null for a theme color. */
fun fixedRgb(c: TermColor): Int? = when (c) {
    is TermColor.Rgb -> c.rgb
    is TermColor.Indexed -> paletteRgb(c.index)
}

/** The relative luminance of a 0xRRGGBB color, from 0 for black to 1 for white. */
private fun luminance(rgb: Int): Double {
    fun channel(v: Int): Double {
        val c = v / 255.0
        return if (c <= 0.04045) c / 12.92 else Math.pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(rgb shr 16 and 0xFF) + 0.7152 * channel(rgb shr 8 and 0xFF) + 0.0722 * channel(rgb and 0xFF)
}

/**
 * Inverts the lightness of a 0xRRGGBB color and keeps its hue and
 * saturation. White becomes black, and a light orange becomes a dark orange.
 */
fun invertLightness(rgb: Int): Int {
    val r = (rgb shr 16 and 0xFF) / 255.0
    val g = (rgb shr 8 and 0xFF) / 255.0
    val b = (rgb and 0xFF) / 255.0
    val max = maxOf(r, g, b)
    val min = minOf(r, g, b)
    // In HSL, 1 - L with the same hue and saturation moves each channel to 1 - max - min + channel.
    val shift = 1 - max - min
    fun byte(v: Double) = Math.round((v + shift).coerceIn(0.0, 1.0) * 255).toInt()
    return (byte(r) shl 16) or (byte(g) shl 8) or byte(b)
}

/** Parses and tidies the output text of an agent. */
fun termLines(text: String): List<TermLine> = tidyLines(parseAnsi(text))

/** A numbered choice of a question or an approval dialog. [key] is the digit that selects it. */
data class AgentChoice(val key: String, val label: String, val selected: Boolean = false)

private val choiceLine = Regex("""^\s*([❯›>]\s*)?(\d{1,2})[.)]\s+(.+)$""")

/** How far from the end of the output the dialog can start, in lines. */
private const val CHOICE_SCAN_LINES = 40

/** The last choice must be this close to the end of the output, in lines. */
private const val CHOICE_TAIL_LINES = 15

/**
 * Finds the numbered choices of the dialog at the end of the output, for
 * example the approval dialog of Claude Code. It takes the last run of
 * numbered lines that starts at 1 and counts up by 1. Other lines can come
 * between the choices, for example descriptions or a rule. It returns an
 * empty list when it finds fewer than 2 choices, or when the choices are not
 * near the end.
 */
fun findChoices(lines: List<String>): List<AgentChoice> {
    val from = maxOf(0, lines.size - CHOICE_SCAN_LINES)
    data class Hit(val index: Int, val number: Int, val choice: AgentChoice)
    val hits = ArrayList<Hit>()
    for (i in from until lines.size) {
        val m = choiceLine.matchEntire(lines[i]) ?: continue
        val number = m.groupValues[2].toInt()
        val label = m.groupValues[3].trim()
        hits += Hit(i, number, AgentChoice(number.toString(), label, m.groupValues[1].isNotEmpty()))
    }
    val start = hits.indexOfLast { it.number == 1 }
    if (start < 0) return emptyList()
    val run = ArrayList<Hit>()
    for (h in hits.subList(start, hits.size)) {
        if (h.number != run.size + 1) break
        run += h
    }
    if (run.size < 2 || run.last().index < lines.size - CHOICE_TAIL_LINES) return emptyList()
    // A single key selects a choice, so only 1 to 9 work.
    return run.map { it.choice }.filter { it.key.length == 1 }
}
