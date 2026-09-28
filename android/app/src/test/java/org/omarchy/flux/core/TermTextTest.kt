package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The fitting of full-screen agent output, for example opencode, to a phone screen. */
class TermTextTest {
    private val esc = "\u001b"

    private val white = 0xFFFFFF
    private val text = 0xC5C8C6
    private val gray = 0xA9A9A9
    private val accent = 0xF0C674
    private val panel = 0x2B2E31
    private val added = 0x3E4231

    /** One cell run with a 24-bit foreground and an optional background, as herdr sends it. */
    private fun cell(s: String, fg: Int, bg: Int? = null): String {
        val b = bg?.let { ";48;2;${it shr 16 and 0xFF};${it shr 8 and 0xFF};${it and 0xFF}" }.orEmpty()
        return "$esc[0m$esc[38;2;${fg shr 16 and 0xFF};${fg shr 8 and 0xFF};${fg and 0xFF}${b}m$s"
    }

    /** A row of an opencode panel: a margin, the bar, the text, the panel background, and a margin. */
    private fun panelRow(body: String, bar: Int = panel, width: Int = 80): String =
        cell("  ", white) + cell("┃", bar, panel) + cell("  $body", text, panel) +
            cell(" ".repeat(width - body.length), white, panel) + cell("  ", white) + "$esc[0m"

    private fun plainRow(body: String, indent: Int = 5, width: Int = 86): String =
        cell(" ".repeat(indent), white) + cell(body, text) + cell(" ".repeat(width - indent - body.length), white) + "$esc[0m"

    private fun blankRow() = cell(" ".repeat(86), white) + "$esc[0m"

    /** The shape of an opencode screen: a message, a tool panel, a gap, the prompt box, and the status line. */
    private val opencode = listOf(
        blankRow(),
        panelRow("", accent),
        panelRow("Add a test", accent),
        panelRow("", accent),
        blankRow(),
        plainRow("I added the test."),
        blankRow(),
        panelRow(""),
        panelRow("$ make test"),
        panelRow(""),
        panelRow("ok  4 tests"),
        panelRow(""),
        blankRow(),
        plainRow("▣  Build · Big Pickle · 12s"),
    ) + List(20) { blankRow() } + listOf(
        panelRow("", accent),
        panelRow("", accent),
        panelRow("", accent),
        panelRow("Build · Big Pickle", accent),
        cell("  ", white) + cell("╹", accent) + cell("▀".repeat(81), panel) + cell("  ", white) + "$esc[0m",
        cell("   ", white) + cell("~/code/app", gray) + cell(" ".repeat(40), white) + cell("ctrl+p ", text) + cell("commands", gray) + "$esc[0m",
        blankRow(),
    )

    @Test
    fun fitsAnOpencodeScreen() {
        val lines = termLines(opencode.joinToString("\r\n"))
        assertEquals(
            listOf(
                "┃",
                "┃  Add a test",
                "┃",
                "",
                "   I added the test.",
                "",
                "┃",
                "┃  $ make test",
                "┃",
                "┃  ok  4 tests",
                "┃",
                "",
                "   ▣  Build · Big Pickle · 12s",
                "",
                "┃",
                "┃  Build · Big Pickle",
                " ~/code/app" + " ".repeat(40) + "ctrl+p commands",
            ),
            lines.map { it.text },
        )
        assertEquals("a panel row keeps the panel background", TermColor.Rgb(panel), lines[1].fill)
        assertEquals("an empty panel row too", TermColor.Rgb(panel), lines[0].fill)
        assertNull("a row of the conversation has no fill", lines[4].fill)
        assertNull(lines[3].fill)
    }

    @Test
    fun fillsWithTheBackgroundAfterTheText() {
        // A diff row: the panel, then the added code, then blanks in the color of the added code.
        val row = cell("┃ ", panel, panel) + cell(" 5 + ", gray, added) + cell("def add(a, b):", text, added) +
            cell(" ".repeat(30), white, added) + cell("    ", white, panel) + cell("  ", white)
        val line = termLines(row).single()
        assertEquals("┃  5 + def add(a, b):", line.text)
        assertEquals(TermColor.Rgb(added), line.fill)
        assertNull("blanks with the default background give no fill", termLines("text   $esc[41m  ").single().fill)
    }

    @Test
    fun dropsAScrollBarButKeepsADrawing() {
        val row = cell("┃  1   def greet(name):", text, panel) + cell(" ".repeat(20), white, panel) + cell("█", gray, panel) + cell("   ", white, panel)
        val line = termLines(row).single()
        assertEquals("┃  1   def greet(name):", line.text)
        assertEquals(TermColor.Rgb(panel), line.fill)
        assertEquals("a lone block with no text before it stays", " ".repeat(28) + "▄", termLines(" ".repeat(30) + "▄\n  █▀▀█").first().text)
        assertEquals("a block that follows text directly stays", "bar ████", termLines("bar ████").single().text)
    }

    @Test
    fun dropsTheEdgesOfBoxes() {
        assertEquals(listOf("┃ a", "b"), termLines("┃ a\n╹" + "▀".repeat(40) + "\n" + "▄".repeat(20) + "\nb").map { it.text })
        assertEquals("a short run stays", listOf("▀▀▀"), termLines("▀▀▀").map { it.text })
        assertEquals("a logo row with gaps stays", listOf("▀▀▀▀ █▀▀▀ ▀▀▀▀"), termLines("▀▀▀▀ █▀▀▀ ▀▀▀▀").map { it.text })
    }

