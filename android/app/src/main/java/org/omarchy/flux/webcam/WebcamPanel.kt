package org.omarchy.flux.webcam

import android.graphics.SurfaceTexture
import android.view.TextureView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.camera.CameraRationale
import org.omarchy.flux.camera.rememberCameraPermission
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.ui.Mono
import org.omarchy.flux.ui.Palette
import org.omarchy.flux.ui.T

/**
 * The Webcam mode of the Camera screen. The phone camera becomes a webcam
 * named Flux Camera on the computer. The preview shows what the computer
 * gets.
 */
@Composable
fun WebcamPanel(deviceId: String) {
    val permission = rememberCameraPermission()
    if (!permission.granted) {
        CameraRationale(onAllow = permission.request, onSettings = permission.openSettings, onPhoto = null, what = "use this phone as a webcam")
        return
    }

    val context = LocalContext.current
    val controller = remember { WebcamController(context.applicationContext) }
    var front by rememberSaveable { mutableStateOf(false) }
    var resolution by rememberSaveable { mutableStateOf(Resolution.HD) }
    var rotation by rememberSaveable { mutableIntStateOf(0) }
    val status by WebcamSession.status.collectAsState()
    val cameraError by controller.cameraError.collectAsState()
    val pcName = remember(deviceId) { FluxCore.device(deviceId)?.identity?.deviceName ?: "the computer" }
    val currentFront by rememberUpdatedState(front)

    DisposableEffect(controller) { onDispose { controller.release() } }
    LaunchedEffect(front) { controller.startCamera(front) }
    LaunchedEffect(rotation) { controller.extraRotation = rotation }

    // The stream stops when the app goes to the background, and the camera
    // closes, so that other apps can use it.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> {
                    controller.stopLive()
                    controller.stopCamera()
                }
                Lifecycle.Event.ON_START -> controller.startCamera(currentFront)
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // The screen stays on while the phone streams.
    val view = LocalView.current
    DisposableEffect(status.active) {
        view.keepScreenOn = status.active
        onDispose { view.keepScreenOn = false }
    }

    Column(
        Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(24.dp)).background(Palette.pad),
        ) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    TextureView(ctx).apply {
                        surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                            override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) =
                                controller.attachPreview(texture, width, height, currentFront)

                            override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) =
                                controller.attachPreview(texture, width, height, currentFront)

                            override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
                                controller.detachPreview()
                                return true
                            }

                            override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = Unit
                        }
                    }
                },
                update = { tv ->
                    // A camera switch changes the preview mirror. Other
                    // recompositions keep the preview surface.
                    if (tv.tag != front) {
                        tv.tag = front
                        tv.surfaceTexture?.let { controller.attachPreview(it, tv.width, tv.height, front) }
                    }
                },
            )
            if (status.phase == WebcamSession.Phase.Live) {
                Box(
                    Modifier.align(Alignment.TopStart).padding(12.dp).clip(RoundedCornerShape(8.dp))
                        .background(MaterialTheme.colorScheme.error).padding(horizontal = 10.dp, vertical = 4.dp),
                ) { T("● LIVE", size = 12, color = MaterialTheme.colorScheme.onError, weight = FontWeight.Medium) }
            }
        }

        StatusLine(status, cameraError, pcName)

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Pill(if (front) "Back camera" else "Front camera", selected = false, enabled = true) { front = !front }
            Pill("Rotate", selected = false, enabled = true) { rotation = (rotation + 90) % 360 }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            T("Quality", color = Palette.secondary, size = 13)
            for (r in Resolution.entries) {
                Pill(r.label, selected = r == resolution, enabled = !status.active) { resolution = r }
            }
        }

        val active = status.active
        Box(
            Modifier.fillMaxWidth().height(64.dp).clip(RoundedCornerShape(32.dp))
                .background(if (active) MaterialTheme.colorScheme.errorContainer else Palette.accent)
                .clickable(enabled = cameraError == null || active) {
                    if (active) controller.stopLive() else controller.goLive(deviceId, resolution)
                },
            contentAlignment = Alignment.Center,
        ) {
            T(
                if (active) "Stop webcam" else "Start webcam",
                size = 18, weight = FontWeight.Medium,
                color = if (active) MaterialTheme.colorScheme.onErrorContainer else Palette.onAccent,
            )
        }
        T(
            "Apps on $pcName see this phone as Flux Camera. Keep this screen open while you stream.",
            color = Palette.hint, size = 12, align = TextAlign.Center, modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun StatusLine(status: WebcamSession.Status, cameraError: String?, pcName: String) {
    val error = MaterialTheme.colorScheme.error
    when {
        cameraError != null -> T(cameraError, color = error)
        status.phase == WebcamSession.Phase.Error -> T(status.message, color = error)
        status.phase == WebcamSession.Phase.Live -> Column {
            T(status.message, weight = FontWeight.Medium)
            if (status.device.isNotEmpty()) T(status.device, color = Palette.secondary, size = 12, family = Mono)
        }
        status.message.isNotEmpty() -> T(status.message, color = Palette.body)
        else -> T("Ready. Start to use this phone as a webcam on $pcName.", color = Palette.body)
    }
}

@Composable
private fun Pill(label: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(20.dp)
    val base = Modifier.clip(shape).alpha(if (enabled) 1f else 0.45f)
    val styled = if (selected) {
        base.background(Palette.accentContainer)
    } else {
        base.border(1.dp, Palette.borderStrong, shape)
    }
    Box(styled.clickable(enabled = enabled, onClick = onClick).padding(horizontal = 16.dp, vertical = 9.dp)) {
        T(label, color = if (selected) Palette.onAccentContainer else Palette.text, size = 14, maxLines = 1)
    }
}
