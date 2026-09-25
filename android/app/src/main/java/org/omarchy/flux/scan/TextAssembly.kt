package org.omarchy.flux.scan

/** A rectangle in pixels. The origin is the top left corner. */
data class Box(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val height: Int get() = bottom - top
}

/** One line of recognized text. */
data class ScanLine(val text: String, val box: Box)

/** One block of recognized text, such as a paragraph or a label. */
data class ScanBlock(val lines: List<ScanLine>, val box: Box)

/**
 * Turns recognized blocks into plain text. The recognizer returns blocks in
 * no fixed order, so this puts them in reading order: rows from top to
 * bottom, and blocks in a row from left to right.
 */
object TextAssembly {
    /**
     * The part of the smaller height that 2 blocks must share vertically to
     * be in the same row.
     */
    private const val ROW_OVERLAP = 0.5

    /** Returns the text of the blocks. Blocks are separated by an empty line. */
    fun assemble(blocks: List<ScanBlock>): String =
        readingOrder(blocks)
            .map { block -> joinLines(block.lines.sortedWith(compareBy({ it.box.top }, { it.box.left })).map { it.text }) }
            .filter { it.isNotEmpty() }
            .joinToString("\n\n")

    /** Returns the blocks in reading order. */
    fun readingOrder(blocks: List<ScanBlock>): List<ScanBlock> {
        val rows = mutableListOf<MutableList<ScanBlock>>()
        for (b in blocks.sortedBy { it.box.top }) {
            val row = rows.lastOrNull()
            if (row != null && row.any { sameRow(it.box, b.box) }) row += b else rows += mutableListOf(b)
        }
        return rows.flatMap { row -> row.sortedBy { it.box.left } }
    }

    /**
     * Joins the lines of 1 block. Each line keeps its own row, so lists,
     * addresses, and code stay as they are. A word that the line end splits
     * with a hyphen becomes whole again.
     */
    fun joinLines(lines: List<String>): String {
        val out = StringBuilder()
        for (raw in lines) {
            val line = raw.trim()
            if (line.isEmpty()) continue
            if (out.isEmpty()) {
                out.append(line)
                continue
            }
            if (endsWithSplitWord(out) && line.first().isLowerCase()) {
                out.setLength(out.length - 1)
                out.append(line)
            } else {
                out.append('\n').append(line)
            }
        }
        return out.toString()
    }

    private fun endsWithSplitWord(text: CharSequence): Boolean =
        text.length >= 2 && text[text.length - 1] == '-' && text[text.length - 2].isLetter()

    private fun sameRow(a: Box, b: Box): Boolean {
        val overlap = minOf(a.bottom, b.bottom) - maxOf(a.top, b.top)
        val smaller = minOf(a.height, b.height)
        return smaller > 0 && overlap >= smaller * ROW_OVERLAP
    }
}
