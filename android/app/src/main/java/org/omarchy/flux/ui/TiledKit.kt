package org.omarchy.flux.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.annotation.DrawableRes
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.graphics.takeOrElse
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.drawable.toDrawable
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.ThemeMode
import org.omarchy.flux.theme.PaletteSpec
import org.omarchy.flux.theme.TokyoNight
import org.omarchy.flux.theme.TokyoNightDay
import org.omarchy.flux.theme.paletteOf
import org.omarchy.flux.theme.resolvePalette

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

val TiledGutter = 10.dp

/** The alpha of a tile or a choice that takes no taps, for example while its computer is not reachable. */
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

// ───────────────────────── Components ─────────────────────────

/**
 * A tile. The border takes [accent] while pressed. A long press runs
 * [onLongClick], for example to unpair a computer. A tile that is not
 * [enabled] shows dimmed, takes no taps, and TalkBack reads it as
 * disabled. A tile with a [selected] value is 1 choice of a group:
 * TalkBack reads it as a radio button with its state.
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
    selected: Boolean? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val stroke = if (pressed && onClick != null) BorderStroke(1.dp, accent) else border
    var m = modifier.alpha(if (enabled) 1f else DimAlpha).clip(TileShape).background(container)
    if (stroke != null) m = m.border(stroke, TileShape)
    if (onClick != null) {
        if (selected != null) {
            val chosen: Boolean = selected
            m = m.semantics { this.selected = chosen }
        }
        m = m.combinedClickable(
            interactionSource = source,
            indication = LocalIndication.current,
            enabled = enabled,
            role = if (selected != null) Role.RadioButton else Role.Button,
            onLongClick = onLongClick,
            onClick = onClick,
        )
    }
    Column(m.padding(padding), verticalArrangement = verticalArrangement, horizontalAlignment = horizontalAlignment, content = content)
}

/** The fill of a choice. A selected choice takes the accent tile. The app has 1 selection color, the accent. */
@Composable
@ReadOnlyComposable
fun choiceFill(selected: Boolean): Color = if (selected) Tn.accentTile else Tn.tile

/** The border of a choice: 2 dp of the accent while selected, else the tile border. */
@Composable
@ReadOnlyComposable
fun choiceBorder(selected: Boolean): BorderStroke = if (selected) BorderStroke(2.dp, Tn.blue) else BorderStroke(1.dp, Tn.line)

/**
 * A choice of a small group, such as a player, a camera mode, or a
 * shape. It draws at least 40 dp high and takes taps on 48 dp. [role]
 * tells TalkBack the kind of choice, for example [Role.Tab] for a mode.
 * [leading] draws before the label, for example a color swatch. [inset]
 * is the space at the start and the end of the label.
 */
