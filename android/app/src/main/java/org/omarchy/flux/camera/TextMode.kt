package org.omarchy.flux.camera

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import android.provider.Settings
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Share
import org.omarchy.flux.scan.MlKitTextReader
import org.omarchy.flux.scan.ScanBlock
import org.omarchy.flux.scan.TextAssembly
import org.omarchy.flux.scan.TextReader
import org.omarchy.flux.ui.Palette
import org.omarchy.flux.ui.T

/** The state of the scan screen. */
private sealed interface ScanPhase {
    /** The camera preview runs and shows the text boxes. */
    data object Live : ScanPhase

    /** The frame is frozen and recognition runs. */
    data class Reading(val image: Bitmap?) : ScanPhase

    /** The recognized text is ready to edit and send. */
    data class Result(val image: Bitmap?, val text: String) : ScanPhase
}

/** Text mode: reads text with the camera or from a photo and sends it to the computer. */
@Composable
fun TextMode(d: DeviceUi) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val reader: TextReader = remember { MlKitTextReader() }
    DisposableEffect(Unit) { onDispose { reader.close() } }

    fun hasCamera() = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    var granted by remember { mutableStateOf(hasCamera()) }
    val askCamera = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    LaunchedEffect(Unit) { if (!granted) askCamera.launch(Manifest.permission.CAMERA) }
    // The user can allow the camera in the system settings and come back.
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) granted = hasCamera() }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    var phase by remember { mutableStateOf<ScanPhase>(ScanPhase.Live) }
    var blocks by remember { mutableStateOf<List<ScanBlock>>(emptyList()) }

    fun readStill(image: Bitmap) {
        phase = ScanPhase.Reading(image)
        reader.read(image) { result ->
            val text = result.getOrNull()?.let { TextAssembly.assemble(it) } ?: ""
            if (result.isFailure) FluxCore.toast("Cannot read the image")
            phase = ScanPhase.Result(image, text)
        }
    }

    val pickPhoto = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) {
            val image = runCatching { decodeScaled(context, uri) }.getOrNull()
            if (image == null) FluxCore.toast("Cannot open the photo") else readStill(image)
        }
    }
    val choosePhoto = { pickPhoto.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }

    val controller = remember {
        LifecycleCameraController(context).apply {
            setEnabledUseCases(LifecycleCameraController.IMAGE_ANALYSIS or LifecycleCameraController.IMAGE_CAPTURE)
            imageCaptureResolutionSelector = ResolutionSelector.Builder()
                .setResolutionStrategy(ResolutionStrategy(Size(1920, 1440), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
                .build()
        }
    }
    val live = granted && phase == ScanPhase.Live
    DisposableEffect(live) {
        if (live) {
            val main = ContextCompat.getMainExecutor(context)
            controller.setImageAnalysisAnalyzer(main, reader.liveAnalyzer(main) { blocks = it })
            controller.bindToLifecycle(lifecycleOwner)
        }
        onDispose {
            controller.clearImageAnalysisAnalyzer()
            controller.unbind()
            blocks = emptyList()
        }
    }

    var previewView by remember { mutableStateOf<PreviewView?>(null) }
    fun capture() {
        val frozen = previewView?.bitmap
        phase = ScanPhase.Reading(frozen)
        controller.takePicture(
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    val still = runCatching { upright(image) }.getOrNull()
                    image.close()
                    if (still != null) readStill(still) else phase = ScanPhase.Result(frozen, "")
                }

                override fun onError(exception: ImageCaptureException) {
                    // Fall back to the preview frame, which has a lower resolution.
                    if (frozen != null) readStill(frozen) else phase = ScanPhase.Live
                }
            },
        )
    }

    Column(Modifier.fillMaxSize()) {
        if (!granted && phase == ScanPhase.Live) {
            CameraRationale(
                onAllow = { askCamera.launch(Manifest.permission.CAMERA) },
                onSettings = {
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                },
                onPhoto = choosePhoto,
            )
            return@Column
        }
        Box(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
                .clip(RoundedCornerShape(28.dp)).background(Palette.pad),
            contentAlignment = Alignment.Center,
        ) {
            when (val p = phase) {
                ScanPhase.Live -> {
                    AndroidView(
                        factory = { ctx ->
                            PreviewView(ctx).apply {
                                scaleType = PreviewView.ScaleType.FILL_CENTER
                                this.controller = controller
                                previewView = this
                            }
                        },
                        modifier = Modifier.fillMaxSize(),
                    )
                    TextBoxes(blocks)
                }
                is ScanPhase.Reading -> {
                    Still(p.image)
                    Box(Modifier.clip(RoundedCornerShape(20.dp)).background(Palette.snackbar).padding(horizontal = 16.dp, vertical = 10.dp)) {
                        T("Reading text…", color = Palette.snackbarText)
                    }
                }
                is ScanPhase.Result -> Still(p.image)
            }
        }
        when (val p = phase) {
            ScanPhase.Live -> LiveControls(onPhoto = choosePhoto, onCapture = ::capture)
            is ScanPhase.Reading -> Box(Modifier.fillMaxWidth().padding(24.dp))
            is ScanPhase.Result -> ResultControls(
                d = d,
                text = p.text,
                onText = { phase = p.copy(text = it) },
                onRetake = { phase = ScanPhase.Live },
                onSend = {
                    if (Share.sendScan(FluxCore, d.id, p.text)) {
                        FluxCore.toast("Sent to ${d.name}")
                        phase = ScanPhase.Live
                    } else {
                        FluxCore.toast("Not connected")
                    }
                },
            )
        }
    }
}

