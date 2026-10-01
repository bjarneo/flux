package org.omarchy.flux.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.ImageProxy
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.ui.ButtonKind
import org.omarchy.flux.ui.FluxButton
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.IconBadge
import org.omarchy.flux.ui.T
import org.omarchy.flux.ui.Tn
import org.omarchy.flux.ui.openAppSettings

/** The largest side of a still image that Flux reads. It keeps memory use low. */
internal const val MAX_STILL_SIDE = 2048

/**
 * Tells the Camera screen whether the mode holds work that a link drop
 * must not end: a capture, a send that runs, or a picker or a scanner
 * that is open. The screen then keeps the mode on the screen.
 */
@Composable
internal fun ReportHolding(holding: Boolean, onHolding: (Boolean) -> Unit) {
    val report by rememberUpdatedState(onHolding)
    SideEffect { report(holding) }
    DisposableEffect(Unit) { onDispose { report(false) } }
}

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

/**
 * The screen of a camera mode without the camera permission: what the
 * camera is for, Allow, the app settings, and an optional photo from the
 * gallery. [strip] holds the mode strip at the bottom, so the user can
 * change the mode.
 */
@Composable
internal fun CameraRationale(
    onAllow: () -> Unit,
    onSettings: () -> Unit,
    onPhoto: (() -> Unit)?,
    what: String = "scan text",
    strip: (@Composable () -> Unit)? = null,
) {
    Column(Modifier.fillMaxSize()) {
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 32.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            IconBadge(Ic.camera, size = 72.dp)
            T("Allow the camera to $what", size = 20, weight = FontWeight.SemiBold, align = TextAlign.Center)
            T(
                "Flux uses the camera only while this screen is open. Only what you send goes to the computer.",
                size = 14, color = Tn.sub, align = TextAlign.Center, lineHeight = 1.35f,
            )
            FluxButton("Allow camera", onAllow, icon = Ic.camera)
            FluxButton("Open app settings", onSettings, kind = ButtonKind.Outlined, icon = Ic.settings)
            if (onPhoto != null) FluxButton("From photo", onPhoto, kind = ButtonKind.Outlined, icon = Ic.gallery)
        }
        if (strip != null) {
            strip()
            Spacer(Modifier.height(16.dp))
        }
    }
}

/** The shutter button: a filled circle inside a ring. */
@Composable
internal fun Shutter(onClick: () -> Unit, busy: Boolean = false, description: String = "Take picture") {
    Box(
        Modifier.size(80.dp).clip(CircleShape).border(4.dp, Tn.blue, CircleShape)
            .clickable(enabled = !busy, onClickLabel = description, role = Role.Button, onClick = onClick).padding(8.dp)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.fillMaxSize().clip(CircleShape).background(if (busy) Tn.line else Tn.blue))
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

/** Returns the captured frame as an upright bitmap. */
internal fun upright(image: ImageProxy): Bitmap {
    val bitmap = image.toBitmap()
    val degrees = image.imageInfo.rotationDegrees
    if (degrees == 0) return bitmap
    val m = Matrix().apply { postRotate(degrees.toFloat()) }
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
}
