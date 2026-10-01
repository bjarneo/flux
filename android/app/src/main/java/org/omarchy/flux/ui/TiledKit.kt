package org.omarchy.flux.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
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
import androidx.compose.ui.geometry.center
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.LinearGradientShader
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shader
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.graphics.takeOrElse
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toDrawable
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.ThemeMode
import org.omarchy.flux.theme.PaletteSpec
import org.omarchy.flux.theme.TokyoNight
import org.omarchy.flux.theme.TokyoNightDay
import org.omarchy.flux.theme.paletteOf
import org.omarchy.flux.theme.resolvePalette
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * The Tiled design: the colors of the Omarchy theme of the computer, 12 dp
 * tiles with 8 dp gaps, and an active-window gradient border like
 * Hyprland on Omarchy. [Tn] gives the colors of the current theme. The
 * palettes come from [PaletteSpec] through the contrast guard, see
 * [paletteOf], so each pair below reaches WCAG 2.2 AA.
 *
 * The contrast contract, see [PaletteSpec]:
 * - [text] and [sub] reach 4.5:1 on [bg], [offTile], [tile], [tileHi],
 *   [line], and [accentTile].
 * - [blue], [cyan], [green], [magenta], [orange], [red], and [yellow]
 *   reach 4.5:1 as text on the same colors except [line]. On [line], they
 *   reach 3:1, so use them there for icons and borders only.
 * - [onAccent] reaches 4.5:1 on a fill of each of these colors.
 * - [dim] reaches 3:1, for borders, icons, and disabled states. It is not
 *   for text.
 */
@Immutable
class TiledColors(
    val dark: Boolean,
    /** The page. */
    val bg: Color,
    val tile: Color,
    /** A tile that stands out, a menu, or a dialog. */
    val tileHi: Color,
    /** A tile that is off, and the background of the agent output. */
    val offTile: Color,
    /** The border of a tile, and a tonal container for [text] and [sub]. */
    val line: Color,
    val lineHi: Color,
    /** The body ink. */
    val text: Color,
    /** The second ink, for hints, labels, placeholders, and data that is not the main value. */
    val sub: Color,
    /**
     * For borders, icons, and disabled states only, never for text that
     * carries meaning. It reaches 3:1 on [bg], [tile], and [tileHi].
     */
    val dim: Color,
    /** The text and icons on an accent fill or a fill of a semantic color. */
    val onAccent: Color,
    /**
     * The primary color, for actions and selection. On Tokyo Night it is
     * blue. On another theme it is the accent of that theme, or the blue
     * of that theme when its accent looks like [red]. [accent] is the same
     * color. For the blue of the terminal, use [termBlue].
     */
    val blue: Color,
    val cyan: Color,
    val green: Color,
    val magenta: Color,
    val orange: Color,
    /** Red means "needs you" or an error, nothing else. */
    val red: Color,
    val yellow: Color,
    /** A tile with the hue of the accent and the luminance of [tileHi], for a selected item. */
    val accentTile: Color = tileHi,
    /** The colors of the active border gradient, from the hyprland_active_border of the theme. */
    val border: List<Color> = listOf(blue, cyan),
    /** The angle of [border] in degrees, as in Hyprland, or null for corner to corner. */
    val borderAngle: Float? = null,
    /** The blue of the theme for ANSI blue in the terminal output. It reaches 4.5:1 on [bg], [offTile], [tile], and [tileHi]. */
    val termBlue: Color = blue,
) {
    /** The primary color, the same color as [blue]. */
    val accent: Color get() = blue
}

private fun rgb(c: Int) = Color(0xFF000000.toInt() or c)

/** Turns a palette into the Tiled colors. */
fun PaletteSpec.toTiledColors() = TiledColors(
    dark = dark,
    bg = rgb(bg), tile = rgb(tile), tileHi = rgb(tileHi), offTile = rgb(offTile),
    line = rgb(line), lineHi = rgb(lineHi),
    text = rgb(text), sub = rgb(sub), dim = rgb(dim), onAccent = rgb(onAccent),
    blue = rgb(accent), cyan = rgb(cyan), green = rgb(green), magenta = rgb(magenta),
    orange = rgb(orange), red = rgb(red), yellow = rgb(yellow),
    accentTile = rgb(accentTile),
    border = border.map(::rgb),
    borderAngle = borderAngle,
    termBlue = rgb(termBlue),
)

/** Tokyo Night, the theme without a computer theme in the dark mode. */
private val TiledDark = TokyoNight.toTiledColors()

/** Tokyo Night Day, the theme without a computer theme in the light mode. */
private val TiledLight = TokyoNightDay.toTiledColors()

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

/**
 * The active border of the master tile, 2 dp wide. Without colors, it is
 * the hyprland_active_border gradient of the theme at its angle. Without a
 * theme border, it goes from the accent to cyan, corner to corner.
 */