@Composable
fun ChoiceChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    mono: Boolean = false,
    role: Role = Role.RadioButton,
    inset: Dp = 12.dp,
    leading: (@Composable () -> Unit)? = null,
) {
    val shape = RoundedCornerShape(8.dp)
    val border = choiceBorder(selected)
    Row(
        modifier.minimumInteractiveComponentSize().heightIn(min = 40.dp).alpha(if (enabled) 1f else DimAlpha)
            .clip(shape).background(choiceFill(selected)).border(border, shape)
            .selectable(selected = selected, enabled = enabled, role = role, onClick = onClick)
            .padding(horizontal = inset, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        leading?.invoke()
        T(
            label, size = 13, color = if (selected) Tn.text else Tn.sub, weight = FontWeight.SemiBold,
            family = if (mono) Mono else FontFamily.Default, align = TextAlign.Center,
        )
    }
}

/** The kinds of [FluxButton]. */
enum class ButtonKind {
    /** The main action of a screen or a tile: the accent fill. */
    Filled,

    /** A second action that still needs weight, such as Stop or Done. */
    Tonal,

    /** A second action: an outline and the accent text. */
    Outlined,

    /** An action that deletes or ends something for good: a red outline and red text. */
    Destructive,

    /** A small action in a line of text, such as Retry. */
    Text,
}

/**
 * The button of the app, on the tile shape. It is at least 48 dp high,
 * and its label wraps at a large font size. [icon] draws before the
 * label. While [busy], a spinner replaces the icon and the button takes no
 * taps. [mono] sets the label in the mono family, for data such as a
 * monitor name.
 */
@Composable
fun FluxButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: ButtonKind = ButtonKind.Filled,
    @DrawableRes icon: Int? = null,
    enabled: Boolean = true,
    busy: Boolean = false,
    mono: Boolean = false,
) {
    val on = enabled && !busy
    val (fill, ink) = when (kind) {
        ButtonKind.Filled -> Tn.blue to Tn.onAccent
        ButtonKind.Tonal -> Tn.line to Tn.text
        ButtonKind.Outlined, ButtonKind.Text -> Color.Transparent to Tn.blue
        ButtonKind.Destructive -> Color.Transparent to Tn.red
    }
    val flat = kind == ButtonKind.Outlined || kind == ButtonKind.Text || kind == ButtonKind.Destructive
    // A busy button keeps its colors, so that its label stays legible. It takes no taps.
    val colors = ButtonDefaults.buttonColors(
        containerColor = fill, contentColor = ink,
        disabledContainerColor = if (busy) fill else if (flat) Color.Transparent else Tn.tile,
        disabledContentColor = if (busy) ink else Tn.dim,
    )
    val border = when (kind) {
        ButtonKind.Outlined -> BorderStroke(1.dp, if (on || busy) Tn.dim else Tn.line)
        ButtonKind.Destructive -> BorderStroke(1.dp, if (on || busy) Tn.red else Tn.line)
        else -> null
    }
    Button(
        onClick = onClick,
        modifier = modifier.heightIn(min = 48.dp),
        enabled = on,
        shape = TileShape,
        colors = colors,
        border = border,
        contentPadding = PaddingValues(horizontal = if (kind == ButtonKind.Text) 12.dp else 18.dp, vertical = 10.dp),
    ) {
        if (busy) {
            Spinner(Modifier.size(18.dp), color = LocalContentColor.current)
            Spacer(Modifier.size(8.dp))
        } else if (icon != null) {
            Sym(icon, size = 18.dp)
            Spacer(Modifier.size(8.dp))
        }
        Text(
            label,
            style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold, fontFamily = if (mono) Mono else FontFamily.Default),
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * The key at the end of a text field, such as Send or Run: 56 dp square on
 * the tile shape. [filled] draws it in the accent while it can send.
 * While [busy], a spinner shows and the key takes no taps.
 */
@Composable
fun FieldKey(
    description: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    busy: Boolean = false,
    filled: Boolean = true,
    content: @Composable () -> Unit,
) {
    val on = enabled && !busy
    val fill = filled && on
    Box(
        Modifier.size(56.dp).clip(TileShape).background(if (fill) Tn.blue else Tn.tile)
            .border(1.dp, if (fill) Tn.blue else Tn.line, TileShape)
            .clickable(enabled = on, onClickLabel = description, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        if (busy) {
            Spinner(Modifier.size(18.dp), color = Tn.blue)
        } else {
            // The content can be a text label, such as Enter, so a key that is off also uses the second ink, which reaches 4.5:1.
            // An off key has no accent fill, and TalkBack reads it as disabled.
            CompositionLocalProvider(LocalContentColor provides if (fill) Tn.onAccent else Tn.sub, content = content)
        }
    }
}

/**
 * Lines in the place of text that loads, such as the output of an agent.
 * TalkBack reads [description]. The lines pulse unless the Remove
 * animations setting is on.
 */
@Composable
fun LineSkeleton(
    description: String,
    modifier: Modifier = Modifier,
    lines: List<Float> = listOf(0.92f, 0.78f, 0.86f, 0.55f, 0.7f),
    color: Color = Tn.line,
) {
    val reduce = LocalReduceMotion.current
    val pulse = if (reduce) {
        null
    } else {
        rememberInfiniteTransition(label = "skeleton").animateFloat(
            1f, 0.45f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "skeletonAlpha",
        )
    }
    Column(
        modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = description }
            .graphicsLayer { alpha = pulse?.value ?: 1f },
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        for (f in lines) Box(Modifier.fillMaxWidth(f).height(12.dp).clip(RoundedCornerShape(3.dp)).background(color))
    }
}

/**
 * A bottom sheet of the app. It opens in full, and Back or a tap on the
 * scrim closes it. The pairing sheet is not a [FluxSheet], see
 * [TiledPairSheet].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FluxSheet(onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheet,
        shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
        containerColor = Tn.bg,
        contentColor = Tn.text,
        dragHandle = { BottomSheetDefaults.DragHandle(color = Tn.dim) },
        content = content,
    )
}

/** A command to run on a computer, in mono, with a key that copies it. */
@Composable
fun CommandBlock(command: String, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(Tn.offTile).border(1.dp, Tn.line, RoundedCornerShape(8.dp))
            .padding(start = 12.dp, end = 2.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        SelectionContainer(Modifier.weight(1f).padding(vertical = 10.dp)) {
            T(command, size = 13, color = Tn.text, family = Mono, lineHeight = 1.3f)
        }
        IconButton(onClick = { if (Android.setClipboard(context, command)) FluxCore.toast("Copied") }) {
            Sym(Ic.copy, "Copy the command", tint = Tn.blue, size = 20.dp)
        }
    }
}

/** A key of a key bar or a keyboard. The label shrinks to fit the key at a large font size. */
@Composable
fun KeyLabel(text: String, color: Color, size: Int = 12, family: FontFamily = Mono) {
    T(text, size = size, color = color, weight = FontWeight.SemiBold, family = family, maxLines = 1, fit = true)
}

/** A row of keys with the same height, at least 48 dp, and the grid gap of 8 dp between the keys. */
@Composable
fun KeyRow(modifier: Modifier = Modifier, gap: Dp = TileGap, content: @Composable RowScope.() -> Unit) {
    Row(
        modifier.fillMaxWidth().heightIn(min = 48.dp).height(IntrinsicSize.Min),
        horizontalArrangement = Arrangement.spacedBy(gap),
        content = content,
    )
}

/**
 * The label of a value or a group in a tile, in the body face and as
 * written. Write the text in sentence case. It wraps at a large font size.
 */
@Composable
fun TileLabel(text: String, modifier: Modifier = Modifier, color: Color = Tn.sub, maxLines: Int = Int.MAX_VALUE) {
    T(text, modifier, size = 12, color = color, weight = FontWeight.Medium, lineHeight = 1.35f, maxLines = maxLines)
}

/** The heading of a group of tiles, in the Material 3 Title Small style. Write the text in sentence case. TalkBack reads it as a heading. */
@Composable
fun SectionLabel(text: String) {
    Text(
        text,
        Modifier.padding(start = 4.dp, top = 20.dp, bottom = 8.dp).semantics { heading() },
        color = Tn.text,
        style = MaterialTheme.typography.titleSmall,
    )
}

/** A row of tiles with the grid gap. The tiles take the same height, at least [minHeight], and grow with the font size. */
@Composable
fun TileRow(minHeight: Dp, modifier: Modifier = Modifier, gap: Dp = TileGap, content: @Composable RowScope.() -> Unit) {
    Row(
        modifier.fillMaxWidth().heightIn(min = minHeight).height(IntrinsicSize.Min),
        horizontalArrangement = Arrangement.spacedBy(gap),
        content = content,
    )
}

/** The largest width of the content of a screen. A wider window, such as a tablet, shows the content in the center. */
val ContentMaxWidth = 840.dp

/**
 * The scroll column of a screen. The scroll area fills the window, so that
 * a drag at the side of the content also scrolls. The content is at most
 * [ContentMaxWidth] wide and stays in the center, with the gutter at the
 * sides and [bottom] of space after the last item.
 */
@Composable
fun CappedScrollColumn(modifier: Modifier = Modifier, bottom: Dp = 24.dp, content: @Composable ColumnScope.() -> Unit) {
    Box(modifier.fillMaxSize().verticalScroll(rememberScrollState()), contentAlignment = Alignment.TopCenter) {
        Column(
            Modifier.widthIn(max = ContentMaxWidth).fillMaxWidth().padding(horizontal = TiledGutter).padding(bottom = bottom),
            content = content,
        )
    }
}

// ───────────────────────── Tools ─────────────────────────

/** The tint of the icon of a tool. All tools use the accent, and a tool that is off uses the second ink. */
@Composable
@ReadOnlyComposable
private fun toolTint(enabled: Boolean): Color = if (enabled) Tn.blue else Tn.sub

/**
 * The tool that a destination uses most, such as Send clipboard: the
 * master tile above the other tools. It is taller than a [ToolRow], and
 * its fill stands out. A tool that is not [enabled] shows dimmed, takes no
 * taps, and TalkBack reads it as disabled.
 */
@Composable
fun MasterTool(@DrawableRes icon: Int, label: String, sub: String?, enabled: Boolean, onClick: () -> Unit) {
    Tile(
        Modifier.fillMaxWidth().heightIn(min = 128.dp),
        onClick = onClick,
        container = Tn.tileHi,
        border = BorderStroke(1.dp, Tn.lineHi),
        enabled = enabled,
        padding = PaddingValues(18.dp),
    ) {
        // The icon stays at the top and the text at the bottom. At a large font size, the tile grows and keeps the gap.
        Sym(icon, modifier = Modifier.padding(bottom = 16.dp), tint = toolTint(enabled), size = 28.dp)
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            T(label, size = 20, weight = FontWeight.SemiBold, lineHeight = 1.2f)
            if (sub != null) T(sub, size = 14, color = Tn.sub, lineHeight = 1.3f)
        }
    }
}

/**
 * A tool under the master tile: a compact row with the icon, the label,
 * and an optional line under the label. The rows of a group stack with the
 * tile gap. A [badge] above 0 shows the number of items that need the
 * user. A tool that is not [enabled] shows dimmed, takes no taps, and
 * TalkBack reads it as disabled.
 */
@Composable
fun ToolRow(@DrawableRes icon: Int, label: String, sub: String?, enabled: Boolean, badge: Int = 0, onClick: () -> Unit) {
    Tile(
        Modifier.fillMaxWidth().heightIn(min = 56.dp),
        onClick = onClick,
        enabled = enabled,
        padding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(icon, tint = toolTint(enabled), size = 22.dp)
            // The text wraps with no limit. At a large font size, the row grows.
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(label, size = 15, weight = FontWeight.SemiBold)
                if (sub != null) T(sub, size = 13, color = Tn.sub, lineHeight = 1.3f)
            }
            if (badge > 0) {
                val description = if (badge == 1) "1 needs you" else "$badge need you"
                T(
                    if (badge > 9) "9+" else "$badge",
                    Modifier.clip(RoundedCornerShape(8.dp)).background(Tn.red).padding(horizontal = 7.dp, vertical = 1.dp)
                        .clearAndSetSemantics { contentDescription = description },
                    size = 12, color = Tn.onAccent, weight = FontWeight.Bold, family = Mono,
                )
            }
        }
    }
}

