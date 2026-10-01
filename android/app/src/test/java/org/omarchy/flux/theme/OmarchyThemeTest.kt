package org.omarchy.flux.theme

import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.json

class OmarchyThemeTest {
    private fun body(text: String) = json.parseToJsonElement(text) as JsonObject

    @Test
    fun readsTheThemePacket() {
        val line = """{"id":1,"type":"flux.theme","body":{"name":"synthwave","mode":"dark",""" +
            """"colors":{"background":"#0c031f","foreground":"#E8E6EF","accent":"#d563fe","bright_red":"#fe83af"},""" +
            """"border":{"colors":["#21e4f8ee","#d563feee"],"angle":45}}}"""
        val p = Packet.parse(line)!!
        assertEquals(Types.FLUX_THEME, p.type)
        val t = OmarchyTheme.parse(p.body)!!
        assertEquals("synthwave", t.name)
        assertEquals(true, t.dark)
        assertEquals(0x0C031F, t["background"])
        assertEquals(0xE8E6EF, t["foreground"])
        assertEquals(0xFE83AF, t["bright_red"])
        // The border drops the alpha of Hyprland.
        assertEquals(listOf(0x21E4F8, 0xD563FE), t.border)
        assertEquals(45f, t.borderAngle)
    }

    @Test
    fun eachKeyCanBeMissing() {
        val t = OmarchyTheme.parse(body("""{"colors":{"background":"#fdf6e3"}}"""))!!
        assertEquals("", t.name)
        assertNull(t.dark)
        assertTrue(t.border.isEmpty())
        assertNull(t.borderAngle)
        val light = OmarchyTheme.parse(body("""{"mode":"light","border":{"colors":["#ffffff"]}}"""))!!
        assertEquals(false, light.dark)
        assertTrue(light.colors.isEmpty())
    }

    @Test
    fun ignoresWhatItCannotRead() {
        val t = OmarchyTheme.parse(
            body(
                """{"mode":"sepia","colors":{"background":"#12345","foreground":"rgb(1,2,3)","Accent":"#ffffff",""" +
                    """"red":7,"green":"#00ff00"},"border":{"colors":["#zzzzzz",3,"#00ff00"],"angle":"-90deg"}}""",
            ),
        )!!
        assertNull(t.dark)
        assertEquals(mapOf("green" to 0x00FF00), t.colors)
        assertEquals(listOf(0x00FF00), t.border)
        assertEquals(270f, t.borderAngle)
    }

    @Test
    fun aBodyWithoutColorsIsNoTheme() {
        assertNull(OmarchyTheme.parse(body("""{"name":"empty"}""")))
        assertNull(OmarchyTheme.parse(body("""{"colors":{"background":"blue"}}""")))
    }

    @Test
    fun limitsTheSizes() {
        val colors = (0 until 100).joinToString(",") { "\"c$it\":\"#010203\"" }
        val border = (0 until 20).joinToString(",") { "\"#ffffff\"" }
        val t = OmarchyTheme.parse(body("""{"name":"${"x".repeat(200)}","colors":{$colors},"border":{"colors":[$border]}}"""))!!
        assertEquals(OmarchyTheme.MAX_COLORS, t.colors.size)
        assertEquals(OmarchyTheme.MAX_BORDER, t.border.size)
        assertEquals(OmarchyTheme.MAX_NAME, t.name.length)
    }

    @Test
    fun theSavedFormReadsBackTheSame() {
        for (t in SampleThemes.all) assertEquals(t, OmarchyTheme.parse(t.toJson()))
        assertEquals("#0c031f", OmarchyTheme.hex(0x0C031F))
    }

    @Test
    fun thePhoneAsksForTheTheme() {
        assertTrue(Types.FLUX_THEME in INCOMING)
        assertEquals("flux.theme", Types.FLUX_THEME)
    }
}
