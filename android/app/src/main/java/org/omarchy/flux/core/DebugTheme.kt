package org.omarchy.flux.core

import org.omarchy.flux.BuildConfig
import org.omarchy.flux.theme.SampleThemes
import org.omarchy.flux.theme.paletteOf

/**
 * Debug builds only: a sample theme for the sample computer of
 * [DebugDemo], so that each screen renders in a computer theme on an
 * emulator with no computer. `adb shell am start -n
 * org.omarchy.flux/.ui.MainActivity --ez flux.debug.demo true --es
 * flux.debug.theme neon` selects it. The names are those of
 * [SampleThemes], and "none" removes the theme.
 */
object DebugTheme {
    @Volatile private var selected: String? = null
    @Volatile private var cache: ComputerTheme? = null

    fun select(name: String) {
        selected = name
        ComputerThemes.refresh()
    }

    /** The theme of the sample computer, or null. */
    fun current(): ComputerTheme? {
        if (!BuildConfig.DEBUG || !DebugDemo.on) return null
        val theme = SampleThemes.byName(selected) ?: return null
        cache?.takeIf { it.theme == theme }?.let { return it }
        return ComputerTheme(DebugDemo.PC, theme, paletteOf(theme)).also { cache = it }
    }
}
