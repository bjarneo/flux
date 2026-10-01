package org.omarchy.flux.theme

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.core.ThemeMode
import kotlin.math.PI
import kotlin.math.abs

class ThemePaletteTest {
    private fun hex(c: Int) = OmarchyTheme.hex(c)

    private fun assertContrast(what: String, a: Int, b: Int, least: Double) {
        val r = contrast(a, b)
        assertTrue("$what: ${hex(a)} on ${hex(b)} is ${"%.2f".format(r)}:1, needs $least:1", r >= least)
    }

    /** Asserts each contrast that the palette promises. */
    private fun assertReadable(p: PaletteSpec) {
        for (s in p.surfaces + p.line + p.accentTile) assertContrast("${p.name} text", p.text, s, TEXT_CONTRAST)
        for (s in p.surfaces) assertContrast("${p.name} sub", p.sub, s, TEXT_CONTRAST)
        for (s in listOf(p.bg, p.tile, p.tileHi)) assertContrast("${p.name} dim", p.dim, s, NON_TEXT_CONTRAST)
        val fills = listOf("accent", "cyan", "green", "magenta", "orange", "red", "yellow").zip(p.fills)
        for ((name, c) in fills) {
            for (s in p.surfaces) assertContrast("${p.name} $name as text", c, s, TEXT_CONTRAST)
            assertContrast("${p.name} ink on $name", p.onAccent, c, TEXT_CONTRAST)
        }
        assertTrue("${p.name} has a border", p.border.isNotEmpty())
        for (b in p.border) for (s in listOf(p.bg, p.tile)) assertContrast("${p.name} border", b, s, NON_TEXT_CONTRAST)
    }

    private fun hueDistance(a: Double, b: Double): Double {
        val d = abs(a - b) % (2 * PI)
        return if (d > PI) 2 * PI - d else d
    }

    /** Asserts that the guard kept the hue of a color with a visible chroma. */
    private fun assertSameHue(what: String, from: Int, to: Int) {
        val a = oklch(from)
        val b = oklch(to)
        if (a.c < 0.04 || b.c < 0.04) return
        assertTrue("$what: the hue moved from ${hex(from)} to ${hex(to)}", hueDistance(a.h, b.h) < 0.08)
    }

    @Test
    fun contrastFollowsWcag() {
        assertEquals(21.0, contrast(0x000000, 0xFFFFFF), 0.01)
        assertEquals(1.0, contrast(0x7AA2F7, 0x7AA2F7), 0.0001)
        // The well-known lightest gray that passes AA on white.
        assertEquals(4.54, contrast(0x767676, 0xFFFFFF), 0.01)
        assertEquals(contrast(0x16161E, 0xC0CAF5), contrast(0xC0CAF5, 0x16161E), 0.0)
    }

    @Test
    fun theGuardKeepsAPassingColor() {
        assertEquals(0xC0CAF5, guard(0xC0CAF5, listOf(Need(0x16161E, TEXT_CONTRAST)), lighter = true))
    }

    @Test
    fun theGuardMovesOnlyTheLightness() {
        val tiles = listOf(0x16161E, 0x1F2335, 0x24283B)
        // The old Tokyo Night dim, 2.35 to 2.91:1 on the tiles.
        val moved = guard(0x565F89, tiles.map { Need(it, TEXT_CONTRAST) }, lighter = true)
        tiles.forEach { assertContrast("moved dim", moved, it, TEXT_CONTRAST) }
        assertTrue(oklch(moved).l > oklch(0x565F89).l)
        assertSameHue("dim", 0x565F89, moved)
        // A saturated red on a light tile goes darker and stays red.
        val red = guard(0xF52A65, listOf(Need(0xE9EAEF, TEXT_CONTRAST)), lighter = false)
        assertContrast("red", red, 0xE9EAEF, TEXT_CONTRAST)
        assertSameHue("red", 0xF52A65, red)
    }

    @Test
    fun theFallbackPalettesAreReadable() {
        assertReadable(TokyoNight)
        assertReadable(TokyoNightDay)
        assertTrue(TokyoNight.dark)
        assertFalse(TokyoNightDay.dark)
    }

