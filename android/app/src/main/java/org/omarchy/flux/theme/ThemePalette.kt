package org.omarchy.flux.theme

import org.omarchy.flux.core.ThemeMode

/**
 * The colors of 1 Flux palette, as 0xRRGGBB. TiledKit turns a palette into
 * the Tn tokens. [paletteOf] makes a palette from the theme of a computer,
 * and [TokyoNight] and [TokyoNightDay] are the palettes without one.
 */
data class PaletteSpec(
    /** The name of the theme, for example "tokyo-night". */
    val name: String,
    val dark: Boolean,
    /** The page. */
    val bg: Int,
    /** A tile that is off, and the background of the agent output. */
    val offTile: Int,
    val tile: Int,
    /** A tile that stands out, a menu, or a dialog. */
    val tileHi: Int,
    /** The border of a tile, and a container for [text]. */
    val line: Int,
    val lineHi: Int,
    /** The body ink. It reaches 4.5:1 on each surface. */
    val text: Int,
    /** The second ink. It reaches 4.5:1 on each surface except [line] and [accentTile]. */
    val sub: Int,
    /** For borders and disabled states only. It reaches 3:1 on [bg], [tile], and [tileHi]. */
    val dim: Int,
    /** The ink on a fill of [accent] or a semantic color. It reaches 4.5:1 on each of them. */
    val onAccent: Int,
    /** The accent of the theme. */
    val accent: Int,
    /** A tile with a tint of the accent, for a selected item. [text] reaches 4.5:1 on it. */
    val accentTile: Int,
    val cyan: Int,
    val green: Int,
    val magenta: Int,
    val orange: Int,
    /** Red means "needs you" or an error, nothing else. */
    val red: Int,
    val yellow: Int,
    /** The colors of the active border gradient. Each reaches 3:1 on [bg] and [tile]. */
    val border: List<Int>,
    /** The angle of the border gradient in degrees, as in Hyprland, or null for corner to corner. */
    val borderAngle: Float?,
) {
    /** The surfaces that body text sits on. */
    val surfaces: List<Int> get() = listOf(bg, offTile, tile, tileHi)

    /** The fills that take [onAccent] text. */
    val fills: List<Int> get() = listOf(accent, cyan, green, magenta, orange, red, yellow)
}

/** The contrast that text needs, WCAG 2.2 AA. */
const val TEXT_CONTRAST = 4.5

/** The contrast that icons, borders, and large text need, WCAG 2.2 AA. */
const val NON_TEXT_CONTRAST = 3.0

/** How much of the accent the [PaletteSpec.accentTile] takes. */
private const val ACCENT_TILE_MIX = 0.18

private const val WHITE = 0xFFFFFF
private const val BLACK = 0x000000

private fun spec(
    name: String, dark: Boolean, bg: Int, offTile: Int, tile: Int, tileHi: Int, line: Int, lineHi: Int,
    text: Int, sub: Int, dim: Int, onAccent: Int, accent: Int, cyan: Int, green: Int, magenta: Int,
    orange: Int, red: Int, yellow: Int,
) = PaletteSpec(
    name, dark, bg, offTile, tile, tileHi, line, lineHi, text, sub, dim, onAccent, accent,
    accentTile = mix(tileHi, accent, ACCENT_TILE_MIX),
    cyan = cyan, green = green, magenta = magenta, orange = orange, red = red, yellow = yellow,
    border = listOf(accent, cyan), borderAngle = null,
)

/**
 * Tokyo Night, the default Omarchy theme. The tiles are lighter than the
 * page. [PaletteSpec.sub] and [PaletteSpec.dim] are lighter than the
 * Tokyo Night comment color, so that they reach their contrast.
 */
val TokyoNight = spec(
    name = "tokyo-night", dark = true,
    bg = 0x16161E, offTile = 0x1A1B26, tile = 0x1F2335, tileHi = 0x24283B, line = 0x292E42, lineHi = 0x3B4261,
    text = 0xC0CAF5, sub = 0x858EB8, dim = 0x66709B, onAccent = 0x16161E,
    accent = 0x7AA2F7, cyan = 0x7DCFFF, green = 0x9ECE6A, magenta = 0xBB9AF7, orange = 0xFF9E64, red = 0xF7768E, yellow = 0xE0AF68,
)

