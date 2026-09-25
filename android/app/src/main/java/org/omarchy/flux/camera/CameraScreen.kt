package org.omarchy.flux.camera

import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.Sym
import org.omarchy.flux.ui.TopBar
import org.omarchy.flux.webcam.WebcamPanel

/** The modes of the Camera screen, in the order of the mode bar. */
enum class CameraMode(val label: String, @DrawableRes val icon: Int, val hint: String) {
    Text("Text", Ic.text, "Scan text and send it"),
    Qr("QR", Ic.qr, "Read a QR code or barcode"),
    Photo("Photo", Ic.camera, "Take a photo for the computer"),
    Document("Document", Ic.document, "Scan pages to a PDF"),
    Webcam("Webcam", Ic.videocamOutline, "Use this phone as a webcam");

    companion object {
        /** The mode named [key], such as "qr", or Text for an unknown key. */
        fun fromKey(key: String): CameraMode = entries.firstOrNull { it.name.equals(key, ignoreCase = true) } ?: Text
    }
}

/** The Camera screen: 1 camera with a mode bar at the bottom. */
@Composable
fun CameraScreen(d: DeviceUi, onBack: () -> Unit, initial: CameraMode = CameraMode.Text) {
    var mode by rememberSaveable { mutableStateOf(initial) }
    Column(Modifier.fillMaxSize()) {
        TopBar("Camera", onBack, subtitle = mode.hint)
        Box(Modifier.weight(1f).fillMaxWidth()) {
            // Each mode binds the camera itself and releases it when it leaves.
            when (mode) {
                CameraMode.Text -> TextMode(d)
                CameraMode.Qr -> QrMode(d)
                CameraMode.Photo -> PhotoMode(d)
                CameraMode.Document -> DocumentMode(d)
                CameraMode.Webcam -> WebcamPanel(d.id)
            }
        }
        // The root of the activity already pads for the system bars.
        NavigationBar(windowInsets = WindowInsets(0), containerColor = MaterialTheme.colorScheme.surfaceContainer) {
            for (m in CameraMode.entries) {
                NavigationBarItem(
                    selected = m == mode,
                    onClick = { mode = m },
                    icon = { Sym(m.icon) },
                    label = { Text(m.label, maxLines = 1) },
                )
            }
        }
    }
}
