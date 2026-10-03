package org.omarchy.flux.camera

import android.graphics.Bitmap
import android.net.Uri
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
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.graphics.scale
import androidx.lifecycle.compose.LocalLifecycleOwner
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Share
import org.omarchy.flux.ui.ButtonKind
import org.omarchy.flux.ui.ChoiceChip
import org.omarchy.flux.ui.FluxButton
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.Palette
import org.omarchy.flux.ui.Spinner
import org.omarchy.flux.ui.Sym
import org.omarchy.flux.ui.T

/** The largest side of the image that the ink comes from. */
private const val MAX_SIGNATURE_SIDE = 1600

/** The state of Signature mode. */
private sealed interface SignPhase {
    /** The camera preview runs with the guide frame. */
    data object Live : SignPhase

    /** The frame is frozen and the ink is cut out. */
    data class Working(val image: Bitmap?) : SignPhase

    /** The cut-out ink is ready to send. [ink] is null when the image has no ink. */
    data class Result(val ink: SignatureInk?) : SignPhase
}

/**
 * Signature mode: photographs a signature on paper, cuts out the ink, and
 * sends it as a transparent PNG. The computer puts it on the clipboard.
 * [onHolding] tells the Camera screen while the mode holds a capture or an
 * open photo picker.
 */
@Composable
fun SignatureMode(d: DeviceUi, strip: @Composable () -> Unit = {}, onHolding: (Boolean) -> Unit = {}) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()
    val permission = rememberCameraPermission()
    var phase by remember { mutableStateOf<SignPhase>(SignPhase.Live) }
    var color by rememberSaveable { mutableStateOf(InkColor.Black) }
    var sending by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }

    fun cut(image: Bitmap, crop: Crop?) {
        phase = SignPhase.Working(image)
        failure = null
        scope.launch {
            val ink = withContext(Dispatchers.Default) { runCatching { inkOf(image, crop) }.getOrNull() }
            phase = SignPhase.Result(ink)
        }
    }

    // True while the photo picker is open, so that a link drop does not lose the photo.
    var picking by rememberSaveable { mutableStateOf(false) }
    val pickPhoto = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        picking = false
        if (uri != null) {
            val image = runCatching { decodeScaled(context, uri) }.getOrNull()
            if (image == null) FluxCore.toast("Cannot open the photo") else cut(image, null)
        }
    }
    val choosePhoto = {
        picking = true
        pickPhoto.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
    }
    ReportHolding(phase != SignPhase.Live || picking, onHolding)

    val controller = remember {
        LifecycleCameraController(context).apply {
            setEnabledUseCases(LifecycleCameraController.IMAGE_CAPTURE)
            imageCaptureResolutionSelector = ResolutionSelector.Builder()
                .setResolutionStrategy(ResolutionStrategy(Size(2560, 1920), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
                .build()
        }
    }
    // True from the shutter until the photo is ready. An unbind stops a photo
    // that is not ready, so the camera and its preview stay until then.
    var shooting by remember { mutableStateOf(false) }
    val live = permission.granted && (phase == SignPhase.Live || shooting)
    DisposableEffect(live) {
        if (live) controller.bindToLifecycle(lifecycleOwner)
        onDispose { controller.unbind() }
    }

    var previewView by remember { mutableStateOf<PreviewView?>(null) }
    fun capture() {
        val view = previewView ?: return
        val frame = guideFrame(view.width.toFloat(), view.height.toFloat())
        val frozen = view.bitmap
        fun cropOf(image: Bitmap) = SignatureCut.frameInImage(
            frame.left, frame.top, frame.right, frame.bottom,
            view.width, view.height, image.width, image.height, pad = 0.05f,
        )
        shooting = true
        phase = SignPhase.Working(frozen)
        controller.takePicture(
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    shooting = false
                    val still = runCatching { upright(image) }.getOrNull()
                    image.close()
                    val source = still ?: frozen
                    if (source != null) cut(source, cropOf(source)) else phase = SignPhase.Live
                }

                override fun onError(exception: ImageCaptureException) {
                    shooting = false
                    // Fall back to the preview frame, which has a lower resolution.
                    if (frozen != null) {
                        cut(frozen, cropOf(frozen))
                    } else {
                        phase = SignPhase.Live
                        FluxCore.toast("Cannot take the photo")
                    }
                }
            },
        )
    }

    fun send(ink: SignatureInk) {
        if (sending) return
        sending = true
        failure = null
        val rgb = color.of(ink)
        scope.launch {
            val name = CaptureNames.signature()
            val file = withContext(Dispatchers.IO) {
                runCatching {
                    val dir = File(context.cacheDir, "signatures").apply { mkdirs() }
                    File(dir, name).also { f ->
                        val bitmap = Bitmap.createBitmap(ink.pixels(rgb), ink.width, ink.height, Bitmap.Config.ARGB_8888)
                        f.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    }
                }.getOrNull()
            }
            if (file == null) {
                sending = false
                failure = "Cannot save the signature"
                return@launch
            }
            Share.sendCapture(FluxCore, d.id, Uri.fromFile(file), name, mapOf("signature" to true)) { result ->
                ContextCompat.getMainExecutor(context).execute {
                    file.delete()
                    sending = false
                    if (result.isSuccess) {
                        FluxCore.toast("Copied to the clipboard on ${d.name}")
                        phase = SignPhase.Live
                    } else {
                        failure = result.exceptionOrNull()?.message ?: "Sending failed"
                    }
                }
            }
        }
    }

    if (!permission.granted && phase == SignPhase.Live) {
        CameraRationale(onAllow = permission.request, onSettings = permission.openSettings, onPhoto = choosePhoto, what = "capture a signature", strip = strip)
        return
    }
    Column(Modifier.fillMaxSize()) {
        Box(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
                .clip(RoundedCornerShape(28.dp)).background(Palette.pad),
            contentAlignment = Alignment.Center,
        ) {
            // The preview stays under the frozen frame until the photo is ready.
            if (live) {
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
            }
            when (val p = phase) {
                SignPhase.Live -> {
                    GuideFrame()
                    T(
                        "Sign with a dark pen. Fit the signature in the frame.",
                        Modifier.align(Alignment.TopCenter).padding(horizontal = 24.dp, vertical = 20.dp),
                        size = 13, color = Color.White, align = TextAlign.Center,
                    )
                }
                is SignPhase.Working -> {
                    Still(p.image)
                    Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.inverseSurface) {
                        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Spinner(Modifier.size(16.dp), color = MaterialTheme.colorScheme.inverseOnSurface)
                            Text("Finding the ink", color = MaterialTheme.colorScheme.inverseOnSurface)
                        }
                    }
                }
                is SignPhase.Result -> {
                    val ink = p.ink
                    if (ink == null) {
                        T(
                            "No ink found. Use a dark pen on white paper, and fill the frame.",
                            Modifier.padding(32.dp), color = Palette.secondary, align = TextAlign.Center,
                        )
                    } else {
                        SignaturePreview(ink, color)
                    }
                }
            }
        }
        when (val p = phase) {
            SignPhase.Live -> {
                strip()
                LiveControls(onPhoto = choosePhoto, onCapture = ::capture)
            }
            is SignPhase.Working -> Box(Modifier.fillMaxWidth().padding(24.dp))
            is SignPhase.Result -> ResultControls(
                d = d,
                ink = p.ink,
                color = color,
                onColor = { color = it },
                sending = sending,
                canSend = d.online,
                failure = failure,
                onRetake = {
                    failure = null
                    phase = SignPhase.Live
                },
                onSend = { p.ink?.let(::send) },
            )
        }
    }
}

