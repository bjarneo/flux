package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.Packet

class HerdrReplyTest {
    private fun body(line: String) = Packet.parse("""{"id":1,"type":"flux.herdr","body":$line}""")!!.body

    private val esc = "\u001b"

    @Test
    fun parsesBasicColors() {
        val lines = parseAnsi("$esc[1;31mred bold$esc[0m plain $esc[42m bg $esc[0m")
        assertEquals(1, lines.size)
        val spans = lines[0].spans
        assertEquals(TermSpan("red bold", TermStyle(fg = TermColor.Indexed(1), bold = true)), spans[0])
        assertEquals(TermSpan(" plain ", TermStyle()), spans[1])
        assertEquals(TermSpan(" bg ", TermStyle(bg = TermColor.Indexed(2))), spans[2])
    }

    @Test
    fun parsesHerdrColorForms() {
        // herdr sends the basic colors as palette entries.
        val lines = parseAnsi("$esc[0m$esc[1m$esc[38;5;6m/tmp$esc[0m ${esc}[38;2;215;119;87mtrue$esc[0m $esc[48;5;2mbg$esc[39;49m")
        val spans = lines.single().spans
        assertEquals(TermSpan("/tmp", TermStyle(fg = TermColor.Indexed(6), bold = true)), spans[0])
        assertEquals(TermSpan("true", TermStyle(fg = TermColor.Rgb(0xD77757))), spans[2])
        assertEquals(TermSpan("bg", TermStyle(bg = TermColor.Indexed(2))), spans[4])
    }

    @Test
    fun parsesBrightAndColonForms() {
        val s = applySgr(TermStyle(), "93;104")
        assertEquals(TermColor.Indexed(11), s.fg)
        assertEquals(TermColor.Indexed(12), s.bg)
        assertEquals(TermColor.Rgb(0x0A141E), applySgr(TermStyle(), "38:2::10:20:30").fg)
        assertEquals(TermColor.Indexed(200), applySgr(TermStyle(), "48:5:200").bg)
        assertTrue(applySgr(TermStyle(), "4:3").underline)
        assertFalse(applySgr(TermStyle(underline = true), "4:0").underline)
    }

    @Test
    fun resetsStyles() {
        var s = applySgr(TermStyle(), "1;2;3;4;7;9;31;42")
        assertEquals(TermStyle(TermColor.Indexed(1), TermColor.Indexed(2), bold = true, dim = true, italic = true, underline = true, inverse = true, strike = true), s)
        s = applySgr(s, "22;23;24;27;29;39;49")
        assertEquals(TermStyle(), s)
        assertEquals("an empty parameter list resets", TermStyle(), applySgr(TermStyle(bold = true), ""))
        assertEquals(TermStyle(), applySgr(TermStyle(fg = TermColor.Indexed(3)), "0"))
    }

    @Test
    fun ignoresBadColors() {
        assertNull("an index above 255 is not a color", applySgr(TermStyle(), "38;5;300").fg)
        assertNull("an incomplete color is not a color", applySgr(TermStyle(), "38;2;1;2").fg)
        // An unknown color form ends the parameters, so 9 and 1 do not become styles.
        assertEquals(TermStyle(bold = true), applySgr(TermStyle(), "1;38;9;1"))
        assertEquals("a private form changes nothing", TermStyle(), applySgr(TermStyle(), ">4"))
    }

    @Test
    fun dropsOtherSequencesAndControls() {
        val text = "a$esc[2Kb$esc]8;;https://example.com${esc}\\link$esc]8;;\u0007c$esc(Bd${esc}7e\r\u0001f"
        assertEquals("ablinkcdef", parseAnsi(text).single().text)
        assertEquals("a lone escape at the end goes", "x", parseAnsi("x$esc").single().text)
    }

    @Test
    fun expandsTabsAndSplitsLines() {
        val lines = parseAnsi("a\tb\r\n\tc\n")
        assertEquals(listOf("a       b", "        c"), lines.map { it.text })
        assertEquals("nbsp becomes a space", "❯ x", parseAnsi("❯ x").single().text)
    }

    @Test
    fun stylesContinueOnTheNextLine() {
        val lines = parseAnsi("$esc[32mone\ntwo$esc[0m")
        assertEquals(TermStyle(fg = TermColor.Indexed(2)), lines[1].spans.single().style)
    }

