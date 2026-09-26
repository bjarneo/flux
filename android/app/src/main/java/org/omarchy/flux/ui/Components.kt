package org.omarchy.flux.ui

import androidx.annotation.DrawableRes
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

val Mono = FontFamily.Monospace

/** The side margin of every screen. List rows use the same margin. */
val Gutter = 16.dp

@Composable
fun T(
    text: String,
    modifier: Modifier = Modifier,
    size: Int = 14,
    color: Color = Palette.text,
    weight: FontWeight = FontWeight.Normal,
    family: FontFamily = FontFamily.Default,
    align: TextAlign? = null,
    maxLines: Int = Int.MAX_VALUE,
    letterSpacing: Float = 0f,
    lineHeight: Float = 0f,
) {
    BasicText(
        text = text,
        modifier = modifier,
        style = TextStyle(
            color = color,
            fontSize = size.sp,
            fontWeight = weight,
            fontFamily = family,
            textAlign = align ?: TextAlign.Unspecified,
            letterSpacing = letterSpacing.sp,
            lineHeight = if (lineHeight > 0) (size * lineHeight).sp else androidx.compose.ui.unit.TextUnit.Unspecified,
        ),
        maxLines = maxLines,
        overflow = if (maxLines == Int.MAX_VALUE) TextOverflow.Clip else TextOverflow.Ellipsis,
    )
}

/**
 * The top bar of an inner screen: a back button, the title with an
 * optional subtitle, and optional actions at the end.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TopBar(title: String, onBack: () -> Unit, subtitle: String? = null, trailing: @Composable RowScope.() -> Unit = {}) {
    TopAppBar(
        title = {
            Column {
                Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (!subtitle.isNullOrEmpty()) {
                    Text(
                        subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        },
        navigationIcon = { IconButton(onClick = onBack) { Sym(Ic.back, "Back") } },
        actions = trailing,
        // The root of the activity already pads for the system bars.
        windowInsets = WindowInsets(0),
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
    )
}

/**
 * A screen or a section with nothing to show: an icon, a title, a line
 * that says what to do, and an optional action.
 */
@Composable
fun EmptyState(
    @DrawableRes icon: Int,
    title: String,
    body: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null,
) {
    Column(
        modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        IconBadge(icon, size = 72.dp)
        Spacer(Modifier.height(4.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        Text(
            body,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        if (action != null) {
            Spacer(Modifier.height(4.dp))
            action()
        }
    }
}

/** A button with a leading icon, in the Material 3 filled style. */
@Composable
fun IconTextButton(@DrawableRes icon: Int, label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    Button(onClick = onClick, modifier = modifier, enabled = enabled, contentPadding = ButtonDefaults.ButtonWithIconContentPadding) {
        Sym(icon, size = ButtonDefaults.IconSize)
        Spacer(Modifier.size(ButtonDefaults.IconSpacing))
        Text(label)
    }
}

/** A confirmation dialog. [destructive] shows the confirm button in the error color. */
@Composable
fun ConfirmDialog(
    title: String,
    body: String,
    confirm: String,
    onCancel: () -> Unit,
    onConfirm: () -> Unit,
    @DrawableRes icon: Int? = null,
    destructive: Boolean = false,
) {
    AlertDialog(
        onDismissRequest = onCancel,
        icon = icon?.let { { Sym(it) } },
        title = { Text(title) },
        text = { Text(body) },
        confirmButton = {
            Button(
                onClick = onConfirm,
                colors = if (destructive) {
                    ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError)
                } else {
                    ButtonDefaults.buttonColors()
                },
            ) { Text(confirm) }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}

/** The full-screen Find my phone overlay. The ring icon pulses while the phone rings. */
@Composable
fun RingOverlay(from: String, onStop: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val pulse by rememberInfiniteTransition(label = "ring").animateFloat(
        initialValue = 1f,
        targetValue = 1.12f,
        animationSpec = infiniteRepeatable(tween(600), RepeatMode.Reverse),
        label = "pulse",
    )
    Box(
        Modifier.fillMaxSize().background(scheme.primary)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { },
    ) {
        Column(
            Modifier.fillMaxSize().systemBarsPadding().padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterVertically),
        ) {
            IconBadge(Ic.ring, Modifier.scale(pulse), container = scheme.onPrimary.copy(alpha = 0.16f), content = scheme.onPrimary, size = 120.dp)
            Spacer(Modifier.height(8.dp))
            Text("Find my phone", style = MaterialTheme.typography.titleMedium, color = scheme.onPrimary.copy(alpha = 0.8f))
            Text(
                "$from is ringing this phone",
                style = MaterialTheme.typography.headlineMedium,
                color = scheme.onPrimary,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(16.dp))
            Button(
                onClick = onStop,
                modifier = Modifier.height(64.dp),
                shape = CircleShape,
                colors = ButtonDefaults.buttonColors(containerColor = scheme.onPrimary, contentColor = scheme.primary),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 40.dp),
            ) {
                Sym(Ic.check)
                Spacer(Modifier.size(12.dp))
                Text("I found it", style = MaterialTheme.typography.titleMedium)
            }
        }
    }
}

/**
 * The Flux mark, Φ phi: a square ring with an accent bar through it. The
 * geometry uses a 16-unit box. The ring is 10 units wide at 3 units, with a
 * 2-unit stroke. The bar is 2 by 14 units at 7 and 1 units, over the ring.
 */
@Composable
fun FluxMark(size: Dp, fg: Color = Palette.text, accent: Color = Palette.accent) {
    androidx.compose.foundation.Canvas(Modifier.size(size)) {
        val u = this.size.minDimension / 16f
        // A stroke is centered on its path, so the path is 1 unit inside the outer edge.
        drawRect(
            fg,
            topLeft = Offset(4f * u, 4f * u),
            size = androidx.compose.ui.geometry.Size(8f * u, 8f * u),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2f * u),
        )
        drawRect(accent, topLeft = Offset(7f * u, 1f * u), size = androidx.compose.ui.geometry.Size(2f * u, 14f * u))
    }
}
