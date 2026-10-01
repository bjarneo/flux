package org.omarchy.flux.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
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
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
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
    fit: Boolean = false,
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
        // A label that must fit its box, such as a key, shrinks at a large font size, to half its size at most.
        autoSize = if (fit) TextAutoSize.StepBased(minFontSize = (size * 0.5f).sp, maxFontSize = size.sp, stepSize = 0.5.sp) else null,
    )
}

/** Opens the Android settings of Flux, where the user can allow a permission that Android does not ask for again. */
fun openAppSettings(context: Context) {
    runCatching {
        context.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}

/**
 * A permission that the user refused: what it is for, and a button that
 * opens the app settings, where the user can allow it.
 */
@Composable
fun PermissionNotice(text: String, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    Column(modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        // TalkBack reads the notice when it shows.
        T(text, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, size = 13, color = Tn.red, lineHeight = 1.3f)
        FluxButton("Open app settings", { openAppSettings(context) }, Modifier.offset(x = (-12).dp), kind = ButtonKind.Text, icon = Ic.settings)
    }
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

/** A confirmation dialog. [destructive] shows the confirm button as a destructive button: a red outline and red text. */
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
        // The body scrolls when a large font size makes it taller than the dialog.
        text = { Text(body, Modifier.verticalScroll(rememberScrollState())) },
        confirmButton = { FluxButton(confirm, onConfirm, kind = if (destructive) ButtonKind.Destructive else ButtonKind.Filled) },
        dismissButton = { FluxButton("Cancel", onCancel, kind = ButtonKind.Text) },
    )
}

/** The command that deletes the approval key file on the computer. Only root can delete it. */
const val APPROVE_REMOVE_COMMAND = "sudo flux-cli approve remove"

/**
 * The question before an unpair. The command that deletes the key file on
 * the computer shows in a mono block with a copy key.
 */
@Composable
fun UnpairDialog(name: String, onCancel: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onCancel,
        icon = { Sym(Ic.unlink) },
        title = { Text("Unpair $name?") },
        text = {
            // The body scrolls when a large font size makes it taller than the dialog, so the command stays reachable.
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("This phone and $name stop connecting. This phone deletes its fingerprint approval key for $name. You can pair them again later.")
                Text(
                    "The key file on $name stays until you run this command there:",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                CommandBlock(APPROVE_REMOVE_COMMAND)
            }
        },
        confirmButton = { FluxButton("Unpair", onConfirm, kind = ButtonKind.Destructive) },
        dismissButton = { FluxButton("Cancel", onCancel, kind = ButtonKind.Text) },
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
            Text("Find my phone", style = MaterialTheme.typography.titleMedium, color = scheme.onPrimary)
            Text(
                "$from is ringing this phone",
                style = MaterialTheme.typography.headlineMedium,
                color = scheme.onPrimary,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(16.dp))
            Button(
                onClick = onStop,
                modifier = Modifier.heightIn(min = 64.dp),
                shape = TileShape,
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
 * The system splash screen shows the same mark, see
 * res/drawable/flux_splash_mark.xml.
 */
@Composable
fun FluxMark(size: Dp, fg: Color = Palette.text, accent: Color = Palette.accent) {
    Spacer(
        Modifier.size(size).drawWithCache {
            val u = this.size.minDimension / 16f
            // A stroke is centered on its path, so the path is 1 unit inside the outer edge.
            val stroke = Stroke(width = 2f * u)
            onDrawBehind {
                drawRect(fg, topLeft = Offset(4f * u, 4f * u), size = Size(8f * u, 8f * u), style = stroke)
                drawRect(accent, topLeft = Offset(7f * u, 1f * u), size = Size(2f * u, 14f * u))
            }
        },
    )
}
