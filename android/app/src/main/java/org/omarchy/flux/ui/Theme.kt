package org.omarchy.flux.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

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