/** The guide frame, 5 by 2, centered in the preview. It is 88 % of the width when the height allows it. */
private fun guideFrame(width: Float, height: Float): Rect {
    var w = width * 0.88f
    var h = w * 0.4f
    if (h > height * 0.6f) {
        h = height * 0.6f
        w = h * 2.5f
    }
    val left = (width - w) / 2
    val top = (height - h) / 2
    return Rect(left, top, left + w, top + h)
}

/** Dims the preview outside the guide frame, and draws the frame and a signature line. */
@Composable
private fun GuideFrame() {
    val accent = Palette.accent
    Canvas(Modifier.fillMaxSize()) {
        val frame = guideFrame(size.width, size.height)
        val corner = CornerRadius(16.dp.toPx())
        val outside = Path().apply {
            fillType = PathFillType.EvenOdd
            addRect(Rect(Offset.Zero, size))
            addRoundRect(RoundRect(frame, corner))
        }
        drawPath(outside, Color.Black.copy(alpha = 0.5f))
        drawRoundRect(accent, frame.topLeft, frame.size, corner, style = Stroke(2.dp.toPx()))
        val y = frame.top + frame.height * 0.75f
        drawLine(
            Color.White.copy(alpha = 0.6f),
            Offset(frame.left + frame.width * 0.08f, y),
            Offset(frame.right - frame.width * 0.08f, y),
            strokeWidth = 1.dp.toPx(),
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx())),
        )
    }
}