/**
 * Tokyo Night Day. The tiles are darker steps of the page, as in a light
 * Omarchy theme. The body ink is a neutral slate, so that blue means "you
 * can tap this". The colors are darker steps of the Tokyo Night Day
 * colors, so that they reach 4.5:1 on each tile.
 */
val TokyoNightDay = spec(
    name = "tokyo-night-day", dark = false,
    bg = 0xE1E2E7, offTile = 0xDDDEE4, tile = 0xD9DBE1, tileHi = 0xD4D5DC, line = 0xC4C8DA, lineHi = 0xA8AECB,
    text = 0x343B58, sub = 0x4B5993, dim = 0x70769E, onAccent = WHITE,
    accent = 0x2457B8, cyan = 0x006486, green = 0x496529, magenta = 0x7B31CF, orange = 0x914A00, red = 0xBA0046, yellow = 0x765729,
)

/** Below this background luminance, a theme is dark. White and black have the same contrast on it. */
private const val DARK_LUMINANCE = 0.179

/** The contrast of white on a dark page, or of black on a light page, at least. */
private const val BG_HEADROOM = 10.0

/** The same for a tile, so that the text and the colors can reach their contrast. */
private const val TILE_HEADROOM = 7.0

/** The same for [PaletteSpec.line] and [PaletteSpec.accentTile], which hold text. */
private const val LINE_HEADROOM = 6.0

/** The contrast of a surface step against the page: the least, the most, and the value to make. */
private class Step(val least: Double, val most: Double, val make: Double)

private val TILE_DARK = Step(1.06, 1.25, 1.12)
private val HI_DARK = Step(1.10, 1.40, 1.22)
private val TILE_LIGHT = Step(1.04, 1.12, 1.07)
private val HI_LIGHT = Step(1.08, 1.20, 1.13)

private const val LINE_MIX = 0.08
private const val LINE_HI_MIX = 0.22
private const val SUB_MIX = 0.3
private const val DIM_MIX = 0.55

/** The most chroma of the body ink in a light theme, so that it reads as a neutral. */
private const val NEUTRAL_CHROMA = 0.045

private fun needs(ratio: Double, colors: List<Int>) = colors.map { Need(it, ratio) }

/**
 * Makes the palette of a computer theme, through the contrast guard:
 *
 * - background gives the page. A tile is a step toward the ink: a lighter
 *   step from lighter_background in a dark theme, and the darker steps
 *   dark_background and darker_background in a light theme.
 * - foreground gives the body ink. In a light theme, the ink loses its
 *   chroma, so that it is a neutral and not the accent.
 * - The second ink comes from the body ink and the page.
 * - muted gives the dim color, accent the accent, and the terminal colors
 *   the semantic colors. A missing color comes from Tokyo Night.
 * - The guard moves only the lightness of a color, so the hue stays.
 *
 * The background decides whether the theme is dark. The mode of the
 * theme counts only when the background is missing.
 */
