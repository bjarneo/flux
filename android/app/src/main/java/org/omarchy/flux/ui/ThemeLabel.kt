package org.omarchy.flux.ui

import org.omarchy.flux.core.UiState

/**
 * The second line of the Computer choice of the theme setting. It names
 * the theme that the choice draws now and the computer that sent it, for
 * example "cotton-candy from omarchy-desk". Without a computer theme, it
 * names the Tokyo Night palette that the app draws until a computer sends
 * its theme.
 */
fun computerThemeLine(state: UiState, systemDark: Boolean): String {
    fun nameOf(id: String?) = state.devices.firstOrNull { it.id == id }?.name?.ifEmpty { null }
    val t = state.computerTheme
    if (t == null) {
        val fallback = if (systemDark) "Tokyo Night" else "Tokyo Night Day"
        val scope = nameOf(state.themeScope)
        return if (scope != null) "$fallback until $scope sends its theme" else "$fallback until a computer sends its theme"
    }
    val theme = t.name.ifEmpty { null }
    val computer = nameOf(t.deviceId)
    return when {
        theme != null && computer != null -> "$theme from $computer"
        theme != null -> theme
        computer != null -> "The theme of $computer"
        else -> "The theme of a computer"
    }
}