/** The signature on a light checkerboard, so that the ink and the transparent background both show. */
@Composable
private fun SignaturePreview(ink: SignatureInk, color: InkColor) {
    val image = remember(ink, color) {
        Bitmap.createBitmap(ink.pixels(color.of(ink)), ink.width, ink.height, Bitmap.Config.ARGB_8888).asImageBitmap()
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            drawRect(Color.White)
            val cell = 10.dp.toPx()
            val shade = Color(0xFFE4E4E4)
            var y = 0f
            var row = 0
            while (y < size.height) {
                var x = if (row % 2 == 0) 0f else cell
                while (x < size.width) {
                    drawRect(shade, Offset(x, y), androidx.compose.ui.geometry.Size(cell, cell))
                    x += cell * 2
                }
                y += cell
                row++
            }
        }
        Image(image, "The signature", Modifier.fillMaxSize().padding(20.dp), contentScale = ContentScale.Fit)
    }
}

@Composable
private fun LiveControls(onPhoto: () -> Unit, onCapture: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            FilledTonalIconButton(onClick = onPhoto, modifier = Modifier.size(52.dp)) { Sym(Ic.gallery, "From photo") }
        }
        Shutter(onCapture, description = "Capture the signature")
        Box(Modifier.weight(1f))
    }
}

@Composable
private fun ResultControls(
    d: DeviceUi,
    ink: SignatureInk?,
    color: InkColor,
    onColor: (InkColor) -> Unit,
    sending: Boolean,
    canSend: Boolean,
    failure: String?,
    onRetake: () -> Unit,
    onSend: () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (ink != null) {
            Row(Modifier.selectableGroup(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (c in InkColor.entries) {
                    ChoiceChip(
                        c.label, selected = c == color, onClick = { onColor(c) },
                        // The swatch shows the ink, a content color.
                        leading = { Box(Modifier.size(14.dp).clip(CircleShape).background(Color(0xFF000000 or c.of(ink).toLong()))) },
                    )
                }
            }
        }
        if (failure != null) T(failure, color = MaterialTheme.colorScheme.error, size = 13)
        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            FluxButton("Retake", onRetake, kind = ButtonKind.Outlined, icon = Ic.refresh)
            if (ink != null) FluxButton(if (sending) "Sending" else "Send to ${d.name}", onSend, icon = Ic.send, enabled = canSend, busy = sending)
        }
    }
}

/** Crops [image] to [crop], scales it down, and cuts out the ink. */
private fun inkOf(image: Bitmap, crop: Crop?): SignatureInk? {
    val part = if (crop == null) image else Bitmap.createBitmap(image, crop.left, crop.top, crop.width, crop.height)
    val side = maxOf(part.width, part.height)
    val scaled = if (side <= MAX_SIGNATURE_SIDE) {
        part
    } else {
        val s = MAX_SIGNATURE_SIDE.toFloat() / side
        part.scale(maxOf(1, (part.width * s).toInt()), maxOf(1, (part.height * s).toInt()))
    }
    val px = IntArray(scaled.width * scaled.height)
    scaled.getPixels(px, 0, scaled.width, 0, 0, scaled.width, scaled.height)
    return SignatureCut.extract(px, scaled.width, scaled.height)
}
