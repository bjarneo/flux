package org.omarchy.flux.camera

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
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
import org.omarchy.flux.ui.ButtonKind
import org.omarchy.flux.ui.FluxButton
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.IconBadge
import org.omarchy.flux.ui.T
import org.omarchy.flux.ui.Tn

private const val NO_PLAY_SERVICES = "Document scan needs Google Play services, and this phone does not have them."

/** A scanned PDF that did not go out. Send again sends it. */
private class PendingPdf(val uri: Uri, val name: String, val pages: Int)

/**
 * Document mode: the Play services document scanner finds the page edges,
 * scans 1 or more pages, and gives a PDF. Flux sends the PDF to the computer.
 * A PDF that did not go out stays, and Send again sends it. [onHolding]
 * tells the Camera screen while the scanner is open, a send runs, or a PDF
 * waits.
 */
@Composable
fun DocumentMode(d: DeviceUi, strip: @Composable () -> Unit = {}, onHolding: (Boolean) -> Unit = {}) {
    val context = LocalContext.current
    var status by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    // True while the scanner is open, so that a link drop does not lose the scan.
    var scanning by rememberSaveable { mutableStateOf(false) }
    var failed by remember { mutableStateOf<PendingPdf?>(null) }
    ReportHolding(scanning || busy || failed != null, onHolding)
    val scanner = remember {
        GmsDocumentScanning.getClient(
            GmsDocumentScannerOptions.Builder()
                .setGalleryImportAllowed(true)
                .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_PDF)
                .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
                .build(),
        )
    }

    fun send(pdf: PendingPdf) {
        busy = true
        failed = null
        status = "Sending ${pdf.name}, ${pageLabel(pdf.pages)}…"
        Share.sendCapture(FluxCore, d.id, pdf.uri, pdf.name, mapOf("scan" to true)) { result ->
            ContextCompat.getMainExecutor(context).execute {
                busy = false
                if (result.isSuccess) {
                    FluxCore.toast("Sent to ${d.name}")
                    status = "Sent ${pdf.name}, ${pageLabel(pdf.pages)}, to ${d.name}"
                } else {
                    failed = pdf
                    status = result.exceptionOrNull()?.message ?: "Sending failed"
                }
            }
        }
    }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { res ->
        scanning = false
        if (res.resultCode != Activity.RESULT_OK) return@rememberLauncherForActivityResult
        val pdf = GmsDocumentScanningResult.fromActivityResultIntent(res.data)?.pdf ?: run {
            status = "The scanner returned no PDF"
            return@rememberLauncherForActivityResult
        }
        send(PendingPdf(pdf.uri, CaptureNames.document(), pdf.pageCount))
    }

    fun start() {
        val activity = context.findActivity()
        if (activity == null || GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) != ConnectionResult.SUCCESS) {
            status = NO_PLAY_SERVICES
            return
        }
        scanner.getStartScanIntent(activity)
            .addOnSuccessListener {
                scanning = true
                launcher.launch(IntentSenderRequest.Builder(it).build())
            }
            .addOnFailureListener { status = NO_PLAY_SERVICES + " " + (it.message ?: "") }
    }

    Column(Modifier.fillMaxSize()) {
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            IconBadge(Ic.document, size = 72.dp)
            T("Scan a document", size = 20, weight = FontWeight.SemiBold, align = TextAlign.Center)
            T(
                "The scanner finds the page edges. You can add pages or import from the gallery. Flux sends 1 PDF to ${d.name}.",
                size = 14, color = Tn.sub, align = TextAlign.Center, lineHeight = 1.35f,
            )
            val pending = failed
            if (pending != null) FluxButton("Send again", { send(pending) }, icon = Ic.send, enabled = d.online)
            // Without the computer, a new scan cannot go out.
            FluxButton(
                if (busy) "Sending" else "Scan document", ::start, icon = Ic.document, busy = busy, enabled = d.online,
                kind = if (pending != null) ButtonKind.Outlined else ButtonKind.Filled,
            )
            status?.let { T(it, size = 14, color = if (pending != null) Tn.red else Tn.sub, align = TextAlign.Center, lineHeight = 1.35f) }
        }
        strip()
        Spacer(Modifier.height(16.dp))
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
