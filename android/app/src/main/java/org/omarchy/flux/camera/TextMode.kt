package org.omarchy.flux.camera

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
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
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
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
import org.omarchy.flux.ui.ButtonKind
import org.omarchy.flux.ui.FieldEditor
import org.omarchy.flux.ui.FieldKeys
import org.omarchy.flux.ui.FluxButton
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.Palette
import org.omarchy.flux.ui.Spinner
import org.omarchy.flux.ui.Sym
import org.omarchy.flux.ui.T
import org.omarchy.flux.ui.openAppSettings
import org.omarchy.flux.voice.DictationText
import org.omarchy.flux.voice.VoiceField
import org.omarchy.flux.voice.rememberVoiceTyping

/** The state of the scan screen. */
private sealed interface ScanPhase {
    /** The camera preview runs and shows the text boxes. */
    data object Live : ScanPhase

    /** The frame is frozen and recognition runs. */
    data class Reading(val image: Bitmap?) : ScanPhase

    /** The recognized text is ready to edit and send. */
    data class Result(val image: Bitmap?, val text: String) : ScanPhase
}

/**
 * Text mode: reads text with the camera or from a photo and sends it to the
 * computer. [strip] is the mode strip. [onHolding] tells the Camera screen
 * while the mode holds a scan or an open photo picker.
 */
@Composable
fun TextMode(d: DeviceUi, strip: @Composable () -> Unit = {}, onHolding: (Boolean) -> Unit = {}) {
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

    // True while the photo picker is open, so that a link drop does not lose the photo.
    var picking by rememberSaveable { mutableStateOf(false) }
    val pickPhoto = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        picking = false
        if (uri != null) {
            val image = runCatching { decodeScaled(context, uri) }.getOrNull()
            if (image == null) FluxCore.toast("Cannot open the photo") else readStill(image)
        }
    }
    val choosePhoto = {
        picking = true
        pickPhoto.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
    }
    ReportHolding(phase != ScanPhase.Live || picking, onHolding)

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
                onSettings = { openAppSettings(context) },
                onPhoto = choosePhoto,
                strip = strip,
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
                    Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.inverseSurface) {
                        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Spinner(Modifier.size(16.dp), color = MaterialTheme.colorScheme.inverseOnSurface)
                            Text("Reading text", color = MaterialTheme.colorScheme.inverseOnSurface)
                        }
                    }
                }
                is ScanPhase.Result -> Still(p.image)
            }
        }
        when (val p = phase) {
            ScanPhase.Live -> {
                strip()
                LiveControls(onPhoto = choosePhoto, onCapture = ::capture)
            }
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
        Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            FilledTonalIconButton(onClick = onPhoto, modifier = Modifier.size(52.dp)) { Sym(Ic.gallery, "From photo") }
        }
        Shutter(onCapture, description = "Scan text")
        Box(Modifier.weight(1f))
    }
}

/** The scanned text to edit and send. A dictation puts its words at the cursor. */
@Composable
private fun ResultControls(d: DeviceUi, text: String, onText: (String) -> Unit, onRetake: () -> Unit, onSend: () -> Unit) {
    // The field keeps the cursor. A new text puts the cursor at its end.
    var field by remember { mutableStateOf(TextFieldValue(text, TextRange(text.length))) }
    val value = if (field.text == text) field else TextFieldValue(text, TextRange(text.length))
    val voice = rememberVoiceTyping { spoken ->
        val e = DictationText.insert(value.text, value.selection.start, value.selection.end, spoken)
        field = TextFieldValue(e.text, TextRange(e.cursor))
        onText(e.text)
    }
    // After Clear, the empty field stays, so that the user can write or dictate the text.
    var cleared by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    fun change(v: TextFieldValue) {
        field = v
        onText(v.text)
    }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (text.isEmpty() && !cleared) {
            T("No text found. Move closer, or add light.", Modifier.fillMaxWidth().padding(vertical = 12.dp), color = Palette.secondary, align = TextAlign.Center)
        } else {
            VoiceField(voice) { m ->
                OutlinedTextField(
                    value = value,
                    onValueChange = ::change,
                    modifier = m.heightIn(min = 120.dp, max = 260.dp),
                    trailingIcon = {
                        FieldKeys(text.isNotEmpty(), {
                            cleared = true
                            change(TextFieldValue())
                        }, { editing = true })
                    },
                    minLines = 4,
                )
            }
        }
        if (editing) {
            FieldEditor("Scanned text", value, ::change, onDismiss = { editing = false }, context = d.name) {
                FluxButton("Send to ${d.name}", {
                    editing = false
                    onSend()
                }, icon = Ic.send, enabled = text.isNotBlank() && d.online)
            }
        }
        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            FluxButton("Retake", onRetake, kind = ButtonKind.Outlined, icon = Ic.refresh)
            if (text.isNotBlank()) FluxButton("Send to ${d.name}", onSend, icon = Ic.send, enabled = d.online)
        }
    }
}