/** The outlines of the detected text blocks, in preview view pixels. */
@Composable
private fun TextBoxes(blocks: List<ScanBlock>) {
    val color = Palette.accent
    val stroke = with(LocalDensity.current) { 2.dp.toPx() }
    val corner = with(LocalDensity.current) { 4.dp.toPx() }
    Canvas(Modifier.fillMaxSize()) {
        for (b in blocks) {
            val box = b.box
            if (box.right <= box.left || box.bottom <= box.top) continue
            drawRoundRect(
                color,
                topLeft = Offset(box.left.toFloat(), box.top.toFloat()),
                size = androidx.compose.ui.geometry.Size((box.right - box.left).toFloat(), (box.bottom - box.top).toFloat()),
                cornerRadius = CornerRadius(corner, corner),
                style = Stroke(width = stroke),
            )
        }
    }
}

@Composable
private fun LiveControls(onPhoto: () -> Unit, onCapture: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) { OutlinedPill("From photo", onPhoto) }
        // The capture button: a filled circle inside a ring.
        Box(
            Modifier.size(80.dp).clip(CircleShape).border(4.dp, Palette.accent, CircleShape).clickable(onClick = onCapture).padding(8.dp),
            contentAlignment = Alignment.Center,
        ) { Box(Modifier.fillMaxSize().clip(CircleShape).background(Palette.accent)) }
        Box(Modifier.weight(1f))
    }
}

@Composable
private fun ResultControls(d: DeviceUi, text: String, onText: (String) -> Unit, onRetake: () -> Unit, onSend: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (text.isEmpty()) {
            T("No text found. Move closer or add light.", Modifier.fillMaxWidth().padding(vertical = 12.dp), color = Palette.secondary, align = TextAlign.Center)
        } else {
            OutlinedTextField(
                value = text,
                onValueChange = onText,
                modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp, max = 260.dp),
                minLines = 4,
            )
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
            OutlinedPill("Retake", onRetake)
            if (text.isNotBlank()) FilledPill("Send to ${d.name}", onSend)
        }
    }
}

/** Returns the captured frame as an upright bitmap. */
private fun upright(image: ImageProxy): Bitmap {
    val bitmap = image.toBitmap()
    val degrees = image.imageInfo.rotationDegrees
    if (degrees == 0) return bitmap
    val m = Matrix().apply { postRotate(degrees.toFloat()) }
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
}