/**
 * A square button with an icon, for top bars: a 40 dp tile that takes
 * taps on 48 dp. TalkBack reads [description].
 */
@Composable
fun SquareButton(@DrawableRes icon: Int, description: String, onClick: () -> Unit, enabled: Boolean = true) {
    FilledTonalIconButton(
        onClick = onClick,
        enabled = enabled,
        shape = RoundedCornerShape(8.dp),
        colors = IconButtonDefaults.filledTonalIconButtonColors(
            containerColor = Tn.tile, contentColor = Tn.text, disabledContainerColor = Tn.tile, disabledContentColor = Tn.dim,
        ),
    ) { Sym(icon, description, size = 20.dp) }
}

/**
 * A spinner for work that runs. With Remove animations on, Android stops
 * the animation at its first frame, which draws only a dot. The spinner
 * then shows a fixed ring of 3 quarters.
 */
@Composable
fun Spinner(modifier: Modifier = Modifier, color: Color = Tn.blue, strokeWidth: Dp = 2.dp) {
    if (LocalReduceMotion.current) {
        CircularProgressIndicator(progress = { 0.75f }, modifier = modifier, color = color, strokeWidth = strokeWidth, trackColor = Color.Transparent)
    } else {
        CircularProgressIndicator(modifier, color = color, strokeWidth = strokeWidth)
    }
}

