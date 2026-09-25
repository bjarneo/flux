package org.omarchy.flux.camera

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Share
import org.omarchy.flux.ui.GlyphBox
import org.omarchy.flux.ui.Palette
import org.omarchy.flux.ui.T

private const val NO_PLAY_SERVICES = "Document scan needs Google Play services, and this phone does not have them."

/**
 * Document mode: the Play services document scanner finds the page edges,
 * scans 1 or more pages, and gives a PDF. Flux sends the PDF to the computer.
 */
@Composable
fun DocumentMode(d: DeviceUi) {
    val context = LocalContext.current
    var status by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scanner = remember {
        GmsDocumentScanning.getClient(
            GmsDocumentScannerOptions.Builder()
                .setGalleryImportAllowed(true)
                .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_PDF)
                .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
                .build(),
        )
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { res ->
        if (res.resultCode != Activity.RESULT_OK) return@rememberLauncherForActivityResult
        val pdf = GmsDocumentScanningResult.fromActivityResultIntent(res.data)?.pdf ?: run {
            status = "The scanner returned no PDF"
            return@rememberLauncherForActivityResult
        }
        val name = CaptureNames.document()
        val pages = pdf.pageCount
        busy = true
        status = "Sending $name, ${pageLabel(pages)}…"
        Share.sendCapture(FluxCore, d.id, pdf.uri, name, mapOf("scan" to true)) { result ->
            ContextCompat.getMainExecutor(context).execute {
                busy = false
                status = if (result.isSuccess) {
                    FluxCore.toast("Sent to ${d.name}")
                    "Sent $name, ${pageLabel(pages)}, to ${d.name}"
                } else {
                    result.exceptionOrNull()?.message ?: "Sending failed"
                }
            }
        }
    }

    fun start() {
        val activity = context.findActivity()
        if (activity == null || GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) != ConnectionResult.SUCCESS) {
            status = NO_PLAY_SERVICES
            return
        }
        scanner.getStartScanIntent(activity)
            .addOnSuccessListener { launcher.launch(IntentSenderRequest.Builder(it).build()) }
            .addOnFailureListener { status = NO_PLAY_SERVICES + " " + (it.message ?: "") }
    }

    Column(
        Modifier.fillMaxSize().padding(horizontal = 28.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        GlyphBox("▤")
        T("Scan a document", size = 20, align = TextAlign.Center)
        T(
            "The scanner finds the page edges. You can add pages or import from the gallery. Flux sends 1 PDF to ${d.name}.",
            color = Palette.body, align = TextAlign.Center, lineHeight = 1.45f,
        )
        if (!busy) FilledPill("Scan document", ::start)
        status?.let { T(it, color = Palette.secondary, align = TextAlign.Center) }
    }
}

private fun pageLabel(n: Int) = if (n == 1) "1 page" else "$n pages"

private fun Context.findActivity(): Activity? {
    var c: Context? = this
    while (c is ContextWrapper) {
        if (c is Activity) return c
        c = c.baseContext
    }
    return null
}
