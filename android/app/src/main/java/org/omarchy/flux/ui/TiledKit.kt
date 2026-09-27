package org.omarchy.flux.ui

import android.app.Activity
import androidx.annotation.DrawableRes
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.ThemeMode

/**
 * The Tiled design: Tokyo Night colors, 12 dp tiles with 8 dp gaps, and an
 * active-window gradient border like Hyprland on Omarchy. [Tn] gives the
 * colors of the current theme.
 */
@Immutable
class TiledColors(
    val dark: Boolean,
    val bg: Color,
    val tile: Color,
    val tileHi: Color,
    val offTile: Color,
    val line: Color,
    val lineHi: Color,
    val text: Color,
    val sub: Color,
    val dim: Color,
    /** The text and icons on an accent fill. */
    val onAccent: Color,
    val blue: Color,
    val cyan: Color,
    val green: Color,
    val magenta: Color,
    val orange: Color,
    val red: Color,
    val yellow: Color,
)

/** Tokyo Night. */
private val TiledDark = TiledColors(
    dark = true,
    bg = Color(0xFF16161E),
    tile = Color(0xFF1F2335),
    tileHi = Color(0xFF24283B),
    offTile = Color(0xFF1A1B26),
    line = Color(0xFF292E42),
    lineHi = Color(0xFF3B4261),
    text = Color(0xFFC0CAF5),
    sub = Color(0xFFA9B1D6),
    dim = Color(0xFF565F89),
    onAccent = Color(0xFF16161E),
    blue = Color(0xFF7AA2F7),
    cyan = Color(0xFF7DCFFF),
    green = Color(0xFF9ECE6A),
    magenta = Color(0xFFBB9AF7),
    orange = Color(0xFFFF9E64),
    red = Color(0xFFF7768E),
    yellow = Color(0xFFE0AF68),
)

/**
 * Tokyo Night Day. The tiles are lighter than the background, as in the
 * dark theme. [TiledColors.tileHi] and [TiledColors.offTile] are steps
 * between the Tokyo Night Day colors.
 */
private val TiledLight = TiledColors(
    dark = false,
    bg = Color(0xFFD0D5E3),
    tile = Color(0xFFE1E2E7),
    tileHi = Color(0xFFE9EAEF),
    offTile = Color(0xFFD8DBE5),
    line = Color(0xFFC4C8DA),
    lineHi = Color(0xFFA8AECB),
    text = Color(0xFF3760BF),
    sub = Color(0xFF6172B0),
    dim = Color(0xFF848CB5),
    onAccent = Color(0xFFE1E2E7),
    blue = Color(0xFF2E7DE9),
    cyan = Color(0xFF007197),
    green = Color(0xFF587539),
    magenta = Color(0xFF9854F1),
    orange = Color(0xFFB15C00),
    red = Color(0xFFF52A65),
    yellow = Color(0xFF8C6C3E),
)

private val LocalTiledColors = staticCompositionLocalOf { TiledDark }

/** The Tiled colors of the current theme. */
val Tn: TiledColors
    @Composable @ReadOnlyComposable get() = LocalTiledColors.current

val TileShape = RoundedCornerShape(12.dp)
val TileGap = 8.dp

/** The height of 1 grid row on the device home screen. 2 rows are 2 × 62 + 8. */
val TileUnit = 62.dp
val TileUnit2 = TileUnit * 2 + TileGap
val TiledGutter = 10.dp

/** The alpha of a tile whose computer is not reachable. */
private const val DimAlpha = 0.55f

@Composable
@ReadOnlyComposable
fun activeBorder(from: Color = Tn.blue, to: Color = Tn.cyan) = BorderStroke(2.dp, Brush.linearGradient(listOf(from, to)))

/**
 * The theme of the app: Tokyo Night in the dark theme and Tokyo Night Day in
 * the light theme. [ThemeMode.System] follows the phone. Material parts,
 * such as menus, sliders, dialogs, and the camera and mic screens, take the
 * same colors as the tiles.
 */
