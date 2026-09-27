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

/** One line of terminal text. */
data class TermLine(val spans: List<TermSpan>) {
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

/**
 * Makes terminal lines fit a phone screen. It removes the blanks at the end
 * of each line and the empty lines at the end. It also shortens lines of
 * box rules, because they fill the width of the terminal.
 */
fun tidyLines(lines: List<TermLine>): List<TermLine> {
    val out = lines.map { line ->
        val trimmed = trimEnd(line)
        val text = trimmed.text
        if (text.length > RULE_WIDTH && text.all { it in ruleChars }) take(trimmed, RULE_WIDTH) else trimmed
    }
    return out.dropLastWhile { it.spans.isEmpty() }
}

private fun trimEnd(line: TermLine): TermLine {
    val spans = line.spans.toMutableList()
    while (spans.isNotEmpty()) {
        val last = spans.last()
        val t = last.text.trimEnd()
        if (t.isNotEmpty()) {
            spans[spans.size - 1] = last.copy(text = t)
            break
        }
        spans.removeAt(spans.size - 1)
    }
    return TermLine(spans)
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
    return TermLine(out)
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