    @Test
    fun keepsOneOfEachRunOfEmptyRows() {
        assertEquals(listOf("a", "", "b"), termLines("\n\n\na\n\n\n\n\nb\n\n").map { it.text })
        assertEquals(listOf("┃", "┃ x", "┃"), termLines("┃\n┃\n┃\n┃ x\n┃\n┃").map { it.text })
        assertEquals("different empty rows stay", listOf("a", "", "┃", "", "b"), termLines("a\n\n┃\n\nb").map { it.text })
    }

    @Test
    fun removesTheSharedMargin() {
        assertEquals(listOf("a", "", "  b"), termLines("   a\n\n     b").map { it.text })
        assertEquals("a line at the first column keeps the margin", listOf("  a", "b"), termLines("  a\nb").map { it.text })
        // Blanks with a background are not margin.
        assertEquals("  a", termLines("$esc[44m  a$esc[0m\n   b").first().text)
    }

    @Test
    fun movesACenteredBlockThatFits() {
        val logo = listOf("█▀▀█ █▀▀█", "█  █ █▀▀▀", "▀▀▀▀ ▀▀▀▀")
        val screen = termLines((logo.map { " ".repeat(30) + it } + "" + ("x".repeat(70))).joinToString("\n"))
        val fitted = fitLines(screen, 30)
        // The logo is 9 wide in 70 columns, with 30 blanks before it. On 30 columns, it keeps 30 / 61 of the 21 free columns.
        assertEquals(logo.map { " ".repeat(10) + it }, fitted.take(3).map { it.text })
        assertEquals("a line that cannot fit stays", "x".repeat(70), fitted.last().text)
        assertEquals("lines that fit stay", screen, fitLines(screen, 80))
    }

    @Test
    fun keepsABlockThatCannotFit() {
        val screen = termLines("   " + "word ".repeat(12) + "\n   short\n\n" + "y".repeat(70))
        assertEquals(screen, fitLines(screen, 40))
    }

    @Test
    fun keepsTextNearTheLeft() {
        // An answer of opencode starts at column 3. A line that is a little too wide wraps, and it keeps its column.
        val screen = termLines("   " + "z".repeat(40) + "\n\n" + "y".repeat(70))
        assertEquals(screen, fitLines(screen, 40))
    }

    @Test
    fun findsTheHangingIndent() {
        assertEquals(3, hangingIndent("   Plain text of the answer"))
        assertEquals(3, hangingIndent("┃  $ make test"))
        assertEquals(5, hangingIndent("   - A bullet"))
        assertEquals(7, hangingIndent("┃  [✓] Build the APK"))
        assertEquals(2, hangingIndent("⏺ Claude Code text"))
        assertEquals(5, hangingIndent("  ⎿  Tool output"))
        assertEquals(4, hangingIndent("12. A numbered item"))
        assertEquals("a dash without a blank is text", 0, hangingIndent("->x"))
        assertEquals(0, hangingIndent(""))
    }

    @Test
    fun findsTheToneOfTheColors() {
        assertEquals("light text is for a dark background", TermTone.Dark, termTone(termLines(opencode.joinToString("\n"))))
        val darkText = cell("dark text on a light background", 0x202020) + cell(" more", 0x303030)
        assertEquals(TermTone.Light, termTone(termLines(darkText)))
        // Claude Code uses theme colors for most text, and its orange is neither light nor dark.
        val claude = "$esc[38;2;215;119;87m●$esc[0m I added the migration in the database folder."
        assertNull(termTone(termLines(claude)))
        assertNull("palette colors come from the theme", termTone(termLines("$esc[37mwhite from the theme$esc[0m")))
        // fluxd puts the plain history of an agent above its screen. The history has theme colors, so it does not count.
        val history = List(150) { "an older line of plain text" }
        assertEquals(TermTone.Dark, termTone(termLines((history + opencode).joinToString("\n"))))
        assertNull("light and dark text close in number", termTone(termLines(cell("light", white) + cell("dark", 0x101010))))
    }

    @Test
    fun findsTheShapesOfBlocks() {
        assertEquals(listOf(CellRect(0f, 0f, 1f, 1f)), blockShape('█')?.rects)
        assertEquals(listOf(CellRect(0f, 0f, 1f, 0.5f)), blockShape('▀')?.rects)
        assertEquals(listOf(CellRect(0f, 0.5f, 1f, 1f)), blockShape('▄')?.rects)
        assertEquals(listOf(CellRect(0f, 7f / 8, 1f, 1f)), blockShape('▁')?.rects)
        assertEquals(listOf(CellRect(0f, 0f, 0.5f, 1f)), blockShape('▌')?.rects)
        assertEquals(listOf(CellRect(0f, 0f, 1f / 8, 1f)), blockShape('▏')?.rects)
        assertEquals(listOf(CellRect(0.5f, 0f, 1f, 1f)), blockShape('▐')?.rects)
        assertEquals(0.5f, blockShape('▒')?.alpha)
        assertEquals(listOf(CellRect(0f, 0.5f, 0.5f, 1f)), blockShape('▖')?.rects)
        assertEquals(listOf(CellRect(0.5f, 0f, 1f, 0.5f), CellRect(0f, 0.5f, 0.5f, 1f), CellRect(0.5f, 0.5f, 1f, 1f)), blockShape('▟')?.rects)
        assertNull(blockShape('┃'))
        assertNull(blockShape('a'))
    }

    @Test
    fun invertsTheLightness() {
        assertEquals(0x000000, invertLightness(0xFFFFFF))
        assertEquals(0xFFFFFF, invertLightness(0x000000))
        assertEquals("a color at half lightness stays", 0xFF0000, invertLightness(0xFF0000))
        assertEquals(0x5C5C5C, invertLightness(0xA3A3A3))
        assertEquals("a light orange becomes a dark orange", 0x522100, invertLightness(0xFFCEAD))
    }
}