fun paletteOf(theme: OmarchyTheme): PaletteSpec {
    val rawBg = theme["background"]
    val dark = rawBg?.let { luminance(it) < DARK_LUMINANCE } ?: theme.dark ?: true
    val base = if (dark) TokyoNight else TokyoNightDay
    val extreme = if (dark) WHITE else BLACK
    fun surface(c: Int, headroom: Double) = guard(c, listOf(Need(extreme, headroom)), lighter = !dark)

    val bg = surface(rawBg ?: base.bg, BG_HEADROOM)
    fun inkSide(c: Int) = if (dark) luminance(c) > luminance(bg) else luminance(c) < luminance(bg)
    val fg = theme["foreground"] ?: base.text
    // The surfaces step toward the ink. A foreground on the wrong side gives no direction.
    val ink = if (inkSide(fg)) fg else extreme

    fun step(candidate: Int?, s: Step): Int {
        val c = candidate?.takeIf(::inkSide)
        if (c != null) {
            val r = contrast(bg, c)
            if (r in s.least..s.most) return c
            if (r > s.most) return stepTo(bg, c, s.most)
        }
        return stepTo(bg, ink, s.make)
    }

    val rawTile: Int
    val rawHi: Int
    if (dark) {
        rawHi = step(theme["lighter_background"], HI_DARK)
        rawTile = step(mix(bg, rawHi, 0.6), TILE_DARK)
    } else {
        rawTile = step(theme["dark_background"], TILE_LIGHT)
        val hi = step(theme["darker_background"], HI_LIGHT)
        rawHi = if (luminance(hi) < luminance(rawTile)) hi else step(null, HI_LIGHT)
    }
    val tile = surface(rawTile, TILE_HEADROOM)
    val tileHi = surface(rawHi, TILE_HEADROOM)
    val offTile = surface(mix(bg, tile, 0.5), TILE_HEADROOM)
    val line = surface(mix(tileHi, ink, LINE_MIX), LINE_HEADROOM)
    val lineHi = mix(tileHi, ink, LINE_HI_MIX)
    val surfaces = listOf(bg, offTile, tile, tileHi)

    val rawAccent = theme["accent"] ?: theme["blue"] ?: base.accent
    val accentTile = surface(mix(tileHi, rawAccent, ACCENT_TILE_MIX), LINE_HEADROOM)

    val body = if (dark) fg else limitChroma(fg, NEUTRAL_CHROMA)
    val text = guard(body, needs(TEXT_CONTRAST, surfaces + line + accentTile), lighter = dark)
    val sub = guard(mix(text, bg, SUB_MIX), needs(TEXT_CONTRAST, surfaces), lighter = dark)
    val dim = guard(theme["muted"] ?: mix(text, bg, DIM_MIX), needs(NON_TEXT_CONTRAST, listOf(bg, tile, tileHi)), lighter = dark)

    fun semantic(key: String, fallback: Int) = theme[key] ?: theme["bright_$key"] ?: fallback
    val onSurfaces = needs(TEXT_CONTRAST, surfaces)
    var colors = listOf(
        rawAccent,
        semantic("cyan", base.cyan),
        semantic("green", base.green),
        semantic("magenta", base.magenta),
        semantic("orange", base.orange),
        semantic("red", base.red),
        semantic("yellow", base.yellow),
    ).map { guard(it, onSurfaces, lighter = dark) }

    // The ink on a fill: the light or the dark ink, whichever reads better on the accent.
    val lightInk = if (luminance(text) > luminance(bg)) text else bg
    val darkInk = if (lightInk == text) bg else text
    val light = contrast(colors[0], lightInk) >= contrast(colors[0], darkInk)
    val onAccent = guard(if (light) lightInk else darkInk, needs(TEXT_CONTRAST, colors), lighter = light)
    colors = colors.map { c ->
        if (contrast(c, onAccent) >= TEXT_CONTRAST) c
        else guard(c, onSurfaces + Need(onAccent, TEXT_CONTRAST), lighter = !light)
    }
    val (accent, cyan, green, magenta, orange) = colors
    val red = colors[5]
    val yellow = colors[6]

    val borderNeeds = needs(NON_TEXT_CONTRAST, listOf(bg, tile))
    val border = theme.border.ifEmpty { listOf(accent, cyan) }.map { guard(it, borderNeeds, lighter = dark) }
    return PaletteSpec(
        name = theme.name, dark = dark,
        bg = bg, offTile = offTile, tile = tile, tileHi = tileHi, line = line, lineHi = lineHi,
        text = text, sub = sub, dim = dim, onAccent = onAccent, accent = accent, accentTile = accentTile,
        cyan = cyan, green = green, magenta = magenta, orange = orange, red = red, yellow = yellow,
        border = border, borderAngle = if (theme.border.isEmpty()) null else theme.borderAngle,
    )
}

/**
 * Picks the palette for the theme setting. [ThemeMode.Computer] takes the
 * [computer] palette. Without one, it follows the phone like
 * [ThemeMode.System]: Tokyo Night when [systemDark], else Tokyo Night Day.
 */
fun resolvePalette(mode: ThemeMode, computer: PaletteSpec?, systemDark: Boolean): PaletteSpec = when (mode) {
    ThemeMode.Computer -> computer ?: if (systemDark) TokyoNight else TokyoNightDay
    ThemeMode.System -> if (systemDark) TokyoNight else TokyoNightDay
    ThemeMode.Light -> TokyoNightDay
    ThemeMode.Dark -> TokyoNight
}

/**
 * The night mode that the app sets on the system, so that the splash
 * screen and the -night resources match: [ThemeMode.Light],
 * [ThemeMode.Dark], or [ThemeMode.System] to follow the phone.
 */
fun nightModeOf(mode: ThemeMode, computer: PaletteSpec?): ThemeMode = when (mode) {
    ThemeMode.Computer -> when (computer?.dark) {
        true -> ThemeMode.Dark
        false -> ThemeMode.Light
        null -> ThemeMode.System
    }
    else -> mode
}