@Composable
fun TiledTheme(content: @Composable () -> Unit) {
    val mode = FluxCore.state.collectAsStateWithLifecycle().value.theme
    val dark = when (mode) {
        ThemeMode.System -> isSystemInDarkTheme()
        ThemeMode.Light -> false
        ThemeMode.Dark -> true
    }
    val colors = if (dark) TiledDark else TiledLight
    val scheme = remember(colors) { colors.scheme() }
    // The system bars are transparent, so their icons take the color of the theme.
    val view = LocalView.current
    DisposableEffect(view, dark) {
        (view.context as? Activity)?.window?.let { window ->
            WindowCompat.getInsetsController(window, view).run {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
        onDispose { }
    }
    CompositionLocalProvider(LocalTiledColors provides colors) {
        MaterialTheme(colorScheme = scheme) {
            CompositionLocalProvider(LocalContentColor provides colors.text, content = content)
        }
    }
}

/** The Material 3 color scheme of the tiles. */
private fun TiledColors.scheme(): ColorScheme = (if (dark) darkColorScheme() else lightColorScheme()).copy(
    primary = blue, onPrimary = onAccent,
    primaryContainer = tileHi, onPrimaryContainer = text,
    secondary = cyan, onSecondary = onAccent,
    secondaryContainer = line, onSecondaryContainer = text,
    tertiary = magenta, onTertiary = onAccent,
    tertiaryContainer = line, onTertiaryContainer = text,
    background = bg, onBackground = text,
    surface = bg, onSurface = text,
    surfaceVariant = tile, onSurfaceVariant = sub,
    surfaceTint = blue,
    surfaceContainerLowest = bg, surfaceContainerLow = offTile,
    surfaceContainer = tile, surfaceContainerHigh = tileHi, surfaceContainerHighest = line,
    inverseSurface = tileHi, inverseOnSurface = text, inversePrimary = blue,
    outline = dim, outlineVariant = line,
    error = red, onError = onAccent,
    errorContainer = red, onErrorContainer = onAccent,
)

/**
 * A tile. The border takes [accent] while pressed. A long press runs
 * [onLongClick], for example to unpair a computer. A tile that is not
 * [enabled] shows at a lower alpha and still takes taps.
 */
@Composable
fun Tile(
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
    accent: Color = Tn.blue,
    container: Color = Tn.tile,
    border: BorderStroke? = BorderStroke(1.dp, Tn.line),
    enabled: Boolean = true,
    padding: PaddingValues = PaddingValues(14.dp),
    verticalArrangement: Arrangement.Vertical = Arrangement.SpaceBetween,
    horizontalAlignment: Alignment.Horizontal = Alignment.Start,
    content: @Composable ColumnScope.() -> Unit,
) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val stroke = if (pressed && onClick != null) BorderStroke(1.dp, accent) else border
    var m = modifier.alpha(if (enabled) 1f else DimAlpha).clip(TileShape).background(container)
    if (stroke != null) m = m.border(stroke, TileShape)
    if (onClick != null) {
        m = m.combinedClickable(
            interactionSource = source,
            indication = LocalIndication.current,
            onLongClick = onLongClick,
            onClick = onClick,
        )
    }
    Column(m.padding(padding), verticalArrangement = verticalArrangement, horizontalAlignment = horizontalAlignment, content = content)
}

/** A short tile with an icon and a label on 1 line. */
@Composable
fun LineTile(
    @DrawableRes icon: Int,
    label: String,
    accent: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    trailing: String? = null,
) {
    Tile(modifier, onClick, accent = accent, enabled = enabled, padding = PaddingValues(horizontal = 12.dp), verticalArrangement = Arrangement.Center) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(icon, tint = accent, size = 22.dp)
            T(label, Modifier.weight(1f), size = 13, weight = FontWeight.SemiBold, maxLines = 1)
            if (trailing != null) T(trailing, size = 11, color = Tn.dim, family = Mono)
        }
    }
}

/** A small tile: the icon over the label, centered. A [badge] above 0 shows as a red count on the icon. */
@Composable
fun MiniTile(
    @DrawableRes icon: Int,
    label: String,
    accent: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    container: Color = Tn.tile,
    badge: Int = 0,
) {
    Tile(
        modifier, onClick, accent = accent, container = container, enabled = enabled,
        padding = PaddingValues(4.dp), verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box {
            Sym(icon, tint = accent, size = 20.dp)
            if (badge > 0) {
                T(
                    if (badge > 9) "9+" else "$badge",
                    Modifier.align(Alignment.TopEnd).offset(x = 10.dp, y = (-6).dp)
                        .clip(RoundedCornerShape(7.dp)).background(Tn.red).padding(horizontal = 4.dp),
                    size = 10, color = Tn.onAccent, weight = FontWeight.Bold, family = Mono,
                )
            }
        }
        T(label, size = 11, weight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** The mono, uppercase label of a tile or a section. */
@Composable
fun TileLabel(text: String, modifier: Modifier = Modifier, color: Color = Tn.dim) {
    T(text.uppercase(), modifier, size = 11, color = color, weight = FontWeight.Medium, family = Mono, letterSpacing = 0.9f, maxLines = 1)
}

@Composable
fun SectionLabel(text: String) {
    TileLabel(text, Modifier.padding(start = 4.dp, top = 20.dp, bottom = 8.dp))
}

/** A row of tiles with the grid gap. */
@Composable
fun TileRow(height: Dp, modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    Row(modifier.fillMaxWidth().height(height), horizontalArrangement = Arrangement.spacedBy(TileGap), content = content)
}

/** A small square button with an icon, for top bars. */
@Composable
fun SquareButton(@DrawableRes icon: Int, description: String, onClick: () -> Unit, size: Dp = 36.dp) {
    Box(
        Modifier.size(size).clip(RoundedCornerShape(8.dp)).background(Tn.tile).clickable(onClickLabel = description, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Sym(icon, description, size = if (size < 36.dp) 18.dp else 20.dp) }
}

/** The top bar of an inner tiled screen: a square back button and a mono label. */
@Composable
fun TiledTopBar(label: String, onBack: () -> Unit, trailing: @Composable RowScope.() -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(start = 2.dp, top = 8.dp, bottom = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SquareButton(Ic.back, "Back", onBack)
        T(label, Modifier.weight(1f), size = 12, color = Tn.dim, weight = FontWeight.Medium, family = Mono, maxLines = 1)
        trailing()
    }
}

/** A dashed rounded border, for a computer that is available to pair. */
fun Modifier.dashedBorder(color: Color, width: Dp = 1.5.dp, radius: Dp = 12.dp): Modifier = drawBehind {
    val w = width.toPx()
    drawRoundRect(
        color = color,
        topLeft = Offset(w / 2, w / 2),
        size = Size(size.width - w, size.height - w),
        cornerRadius = CornerRadius(radius.toPx()),
        style = Stroke(width = w, pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 5.dp.toPx()))),
    )
}

/** A status dot. */
@Composable
fun Dot(color: Color, size: Dp = 8.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(color))
}
