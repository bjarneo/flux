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
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.ui.GlyphBox
import org.omarchy.flux.ui.Palette
import org.omarchy.flux.ui.T

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
        Modifier.fillMaxSize().padding(horizontal = 28.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        GlyphBox("⌗")
        T("Allow the camera to $what", size = 20, align = TextAlign.Center)
        T(
            "Flux uses the camera only while this screen is open. Only what you send goes to the computer.",
            color = Palette.body, align = TextAlign.Center, lineHeight = 1.45f,
        )
        FilledPill("Allow camera", onAllow)
        OutlinedPill("Open app settings", onSettings)
        if (onPhoto != null) OutlinedPill("From photo", onPhoto)
    }
}

@Composable
internal fun FilledPill(label: String, onClick: () -> Unit) {
    Box(
        Modifier.clip(RoundedCornerShape(20.dp)).background(Palette.accent).clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 11.dp),
    ) { T(label, color = Palette.onAccent, weight = FontWeight.Medium, maxLines = 1) }
}

@Composable
internal fun OutlinedPill(label: String, onClick: () -> Unit) {
    Box(
        Modifier.clip(RoundedCornerShape(20.dp)).border(1.dp, Palette.borderStrong, RoundedCornerShape(20.dp))
            .clickable(onClick = onClick).padding(horizontal = 18.dp, vertical = 10.dp),
    ) { T(label, color = Palette.accent, weight = FontWeight.Medium, maxLines = 1) }
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
