package org.omarchy.flux.scan

import org.junit.Assert.assertEquals
import org.junit.Test

class TextAssemblyTest {
    private fun block(left: Int, top: Int, right: Int, bottom: Int, vararg lines: String): ScanBlock {
        val h = if (lines.isEmpty()) 0 else (bottom - top) / lines.size
        return ScanBlock(
            lines.mapIndexed { i, t -> ScanLine(t, Box(left, top + i * h, right, top + (i + 1) * h)) },
            Box(left, top, right, bottom),
        )
    }

    @Test
    fun stackedBlocksReadTopToBottom() {
        val title = block(10, 10, 300, 40, "Invoice 0925")
        val body = block(10, 80, 300, 140, "Total 12.40", "Due 30 Sep")
        assertEquals("Invoice 0925\n\nTotal 12.40\nDue 30 Sep", TextAssembly.assemble(listOf(body, title)))
    }

    @Test
    fun blocksInOneRowReadLeftToRight() {
        val right = block(200, 12, 300, 38, "B14")
        val left = block(10, 10, 120, 40, "Gate")
        val below = block(10, 60, 300, 90, "Boarding 15:40")
        assertEquals(
            listOf("Gate", "B14", "Boarding 15:40"),
            TextAssembly.readingOrder(listOf(below, right, left)).map { it.lines.first().text },
        )
    }

    @Test
    fun smallOverlapStartsANewRow() {
        val a = block(200, 0, 300, 40, "first")
        val b = block(10, 30, 120, 70, "second")
        assertEquals(listOf("first", "second"), TextAssembly.readingOrder(listOf(b, a)).map { it.lines.first().text })
    }

    @Test
    fun linesInABlockFollowTheirPosition() {
        val b = ScanBlock(
            listOf(ScanLine("second", Box(0, 30, 100, 50)), ScanLine("first", Box(0, 0, 100, 20))),
            Box(0, 0, 100, 50),
        )
        assertEquals("first\nsecond", TextAssembly.assemble(listOf(b)))
    }

    @Test
    fun splitWordsJoin() {
        assertEquals("the configuration file", TextAssembly.joinLines(listOf("the configu-", "ration file")))
    }

    @Test
    fun hyphenBeforeCapitalStays() {
        assertEquals("Omarchy-\nFlux", TextAssembly.joinLines(listOf("Omarchy-", "Flux")))
    }

    @Test
    fun dashAloneStays() {
        assertEquals("price -\nsee below", TextAssembly.joinLines(listOf("price -", "see below")))
    }

    @Test
    fun blankLinesAndBlocksDrop() {
        val empty = block(0, 0, 10, 10)
        val spaces = block(0, 20, 100, 40, "   ")
        val text = block(0, 50, 100, 70, "  ssh deploy@10.0.4.12  ")
        assertEquals("ssh deploy@10.0.4.12", TextAssembly.assemble(listOf(empty, spaces, text)))
    }

    @Test
    fun nothingGivesEmptyText() {
        assertEquals("", TextAssembly.assemble(emptyList()))
    }
}
