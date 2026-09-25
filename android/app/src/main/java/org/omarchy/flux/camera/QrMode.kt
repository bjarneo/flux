package org.omarchy.flux.camera

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.ImageAnalysis
import androidx.camera.mlkit.vision.MlKitAnalyzer
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Share
import org.omarchy.flux.ui.Palette
import org.omarchy.flux.ui.T

private sealed interface QrPhase {
    data object Live : QrPhase
    data class Found(val image: Bitmap?, val sheet: CodeSheet) : QrPhase
    data class Missing(val image: Bitmap?) : QrPhase
}

/** QR mode: reads QR codes and barcodes and sends the value to the computer. */
@Composable
fun QrMode(d: DeviceUi) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val permission = rememberCameraPermission()
    val scanner: BarcodeScanner = remember {
        BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_ALL_FORMATS).build())
    }
    DisposableEffect(Unit) { onDispose { scanner.close() } }

    var phase by remember { mutableStateOf<QrPhase>(QrPhase.Live) }
    var boxes by remember { mutableStateOf<List<android.graphics.Rect>>(emptyList()) }
    var previewView by remember { mutableStateOf<PreviewView?>(null) }

    fun found(image: Bitmap?, codes: List<Barcode>) {
        val code = codes.firstOrNull { !it.rawValue.isNullOrEmpty() }
        phase = if (code == null) QrPhase.Missing(image) else QrPhase.Found(image, Codes.sheet(code.toScanned(), d.name))
    }

    val pickPhoto = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        val image = runCatching { decodeScaled(context, uri) }.getOrNull()
        if (image == null) {
            FluxCore.toast("Cannot open the photo")
            return@rememberLauncherForActivityResult
        }
        scanner.process(InputImage.fromBitmap(image, 0))
            .addOnSuccessListener { found(image, it) }
            .addOnFailureListener { phase = QrPhase.Missing(image) }
    }
    val choosePhoto = { pickPhoto.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }

    val controller = remember { LifecycleCameraController(context).apply { setEnabledUseCases(LifecycleCameraController.IMAGE_ANALYSIS) } }
    val live = permission.granted && phase == QrPhase.Live
    DisposableEffect(live) {
        if (live) {
            val main = ContextCompat.getMainExecutor(context)
            controller.setImageAnalysisAnalyzer(
                main,
                MlKitAnalyzer(listOf(scanner), ImageAnalysis.COORDINATE_SYSTEM_VIEW_REFERENCED, main) { result ->
                    val codes = result.getValue(scanner).orEmpty()
                    boxes = codes.mapNotNull { it.boundingBox }
                    // Pause on the first code with a value, like a camera app.
                    if (phase == QrPhase.Live && codes.any { !it.rawValue.isNullOrEmpty() }) found(previewView?.bitmap, codes)
                },
            )
            controller.bindToLifecycle(lifecycleOwner)
        }
        onDispose {
            controller.clearImageAnalysisAnalyzer()
            controller.unbind()
            boxes = emptyList()
        }
    }

    if (!permission.granted && phase == QrPhase.Live) {
        CameraRationale(onAllow = permission.request, onSettings = permission.openSettings, onPhoto = choosePhoto, what = "scan codes")
        return
    }
    Column(Modifier.fillMaxSize()) {
        Box(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
                .clip(RoundedCornerShape(28.dp)).background(Palette.pad),
            contentAlignment = Alignment.Center,
        ) {
            when (val p = phase) {
                QrPhase.Live -> {
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
                    CodeBoxes(boxes)
                }
                is QrPhase.Found -> Still(p.image)
                is QrPhase.Missing -> Still(p.image)
            }
        }
        when (val p = phase) {
            QrPhase.Live -> Row(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 20.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                T("Point the camera at a code", color = Palette.secondary)
                OutlinedPill("From photo", choosePhoto)
            }
            is QrPhase.Found -> CodeSheetView(d, p.sheet) { phase = QrPhase.Live }
            is QrPhase.Missing -> Column(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                T("No code found in this image.", color = Palette.secondary)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) { FilledPill("Scan again") { phase = QrPhase.Live } }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CodeSheetView(d: DeviceUi, sheet: CodeSheet, onAgain: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)
            .clip(RoundedCornerShape(24.dp)).background(Palette.tile).padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        T(sheet.title, size = 13, color = Palette.accent, weight = FontWeight.Medium)
        SelectionContainer(Modifier.heightIn(max = 160.dp).verticalScroll(rememberScrollState())) {
            T(sheet.value, size = 16)
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            sheet.actions.forEachIndexed { i, action ->
                val send = {
                    val ok = Share.sendFields(FluxCore, d.id, action.body.fields())
                    FluxCore.toast(if (ok) "Sent to ${d.name}" else "Not connected")
                }
                if (i == 0) FilledPill(action.verb, send) else OutlinedPill(action.verb, send)
            }
        }
        Box(
            Modifier.clip(RoundedCornerShape(20.dp)).clickable(onClick = onAgain).padding(horizontal = 4.dp, vertical = 6.dp),
        ) { T("Scan again", color = Palette.accent, weight = FontWeight.Medium) }
    }
}