/** A spinner in the place of a [SquareButton], for a read that runs. */
@Composable
fun SquareSpinner(description: String) {
    Box(
        Modifier.size(48.dp).semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { Spinner(Modifier.size(18.dp), color = Tn.blue) }
}

/**
 * The top bar of every screen above a destination: a back button, the
 * [title], and an optional [context] line in mono, such as the computer.
 * [trailing] holds the actions of the screen. The title is a heading for
 * TalkBack, and both lines wrap at a large font size. When the actions
 * leave the title less width than its longest word, the actions move to a
 * second row under the title, so that no word breaks.
 */
@Composable
fun TiledTopBar(title: String, onBack: () -> Unit, context: String? = null, trailing: @Composable RowScope.() -> Unit = {}) {
    Layout(
        contents = listOf(
            { SquareButton(Ic.back, "Back", onBack) },
            {
                Column(Modifier.padding(start = 2.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    T(title, Modifier.semantics { heading() }, size = 18, weight = FontWeight.SemiBold, lineHeight = 1.2f)
                    if (!context.isNullOrEmpty()) T(context, size = 12, color = Tn.sub, family = Mono)
                }
            },
            { Row(horizontalArrangement = Arrangement.spacedBy(TileGap), verticalAlignment = Alignment.CenterVertically, content = trailing) },
        ),
        modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(top = 4.dp, bottom = 8.dp),
    ) { (backSlot, titleSlot, actionSlot), constraints ->
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        val gap = TileGap.roundToPx()
        val back = backSlot.first().measure(loose)
        val actions = actionSlot.first().measure(loose)
        val titleItem = titleSlot.first()
        val start = back.width + gap
        val end = if (actions.width > 0) actions.width + gap else 0
        val width = if (constraints.hasBoundedWidth) constraints.maxWidth else start + titleItem.maxIntrinsicWidth(Constraints.Infinity) + end
        val inlineWidth = (width - start - end).coerceAtLeast(0)
        // The minimum intrinsic width of the title is the width of its longest word.
        val inline = actions.width == 0 || titleItem.minIntrinsicWidth(Constraints.Infinity) <= inlineWidth
        val titleWidth = if (inline) inlineWidth else (width - start).coerceAtLeast(0)
        val titleBlock = titleItem.measure(Constraints(minWidth = titleWidth, maxWidth = titleWidth))
        val firstRow = maxOf(back.height, titleBlock.height, if (inline) actions.height else 0)
        val secondRow = if (inline) 0 else gap + actions.height
        val height = (firstRow + secondRow).coerceIn(constraints.minHeight, constraints.maxHeight)
        layout(width, height) {
            val top = if (inline) (height - firstRow) / 2 else 0
            back.placeRelative(0, top + (firstRow - back.height) / 2)
            titleBlock.placeRelative(start, top + (firstRow - titleBlock.height) / 2)
            val actionsTop = if (inline) top + (firstRow - actions.height) / 2 else firstRow + gap
            actions.placeRelative(width - actions.width, actionsTop)
        }
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
