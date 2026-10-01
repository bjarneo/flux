package org.omarchy.flux.camera

import androidx.annotation.DrawableRes
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.ui.ChoiceChip
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.NotReachable
import org.omarchy.flux.ui.TiledGutter
import org.omarchy.flux.ui.TiledTopBar

/** The modes of the Camera screen, in the order of the mode strip. The webcam has its own screen under Control. */
enum class CameraMode(val label: String, @DrawableRes val icon: Int, val hint: String) {
    Text("Text", Ic.text, "Scan text and send it"),
    Qr("QR", Ic.qr, "Read a QR code or barcode"),
    Photo("Photo", Ic.camera, "Take a photo for the computer"),
    Document("Document", Ic.document, "Scan pages to a PDF"),
    Signature("Signature", Ic.signature, "Sign on paper, paste on the computer");

    companion object {
        /** The mode named [key], such as "qr", or Text for an unknown key. */
        fun fromKey(key: String): CameraMode = entries.firstOrNull { it.name.equals(key, ignoreCase = true) } ?: Text
    }
}

/**
 * The Camera screen: 1 camera and the mode strip above the shutter, as in
 * the camera app of the phone. Each mode puts [ModeStrip] above its
 * controls while it shows the camera.
 */
@Composable
fun CameraScreen(d: DeviceUi, onBack: () -> Unit, initial: CameraMode = CameraMode.Text) {
    var mode by rememberSaveable { mutableStateOf(initial) }
    val strip: @Composable () -> Unit = { ModeStrip(mode) { mode = it } }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.padding(horizontal = TiledGutter)) { TiledTopBar("Camera", onBack, context = d.name) }
        if (!d.online) {
            Box(Modifier.padding(horizontal = TiledGutter)) { NotReachable(d, "The camera modes") }
            return@Column
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            // Each mode binds the camera itself and releases it when it leaves.
            when (mode) {
                CameraMode.Text -> TextMode(d, strip)
                CameraMode.Qr -> QrMode(d, strip)
                CameraMode.Photo -> PhotoMode(d, strip)
                CameraMode.Document -> DocumentMode(d, strip)
                CameraMode.Signature -> SignatureMode(d, strip)
            }
        }
    }
}

/**
 * The 5 modes in 1 row of tabs. The selected mode has the selection
 * color. At a large font size, the row scrolls.
 */
@Composable
internal fun ModeStrip(mode: CameraMode, onMode: (CameraMode) -> Unit) {
    // The row is centered while it fits the width.
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Row(
            Modifier.horizontalScroll(rememberScrollState()).selectableGroup().padding(horizontal = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            for (m in CameraMode.entries) ChoiceChip(m.label, selected = m == mode, onClick = { onMode(m) }, role = Role.Tab)
        }
    }
}