@Composable
@ReadOnlyComposable
fun activeBorder(from: Color = Color.Unspecified, to: Color = Color.Unspecified): BorderStroke =
    if (from.isSpecified || to.isSpecified) {
        BorderStroke(2.dp, Brush.linearGradient(listOf(from.takeOrElse { Tn.blue }, to.takeOrElse { Tn.cyan })))
    } else {
        BorderStroke(2.dp, activeBorderBrush())
    }

/** The brush of the active border of the theme, for a custom outline. */
@Composable
@ReadOnlyComposable
fun activeBorderBrush(): Brush = borderBrush(Tn.border, Tn.borderAngle)

/**
 * A gradient of [colors] at [angle] degrees: 0 goes from left to right and
 * 90 from top to bottom, as in Hyprland. A null angle goes from the top
 * left corner to the bottom right corner.
 */
fun borderBrush(colors: List<Color>, angle: Float?): Brush = when {
    colors.isEmpty() -> SolidColor(Color.Transparent)
    colors.size == 1 -> SolidColor(colors[0])
    angle == null -> Brush.linearGradient(colors)
    else -> AngleGradient(colors, angle)
}

/** A linear gradient at an angle that spans the whole box. */
private class AngleGradient(private val colors: List<Color>, private val angle: Float) : ShaderBrush() {
    override fun createShader(size: Size): Shader {
        val rad = Math.toRadians(angle.toDouble())
        val dx = cos(rad).toFloat()
        val dy = sin(rad).toFloat()
        val half = (abs(size.width * dx) + abs(size.height * dy)) / 2f
        val c = size.center
        return LinearGradientShader(Offset(c.x - dx * half, c.y - dy * half), Offset(c.x + dx * half, c.y + dy * half), colors)
    }

    override fun equals(other: Any?) = other is AngleGradient && other.colors == colors && other.angle == angle
    override fun hashCode() = 31 * colors.hashCode() + angle.hashCode()
}

/**
 * The theme of the app. [ThemeMode.Computer], the default, follows the
 * Omarchy theme of the computer in scope, see
 * [org.omarchy.flux.core.ComputerThemes]. Without a
 * computer theme, and with [ThemeMode.System], it follows the phone:
 * Tokyo Night in the dark theme and Tokyo Night Day in the light theme.
 * Material parts, such as menus, sliders, dialogs, and the camera and mic
 * screens, take the same colors as the tiles. The system bars and the
 * window background follow the palette.
 */
@Composable
fun TiledTheme(content: @Composable () -> Unit) {
    val state = FluxCore.state.collectAsStateWithLifecycle().value
    val spec = resolvePalette(state.theme, state.computerTheme?.palette, isSystemInDarkTheme())
    val colors = remember(spec) {
        when (spec) {
            TokyoNight -> TiledDark
            TokyoNightDay -> TiledLight
            else -> spec.toTiledColors()
        }
    }
    val scheme = remember(colors) { colors.scheme() }
    // The system bars are transparent, so their icons take the color of the theme.
    val view = LocalView.current
    DisposableEffect(view, colors) {
        view.context.findActivity()?.let { activity ->
            val window = activity.window
            WindowCompat.getInsetsController(window, view).run {
                isAppearanceLightStatusBars = !colors.dark
                isAppearanceLightNavigationBars = !colors.dark
            }
            // The window shows behind Compose, for example during a resize. A translucent window stays clear.
            if (!activity.translucent()) window.setBackgroundDrawable(colors.bg.toArgb().toDrawable())
        }
        onDispose { }
    }
    CompositionLocalProvider(LocalTiledColors provides colors) {
        MaterialTheme(colorScheme = scheme) {
            CompositionLocalProvider(LocalContentColor provides colors.text, content = content)
        }
    }
}

private fun Context.findActivity(): Activity? {
    var c: Context? = this
    while (c is ContextWrapper) {
        if (c is Activity) return c
        c = c.baseContext
    }
    return null
}

/** True when the theme of the activity makes its window translucent. */
private fun Activity.translucent(): Boolean {
    val a = obtainStyledAttributes(intArrayOf(android.R.attr.windowIsTranslucent))
    return try {
        a.getBoolean(0, false)
    } finally {
        a.recycle()
    }
}

/** The Material 3 color scheme of the tiles. */
private fun TiledColors.scheme(): ColorScheme = (if (dark) darkColorScheme() else lightColorScheme()).copy(
    primary = blue, onPrimary = onAccent,
    primaryContainer = accentTile, onPrimaryContainer = text,
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
            if (trailing != null) T(trailing, size = 11, color = Tn.sub, family = Mono)
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
fun TileLabel(text: String, modifier: Modifier = Modifier, color: Color = Tn.sub) {
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
        T(label, Modifier.weight(1f), size = 12, color = Tn.sub, weight = FontWeight.Medium, family = Mono, maxLines = 1)
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