    @Test
    fun tidiesStyledLines() {
        val rule = "$esc[38;5;4m" + "─".repeat(80) + "$esc[0m"
        val lines = termLines("$rule\n$esc[1mbold$esc[0m   $esc[41m   $esc[0m\n\n  \n")
        assertEquals(2, lines.size)
        val fitted = fitLines(lines, 32)
        assertEquals("─".repeat(32), fitted[0].text)
        assertEquals("a shortened rule keeps its color", TermColor.Indexed(4), fitted[0].spans.single().style.fg)
        assertEquals("trailing blanks go, also with a background", listOf(TermSpan("bold", TermStyle(bold = true))), lines[1].spans)
    }

    @Test
    fun computesThePalette() {
        assertNull(paletteRgb(15))
        assertEquals(0x000000, paletteRgb(16))
        assertEquals(0xFFFFFF, paletteRgb(231))
        assertEquals(0xD7875F, paletteRgb(173))
        assertEquals(0x080808, paletteRgb(232))
        assertEquals(0xEEEEEE, paletteRgb(255))
    }

    private val claudeDialog = listOf(
        "● I will run the migration.",
        "Steps:",
        "1. Check the schema",
        "2. Apply the change",
        "─".repeat(32),
        " Bash command",
        "",
        "   bin/migrate --apply",
        "",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and don't ask again for bin/migrate commands",
        "   3. No, and tell Claude what to do differently (esc)",
    )

    @Test
    fun findsTheChoicesOfADialog() {
        val choices = findChoices(claudeDialog)
        assertEquals(
            listOf(
                AgentChoice("1", "Yes", selected = true),
                AgentChoice("2", "Yes, and don't ask again for bin/migrate commands"),
                AgentChoice("3", "No, and tell Claude what to do differently (esc)"),
            ),
            choices,
        )
    }

    @Test
    fun findsChoicesWithDescriptionsAndARule() {
        val lines = listOf(
            "Which database do you want?",
            "❯ 1. Postgres",
            "     The default for new services",
            "  2. SQLite",
            "     A file on the disk",
            "  3. Type something.",
            "─".repeat(32),
            "  4. Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        )
        assertEquals(listOf("1", "2", "3", "4"), findChoices(lines).map { it.key })
    }

    @Test
    fun findsNoChoicesInProse() {
        assertTrue("a single choice is not a dialog", findChoices(listOf("1. Only one")).isEmpty())
        val prose = listOf("1. Check the schema", "2. Apply the change") + List(20) { "more output $it" }
        assertTrue("a list far from the end is not a dialog", findChoices(prose).isEmpty())
        assertTrue(findChoices(emptyList()).isEmpty())
    }

    @Test
    fun outputKeepsColorsAndFindsChoices() {
        val text = claudeDialog.joinToString("\n").replace(" ❯ 1. Yes", " $esc[38;5;4m❯ 1. Yes$esc[0m")
        val o = parseHerdrOutput(body("""{"kind":"output","pane":"w5:p1","format":"ansi","text":${kotlinx.serialization.json.JsonPrimitive(text)}}"""))!!
        assertEquals(claudeDialog.joinToString("\n"), o.text)
        assertEquals(TermColor.Indexed(4), o.lines[10].spans.last().style.fg)
        assertEquals(3, o.choices.size)
    }

    @Test
    fun parsesControl() {
        val on = parseHerdrState(body("""{"kind":"state","enabled":true,"running":true,"control":true,"agents":[]}"""))!!
        assertTrue(on.control)
        val missing = parseHerdrState(body("""{"kind":"state","enabled":true,"running":true,"agents":[]}"""))!!
        assertFalse("a missing control field is false", missing.control)
        val off = parseHerdrState(body("""{"kind":"state","enabled":false,"control":true}"""))!!
        assertFalse("a computer with herdr off takes no replies", off.control)
    }

    @Test
    fun parsesSent() {
        assertEquals(HerdrSent("w5:p1", "keys", null), parseHerdrSent(body("""{"kind":"sent","pane":"w5:p1","action":"keys"}""")))
        val e = parseHerdrSent(body("""{"kind":"sent","pane":"w5:p1","action":"prompt","error":"Replies from the phone are off on this computer."}"""))!!
        assertEquals("prompt", e.action)
        assertEquals("Replies from the phone are off on this computer.", e.error)
        assertNull("a sent answer needs a pane", parseHerdrSent(body("""{"kind":"sent","action":"keys"}""")))
        assertNull("an output is not a sent answer", parseHerdrSent(body("""{"kind":"output","pane":"w5:p1"}""")))
    }

    @Test
    fun keysMatchTheComputer() {
        for (k in listOf("enter", "esc", "tab", "shift+tab", "up", "down", "left", "right", "backspace", "space", "y", "n", "0", "9")) {
            assertTrue(k, k in HERDR_KEYS)
        }
        assertFalse("ctrl+c" in HERDR_KEYS)
        assertEquals(22, HERDR_KEYS.size)
    }
}