    @Test
    fun theFallbackPalettesKeepTheValuesOfTheReview() {
        // Light: the true Tokyo Night Day page, a neutral ink, and white on the primary fill.
        assertEquals(0xE1E2E7, TokyoNightDay.bg)
        assertEquals(0x2457B8, TokyoNightDay.accent)
        assertEquals(0xFFFFFF, TokyoNightDay.onAccent)
        assertTrue(contrast(TokyoNightDay.onAccent, TokyoNightDay.accent) > 6.5)
        assertTrue("the light body ink is a neutral", oklch(TokyoNightDay.text).c < 0.06)
        // The light body ink and the accent no longer look alike.
        assertTrue(oklch(TokyoNightDay.accent).c > 3 * oklch(TokyoNightDay.text).c)
        // Dark: the second ink is about #8089B3, and the dim borders reach 3:1.
        assertEquals(0x858EB8, TokyoNight.sub)
        assertEquals(0x16161E, TokyoNight.bg)
        assertEquals(0xC0CAF5, TokyoNight.text)
    }

    @Test
    fun theThemeOfTheUserKeepsItsColors() {
        val theme = SampleThemes.neon
        val p = paletteOf(theme)
        assertReadable(p)
        assertTrue(p.dark)
        // The colors that pass stay as they are.
        assertEquals(0x0C031F, p.bg)
        assertEquals(0xE8E6EF, p.text)
        assertEquals(0xD563FE, p.accent)
        assertEquals(0xFE288F, p.red)
        assertEquals(0x21E4F8, p.cyan)
        // The accent, not the lime blue, is the primary color.
        assertNotEquals(0xBDFF6D, p.accent)
        // The muted color gets lighter for its 3:1 and keeps its hue.
        assertNotEquals(0x665A8C, p.dim)
        assertSameHue("muted", 0x665A8C, p.dim)
        // The ink on the accent is the dark page, which reads better than the light text.
        assertEquals(p.bg, p.onAccent)
        assertTrue(contrast(p.onAccent, p.accent) > contrast(p.text, p.accent))
        // The tiles are lighter steps of the page, with its purple hue.
        assertTrue(luminance(p.tile) > luminance(p.bg))
        assertTrue(luminance(p.tileHi) > luminance(p.tile))
        assertSameHue("tile", 0x0C031F, p.tile)
        // The border comes from the theme, at its angle.
        assertEquals(listOf(0x21E4F8, 0xD563FE), p.border)
        assertEquals(45f, p.borderAngle)
    }

    @Test
    fun tokyoNightFromAComputerStaysTokyoNight() {
        val p = paletteOf(SampleThemes.tokyoNight)
        assertReadable(p)
        assertEquals(0x1A1B26, p.bg)
        assertEquals(0xC0CAF5, p.text)
        assertEquals(0x7AA2F7, p.accent)
        assertEquals(0xF7768E, p.red)
        assertEquals(0x24283B, p.tileHi)
        assertTrue(luminance(p.tile) > luminance(p.bg))
    }

    @Test
    fun tokyoNightDayGetsANeutralInkAndDarkerColors() {
        val theme = SampleThemes.tokyoNightDay
        val p = paletteOf(theme)
        assertReadable(p)
        assertFalse(p.dark)
        assertEquals(0xE1E2E7, p.bg)
        // The body ink was the accent blue. Now it is a neutral with the same hue.
        assertTrue(oklch(p.text).c <= 0.05)
        assertSameHue("red", theme["red"]!!, p.red)
        assertSameHue("accent", theme["accent"]!!, p.accent)
        // The tiles are the darker steps of the page.
        assertTrue(luminance(p.tile) < luminance(p.bg))
        assertTrue(luminance(p.tileHi) < luminance(p.tile))
        // The light ink reads better on the dark accent.
        assertTrue(luminance(p.onAccent) > luminance(p.accent))
    }

    @Test
    fun catppuccinLatteIsReadable() {
        val theme = SampleThemes.catppuccinLatte
        val p = paletteOf(theme)
        assertReadable(p)
        assertFalse(p.dark)
        assertEquals(0xEFF1F5, p.bg)
        assertEquals(0xE6E9EF, p.tile)
        assertEquals(0xDCE0E8, p.tileHi)
        assertEquals(0x4C4F69, p.text)
        for (key in listOf("red", "green", "yellow", "cyan", "magenta")) {
            val c = p.fills[listOf("accent", "cyan", "green", "magenta", "orange", "red", "yellow").indexOf(key)]
            assertSameHue(key, theme[key]!!, c)
        }
        // 1 border color makes a solid border.
        assertEquals(1, p.border.size)
    }

