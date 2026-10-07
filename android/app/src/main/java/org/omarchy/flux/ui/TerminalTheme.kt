package org.omarchy.flux.ui

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.omarchy.flux.theme.OmarchyTheme

/**
 * The xterm.js theme of an Omarchy theme: the default background and
 * foreground, the cursor, the selection, and the 16 ANSI colors. The
 * terminal of a pane draws the frames of a program, so where a frame
 * asks for a default or an indexed color, the phone shows the color of
 * the computer instead of a hardcoded black.
 *
 * Only the keys that the theme sets are included: a missing key keeps
 * the xterm default. Explicit RGB colors of a frame always win.
 */
fun terminalTheme(theme: OmarchyTheme): JsonObject {
    fun hex(vararg keys: String): String? =
        keys.firstNotNullOfOrNull { theme[it] }?.let { OmarchyTheme.hex(it) }

    return buildJsonObject {
        hex("background")?.let { put("background", it) }
        hex("foreground")?.let { put("foreground", it) }
        // The cursor takes the cursor color of the theme, or else the text
        // color, as the desktop terminal does. An accent cursor looks like
        // a selection.
        hex("cursor", "foreground")?.let { put("cursor", it) }
        hex("background")?.let { put("cursorAccent", it) }
        hex("selection", "accent")?.let { put("selectionBackground", it) }
        hex("color0", "dark_background", "background")?.let { put("black", it) }
        hex("color1", "red")?.let { put("red", it) }
        hex("color2", "green")?.let { put("green", it) }
        hex("color3", "yellow", "orange")?.let { put("yellow", it) }
        hex("color4", "blue")?.let { put("blue", it) }
        hex("color5", "magenta")?.let { put("magenta", it) }
        hex("color6", "cyan")?.let { put("cyan", it) }
        hex("color7", "light_foreground", "foreground")?.let { put("white", it) }
        hex("color8", "dark_foreground", "muted")?.let { put("brightBlack", it) }
        hex("color9", "bright_red", "red")?.let { put("brightRed", it) }
        hex("color10", "bright_green", "green")?.let { put("brightGreen", it) }
        hex("color11", "bright_yellow", "yellow")?.let { put("brightYellow", it) }
        hex("color12", "bright_blue", "blue")?.let { put("brightBlue", it) }
        hex("color13", "bright_magenta", "magenta")?.let { put("brightMagenta", it) }
        hex("color14", "bright_cyan", "cyan")?.let { put("brightCyan", it) }
        hex("color15", "bright_foreground", "foreground")?.let { put("brightWhite", it) }
    }
}
