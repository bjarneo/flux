package org.omarchy.flux.camera

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Share
import org.omarchy.flux.ui.Palette
import org.omarchy.flux.ui.T
import java.io.File

/** The state of the last photo. */
private sealed interface PhotoStatus {
    data object None : PhotoStatus
    data object Saving : PhotoStatus
    data class Sending(val thumb: Bitmap?) : PhotoStatus
    data class Sent(val thumb: Bitmap?) : PhotoStatus
    data class Failed(val thumb: Bitmap?, val file: File, val name: String, val message: String) : PhotoStatus
}

/** Photo mode: takes a full-quality photo and sends it to the computer as a file. */
@Composable
fun PhotoMode(d: DeviceUi) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val permission = rememberCameraPermission()
    var lens by remember { mutableIntStateOf(CameraSelector.LENS_FACING_BACK) }
    var flash by remember { mutableIntStateOf(ImageCapture.FLASH_MODE_OFF) }
    var camera by remember { mutableStateOf<Camera?>(null) }
    var hasFront by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<PhotoStatus>(PhotoStatus.None) }
    val previewView = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }
    val capture = remember {
        ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
            .setJpegQuality(100)
            .setResolutionSelector(ResolutionSelector.Builder().setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY).build())
            .build()
    }
    LaunchedEffect(flash) { capture.flashMode = flash }

    DisposableEffect(permission.granted, lens) {
        var provider: ProcessCameraProvider? = null
        if (permission.granted) {
            val future = ProcessCameraProvider.getInstance(context)
            future.addListener({
                val p = runCatching { future.get() }.getOrNull() ?: return@addListener
                provider = p
                hasFront = runCatching { p.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) }.getOrDefault(false)
                val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
                val selector = CameraSelector.Builder().requireLensFacing(lens).build()
                p.unbindAll()
                camera = runCatching { p.bindToLifecycle(lifecycleOwner, selector, preview, capture) }
                    .onFailure { FluxCore.toast("Cannot open the camera") }
                    .getOrNull()
            }, ContextCompat.getMainExecutor(context))
        }
        onDispose {
            provider?.unbindAll()
            camera = null
        }
    }

    fun send(file: File, name: String, thumb: Bitmap?) {
        status = PhotoStatus.Sending(thumb)
        Share.sendCapture(FluxCore, d.id, Uri.fromFile(file), name, mapOf("photo" to true)) { result ->
            ContextCompat.getMainExecutor(context).execute {
                if (result.isSuccess) {
                    file.delete()
                    status = PhotoStatus.Sent(thumb)
                    FluxCore.toast("Sent to ${d.name}")
                } else {
                    val message = result.exceptionOrNull()?.message ?: "Sending failed"
                    status = PhotoStatus.Failed(thumb, file, name, message)
                    FluxCore.toast(message)
                }
            }
        }
    }

    fun shoot() {
        if (status == PhotoStatus.Saving || status is PhotoStatus.Sending) return
        val name = CaptureNames.photo()
        val dir = File(context.cacheDir, "photos").apply { mkdirs() }
        val file = File(dir, name)
        val metadata = ImageCapture.Metadata().apply { isReversedHorizontal = lens == CameraSelector.LENS_FACING_FRONT }
        status = PhotoStatus.Saving
        capture.takePicture(
            ImageCapture.OutputFileOptions.Builder(file).setMetadata(metadata).build(),
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    send(file, name, runCatching { thumbnail(file) }.getOrNull())
                }

                override fun onError(exception: ImageCaptureException) {
                    status = PhotoStatus.None
                    FluxCore.toast("Cannot take the photo")
                }
            },
        )
    }

    if (!permission.granted) {
        CameraRationale(onAllow = permission.request, onSettings = permission.openSettings, onPhoto = null, what = "take photos")
        return
    }
    Column(Modifier.fillMaxSize()) {
        Box(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
                .clip(RoundedCornerShape(28.dp)).background(Palette.pad),
        ) {
            AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
            Row(Modifier.align(Alignment.TopEnd).padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (camera?.cameraInfo?.hasFlashUnit() == true) {
                    Chip(flashLabel(flash)) { flash = nextFlash(flash) }
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) { LastPhoto(status) { s -> send(s.file, s.name, s.thumb) } }
            // The shutter button: a filled circle inside a ring.
            Box(
                Modifier.size(80.dp).clip(CircleShape).border(4.dp, Palette.accent, CircleShape).clickable(onClick = ::shoot).padding(8.dp),
                contentAlignment = Alignment.Center,
            ) {
                Box(Modifier.fillMaxSize().clip(CircleShape).background(if (status == PhotoStatus.Saving) Palette.accentContainer else Palette.accent))
            }
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                if (hasFront) {
                    Box(
                        Modifier.size(52.dp).clip(CircleShape).background(Palette.tile).clickable {
                            lens = if (lens == CameraSelector.LENS_FACING_BACK) CameraSelector.LENS_FACING_FRONT else CameraSelector.LENS_FACING_BACK
                        },
                        contentAlignment = Alignment.Center,
                    ) { T("⇄", size = 20) }
                }
            }
        }
    }
}

/** The thumbnail of the last photo with its send state. A failed photo sends again on tap. */
@Composable
private fun LastPhoto(status: PhotoStatus, onRetry: (PhotoStatus.Failed) -> Unit) {
    val (thumb, label) = when (status) {
        PhotoStatus.None -> return
        PhotoStatus.Saving -> null to "Saving…"
        is PhotoStatus.Sending -> status.thumb to "Sending…"
        is PhotoStatus.Sent -> status.thumb to "Sent"
        is PhotoStatus.Failed -> status.thumb to "Tap to send again"
    }
    Column(
        Modifier.clickable(enabled = status is PhotoStatus.Failed) { onRetry(status as PhotoStatus.Failed) },
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(Modifier.size(52.dp).clip(RoundedCornerShape(12.dp)).background(Palette.tile)) {
            if (thumb != null) Image(thumb.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        }
        T(label, size = 11, color = if (status is PhotoStatus.Failed) Palette.accent else Palette.secondary, maxLines = 1)
    }
}

@Composable
private fun Chip(label: String, onClick: () -> Unit) {
    Box(
        Modifier.clip(RoundedCornerShape(16.dp)).background(Palette.snackbar).clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 7.dp),
    ) { T(label, size = 13, color = Palette.snackbarText) }
}

private fun nextFlash(mode: Int): Int = when (mode) {
    ImageCapture.FLASH_MODE_OFF -> ImageCapture.FLASH_MODE_AUTO
    ImageCapture.FLASH_MODE_AUTO -> ImageCapture.FLASH_MODE_ON
    else -> ImageCapture.FLASH_MODE_OFF
}

private fun flashLabel(mode: Int): String = when (mode) {
    ImageCapture.FLASH_MODE_AUTO -> "Flash auto"
    ImageCapture.FLASH_MODE_ON -> "Flash on"
    else -> "Flash off"
}

/** Decodes a small upright thumbnail of the photo. */
private fun thumbnail(file: File): Bitmap =
    ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
        val scale = 256f / maxOf(info.size.width, info.size.height)
        if (scale < 1f) decoder.setTargetSize((info.size.width * scale).toInt(), (info.size.height * scale).toInt())
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
    }