    @Test
    fun aLowContrastThemeBecomesReadable() {
        val theme = SampleThemes.lowContrast
        val p = paletteOf(theme)
        assertReadable(p)
        assertTrue(p.dark)
        // The page goes darker so that the ink can reach its contrast.
        assertTrue(luminance(p.bg) < luminance(theme["background"]!!))
        assertTrue(contrast(p.text, p.bg) >= TEXT_CONTRAST)
        assertSameHue("accent", theme["accent"]!!, p.accent)
        assertSameHue("red", theme["red"]!!, p.red)
    }

    @Test
    fun aThemeWithFewColorsTakesTheRestFromTokyoNight() {
        val dark = paletteOf(OmarchyTheme("bare", null, mapOf("background" to 0x101010, "foreground" to 0xEEEEEE)))
        assertReadable(dark)
        assertTrue(dark.dark)
        assertEquals(TokyoNight.red, dark.red)
        val light = paletteOf(OmarchyTheme("bare", false, mapOf("accent" to 0x8839EF)))
        assertReadable(light)
        assertFalse(light.dark)
        assertEquals(TokyoNightDay.bg, light.bg)
        // Without a border, the gradient goes from the accent to cyan, corner to corner.
        assertEquals(listOf(light.accent, light.cyan), light.border)
        assertNull(light.borderAngle)
    }

    @Test
    fun theBackgroundDecidesTheMode() {
        val p = paletteOf(OmarchyTheme("wrong mode", true, mapOf("background" to 0xF7F7F7, "foreground" to 0x2B2426)))
        assertFalse(p.dark)
        assertEquals(0xF7F7F7, p.bg)
        assertReadable(p)
    }

    @Test
    fun aDarkBorderGetsLighter() {
        val p = paletteOf(OmarchyTheme("dark border", true, mapOf("background" to 0x0C031F), listOf(0x1A0A30, 0x0C031F), 90f))
        assertReadable(p)
        assertEquals(2, p.border.size)
        assertEquals(90f, p.borderAngle)
    }

    @Test
    fun theComputerSettingFollowsTheComputerOrThePhone() {
        val computer = paletteOf(SampleThemes.neon)
        assertSame(computer, resolvePalette(ThemeMode.Computer, computer, systemDark = false))
        assertSame(TokyoNight, resolvePalette(ThemeMode.Computer, null, systemDark = true))
        assertSame(TokyoNightDay, resolvePalette(ThemeMode.Computer, null, systemDark = false))
        assertSame(TokyoNight, resolvePalette(ThemeMode.System, computer, systemDark = true))
        assertSame(TokyoNightDay, resolvePalette(ThemeMode.Light, computer, systemDark = true))
        assertSame(TokyoNight, resolvePalette(ThemeMode.Dark, computer, systemDark = false))
    }

    @Test
    fun theNightModeFollowsTheComputerTheme() {
        assertEquals(ThemeMode.Dark, nightModeOf(ThemeMode.Computer, paletteOf(SampleThemes.neon)))
        assertEquals(ThemeMode.Light, nightModeOf(ThemeMode.Computer, paletteOf(SampleThemes.catppuccinLatte)))
        assertEquals(ThemeMode.System, nightModeOf(ThemeMode.Computer, null))
        assertEquals(ThemeMode.Light, nightModeOf(ThemeMode.Light, paletteOf(SampleThemes.neon)))
        assertEquals(ThemeMode.System, nightModeOf(ThemeMode.System, paletteOf(SampleThemes.neon)))
    }

    @Test
    fun computerIsTheDefaultSetting() {
        assertEquals(ThemeMode.Computer, ThemeMode.fromKey(null))
        assertEquals(ThemeMode.Computer, ThemeMode.fromKey("unknown"))
        assertEquals(ThemeMode.System, ThemeMode.fromKey("system"))
        assertEquals(ThemeMode.Computer, ThemeMode.fromKey("computer"))
    }

    @Test
    fun everySampleIsReadable() {
        SampleThemes.all.forEach { assertReadable(paletteOf(it)) }
    }
}
