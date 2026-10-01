package org.omarchy.flux.theme

/**
 * Sample computer themes. The unit tests check the contrast guard with
 * them, and debug builds show them on the sample computer, see
 * [org.omarchy.flux.core.DebugTheme].
 */
object SampleThemes {
    private fun theme(name: String, dark: Boolean?, vararg colors: Pair<String, String>, border: List<String> = emptyList(), angle: Float? = null) =
        OmarchyTheme(
            name, dark,
            colors.associate { (k, v) -> k to OmarchyTheme.parseColor(v)!! },
            border.map { OmarchyTheme.parseColor(it)!! },
            angle,
        )

    /** A dark theme with a deep purple page, neon colors, and a lime blue. */
    val neon = theme(
        "neon", true,
        "background" to "#0c031f", "foreground" to "#e8e6ef", "accent" to "#d563fe", "muted" to "#665a8c",
        "red" to "#fe288f", "blue" to "#bdff6d", "cyan" to "#21e4f8",
        border = listOf("#21e4f8ee", "#d563feee"), angle = 45f,
    )

    val tokyoNight = theme(
        "tokyo-night", true,
        "background" to "#1a1b26", "dark_background" to "#16161e", "darker_background" to "#0f0f14",
        "lighter_background" to "#24283b", "foreground" to "#c0caf5", "dark_foreground" to "#a9b1d6",
        "muted" to "#565f89", "accent" to "#7aa2f7", "selection" to "#33467c",
        "red" to "#f7768e", "green" to "#9ece6a", "yellow" to "#e0af68", "orange" to "#ff9e64",
        "cyan" to "#7dcfff", "blue" to "#7aa2f7", "magenta" to "#bb9af7",
        border = listOf("#33ccffee", "#00ff99ee"), angle = 45f,
    )

    val tokyoNightDay = theme(
        "tokyo-night-day", false,
        "background" to "#e1e2e7", "dark_background" to "#d5d6db", "darker_background" to "#c8c9ce",
        "lighter_background" to "#e9e9ec", "foreground" to "#3760bf", "muted" to "#848cb5",
        "accent" to "#2e7de9", "red" to "#f52a65", "green" to "#587539", "yellow" to "#8c6c3e",
        "orange" to "#b15c00", "cyan" to "#007197", "blue" to "#2e7de9", "magenta" to "#9854f1",
    )

    val catppuccinLatte = theme(
        "catppuccin-latte", false,
        "background" to "#eff1f5", "dark_background" to "#e6e9ef", "darker_background" to "#dce0e8",
        "lighter_background" to "#ccd0da", "foreground" to "#4c4f69", "muted" to "#9ca0b0",
        "accent" to "#8839ef", "red" to "#d20f39", "green" to "#40a02b", "yellow" to "#df8e1d",
        "orange" to "#fe640b", "cyan" to "#04a5e5", "blue" to "#1e66f5", "magenta" to "#ea76cb",
        border = listOf("#8839efee"), angle = 0f,
    )

    /** A dark Omarchy theme whose accent and red are 2 pinks that look alike. */
    val cottonCandy = theme(
        "cotton-candy", true,
        "background" to "#191125", "dark_background" to "#130d1c", "darker_background" to "#0d0913",
        "lighter_background" to "#271f35", "foreground" to "#e9e6ef", "muted" to "#685c81",
        "accent" to "#e1a4ed", "selection" to "#513a5d", "red" to "#f097c5", "yellow" to "#f9dd7d",
        "orange" to "#feb79e", "green" to "#58e3dc", "cyan" to "#61e6ff", "blue" to "#8eaffe",
        "magenta" to "#e1a4ed", "bright_blue" to "#bdd1fe",
        border = listOf("#61e6ffee", "#e1a4edee"), angle = 45f,
    )

    /** A dark Omarchy theme whose accent is its red, and whose blue is a near white. */
    val futurism = theme(
        "futurism", true,
        "background" to "#0a1428", "lighter_background" to "#17294a", "foreground" to "#f0f8ff",
        "muted" to "#53627a", "accent" to "#ff40a3", "red" to "#ff40a3", "yellow" to "#5076b2",
        "orange" to "#ff7ab8", "green" to "#00bfff", "cyan" to "#f0f8ff", "blue" to "#f0f8ff",
        "magenta" to "#ff40a3", "bright_blue" to "#00bfff", "bright_cyan" to "#00bfff",
        "bright_magenta" to "#ff40a3",
    )

    /** A broken theme: every color is a gray near the background. */
    val lowContrast = theme(
        "low-contrast", true,
        "background" to "#5a5a5a", "foreground" to "#6e6e6e", "accent" to "#606080", "muted" to "#5c5c5c",
        "red" to "#704848", "green" to "#4a5a4a", "yellow" to "#66664a", "cyan" to "#4a6666",
        border = listOf("#5b5b5bee", "#595959ee"),
    )

    val all = listOf(neon, tokyoNight, tokyoNightDay, catppuccinLatte, cottonCandy, futurism, lowContrast)

    /** Returns the sample with [name], or null. */
    fun byName(name: String?): OmarchyTheme? = all.firstOrNull { it.name == name }
}
