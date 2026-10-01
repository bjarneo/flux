package org.omarchy.flux.ui

import androidx.annotation.DrawableRes
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import org.omarchy.flux.core.ThemeMode

/**
 * The color roles of the app, taken from the Material 3 color scheme of
 * [TiledTheme]. The names describe where the design uses each color.
 */
object Palette {
    private val c @Composable get() = MaterialTheme.colorScheme

    val background: Color @Composable get() = c.background
    val text: Color @Composable get() = c.onSurface
    val secondary: Color @Composable get() = c.onSurfaceVariant

    val tile: Color @Composable get() = c.surfaceContainerHigh
    val pad: Color @Composable get() = c.surfaceContainerLow

    val accent: Color @Composable get() = c.primary
    val accentContainer: Color @Composable get() = c.primaryContainer
    val onAccentContainer: Color @Composable get() = c.onPrimaryContainer
}

/** 1 choice of the theme setting: the mode, its label, and its icon. */
data class ThemeChoice(val mode: ThemeMode, val label: String, @param:DrawableRes val icon: Int)

/**
 * The choices of the theme setting, in menu order. Computer, the default,
 * follows the Omarchy theme of the computer in scope.
 */
val ThemeChoices = listOf(
    ThemeChoice(ThemeMode.Computer, "Computer", Ic.laptop),
    ThemeChoice(ThemeMode.System, "System", Ic.systemTheme),
    ThemeChoice(ThemeMode.Light, "Light", Ic.lightMode),
    ThemeChoice(ThemeMode.Dark, "Dark", Ic.darkMode),
)
