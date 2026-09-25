package org.omarchy.flux.camera

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.IconBadge
import org.omarchy.flux.ui.Sym

/** The largest side of a still image that Flux reads. It keeps memory use low. */
internal const val MAX_STILL_SIDE = 2048

/** The camera permission of a mode. */
internal class CameraPermission(val granted: Boolean, val request: () -> Unit, val openSettings: () -> Unit)

/**
 * Asks for the camera when the mode opens, and checks again when the user
 * comes back from the system settings.
 */
@Composable
internal fun rememberCameraPermission(): CameraPermission {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    fun has() = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    var granted by remember { mutableStateOf(has()) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    LaunchedEffect(Unit) { if (!granted) ask.launch(Manifest.permission.CAMERA) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) granted = has() }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    return CameraPermission(granted, { ask.launch(Manifest.permission.CAMERA) }, { openAppSettings(context) })
}

internal fun openAppSettings(context: Context) {
    context.startActivity(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
    )
}

@Composable
internal fun CameraRationale(onAllow: () -> Unit, onSettings: () -> Unit, onPhoto: (() -> Unit)?, what: String = "scan text") {
    Column(
        Modifier.fillMaxSize().padding(horizontal = 32.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        IconBadge(Ic.camera, size = 72.dp)
        Text("Allow the camera to $what", style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
        Text(
            "Flux uses the camera only while this screen is open. Only what you send goes to the computer.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        FilledPill("Allow camera", onAllow, Ic.camera)
        OutlinedPill("Open app settings", onSettings, Ic.settings)
        if (onPhoto != null) OutlinedPill("From photo", onPhoto, Ic.gallery)
    }
}

/** The main action of a camera mode: a filled button with an optional icon. */
@Composable
internal fun FilledPill(label: String, onClick: () -> Unit, @DrawableRes icon: Int? = null) {
    Button(onClick = onClick, contentPadding = if (icon != null) ButtonDefaults.ButtonWithIconContentPadding else ButtonDefaults.ContentPadding) {
        PillContent(label, icon)
    }
}

/** A second action of a camera mode: an outlined button with an optional icon. */
@Composable
internal fun OutlinedPill(label: String, onClick: () -> Unit, @DrawableRes icon: Int? = null) {
    OutlinedButton(onClick = onClick, contentPadding = if (icon != null) ButtonDefaults.ButtonWithIconContentPadding else ButtonDefaults.ContentPadding) {
        PillContent(label, icon)
    }
}

@Composable
private fun PillContent(label: String, @DrawableRes icon: Int?) {
    if (icon != null) {
        Sym(icon, size = ButtonDefaults.IconSize)
        Spacer(Modifier.size(ButtonDefaults.IconSpacing))
    }
    Text(label, maxLines = 1)
}

/** The shutter button: a filled circle inside a ring. */
@Composable
internal fun Shutter(onClick: () -> Unit, busy: Boolean = false, description: String = "Take picture") {
    val scheme = MaterialTheme.colorScheme
    Box(
        Modifier.size(80.dp).clip(CircleShape).border(4.dp, scheme.primary, CircleShape)
            .clickable(onClickLabel = description, role = Role.Button, onClick = onClick).padding(8.dp)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.fillMaxSize().clip(CircleShape).background(if (busy) scheme.primaryContainer else scheme.primary))
    }
}

@Composable
internal fun Still(image: Bitmap?) {
    if (image == null) return
    Image(image.asImageBitmap(), contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
}

/** Decodes a photo upright, with its largest side at most [MAX_STILL_SIDE] pixels. */
internal fun decodeScaled(context: Context, uri: Uri): Bitmap =
    ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
        val w = info.size.width
        val h = info.size.height
        val scale = MAX_STILL_SIDE.toFloat() / maxOf(w, h)
        if (scale < 1f) decoder.setTargetSize((w * scale).toInt(), (h * scale).toInt())
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
    }
