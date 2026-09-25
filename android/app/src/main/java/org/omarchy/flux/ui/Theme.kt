package org.omarchy.flux.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

/**
 * The system theme. Android 12 and later give the wallpaper colors of the
 * phone. Android 10 and 11 get the default Material 3 colors. The theme
 * follows the dark or light mode of the phone.
 */
@Composable
fun FluxTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val context = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

/**
 * The color roles of the app, taken from the Material 3 color scheme. The
 * names describe where the design uses each color.
 */
object Palette {
    private val c @Composable get() = MaterialTheme.colorScheme

    val background: Color @Composable get() = c.background
    val text: Color @Composable get() = c.onSurface
    val secondary: Color @Composable get() = c.onSurfaceVariant
    val body: Color @Composable get() = c.onSurfaceVariant
    val hint: Color @Composable get() = c.outline

    val tile: Color @Composable get() = c.surfaceContainerHigh
    val tilePressed: Color @Composable get() = c.surfaceContainerHighest
    val rowPressed: Color @Composable get() = c.surfaceContainer
    val avatarOff: Color @Composable get() = c.surfaceContainerHighest
    val dialog: Color @Composable get() = c.surfaceContainerHigh
    val pad: Color @Composable get() = c.surfaceContainerLow
    val track: Color @Composable get() = c.surfaceContainerHighest
    val stripeA: Color @Composable get() = c.surfaceContainerHighest
    val stripeB: Color @Composable get() = c.surfaceContainerLow

    val border: Color @Composable get() = c.outlineVariant
    val borderStrong: Color @Composable get() = c.outline
    val thumbOff: Color @Composable get() = c.outline

    val accent: Color @Composable get() = c.primary
    val onAccent: Color @Composable get() = c.onPrimary
    val accentContainer: Color @Composable get() = c.primaryContainer
    val onAccentContainer: Color @Composable get() = c.onPrimaryContainer

    val snackbar: Color @Composable get() = c.inverseSurface
    val snackbarText: Color @Composable get() = c.inverseOnSurface
    val scrim: Color @Composable get() = c.scrim.copy(alpha = 0.55f)
}