/** The outlines of the codes that the camera sees, in preview view pixels. */
@Composable
private fun CodeBoxes(boxes: List<android.graphics.Rect>) {
    val color = Palette.accent
    val stroke = with(LocalDensity.current) { 3.dp.toPx() }
    val corner = with(LocalDensity.current) { 6.dp.toPx() }
    Canvas(Modifier.fillMaxSize()) {
        for (b in boxes) {
            drawRoundRect(
                color,
                topLeft = Offset(b.left.toFloat(), b.top.toFloat()),
                size = Size(b.width().toFloat(), b.height().toFloat()),
                cornerRadius = CornerRadius(corner, corner),
                style = Stroke(width = stroke),
            )
        }
    }
}

/** Converts an ML Kit barcode to the model that [Codes] classifies. */
private fun Barcode.toScanned(): ScannedCode {
    val format = when (format) {
        Barcode.FORMAT_QR_CODE -> CodeFormat.QrCode
        Barcode.FORMAT_DATA_MATRIX -> CodeFormat.DataMatrix
        Barcode.FORMAT_PDF417 -> CodeFormat.Pdf417
        Barcode.FORMAT_AZTEC -> CodeFormat.Aztec
        Barcode.FORMAT_EAN_13 -> CodeFormat.Ean13
        Barcode.FORMAT_EAN_8 -> CodeFormat.Ean8
        Barcode.FORMAT_UPC_A -> CodeFormat.UpcA
        Barcode.FORMAT_UPC_E -> CodeFormat.UpcE
        Barcode.FORMAT_CODE_128 -> CodeFormat.Code128
        Barcode.FORMAT_CODE_39 -> CodeFormat.Code39
        Barcode.FORMAT_CODE_93 -> CodeFormat.Code93
        Barcode.FORMAT_CODABAR -> CodeFormat.Codabar
        Barcode.FORMAT_ITF -> CodeFormat.Itf
        else -> CodeFormat.Unknown
    }
    val raw = rawValue.orEmpty()
    return when (valueType) {
        Barcode.TYPE_URL -> ScannedCode(format, raw, url = url?.url ?: raw)
        Barcode.TYPE_WIFI -> ScannedCode(
            format, raw,
            wifi = WifiInfo(
                wifi?.ssid.orEmpty(),
                wifi?.password.orEmpty(),
                when (wifi?.encryptionType) {
                    Barcode.WiFi.TYPE_WPA -> "WPA"
                    Barcode.WiFi.TYPE_WEP -> "WEP"
                    Barcode.WiFi.TYPE_OPEN -> "open"
                    else -> ""
                },
            ),
        )
        Barcode.TYPE_CONTACT_INFO -> ScannedCode(
            format, raw,
            contact = ContactInfo(
                contactInfo?.name?.formattedName.orEmpty(),
                contactInfo?.phones?.mapNotNull { it.number }.orEmpty(),
                contactInfo?.emails?.mapNotNull { it.address }.orEmpty(),
                contactInfo?.organization.orEmpty(),
            ),
        )
        Barcode.TYPE_PRODUCT, Barcode.TYPE_ISBN -> ScannedCode(format, raw, product = true)
        else -> ScannedCode(format, raw)
    }
}
