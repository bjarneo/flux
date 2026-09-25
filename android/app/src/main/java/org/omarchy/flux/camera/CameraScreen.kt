package org.omarchy.flux.camera

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.ui.Palette
import org.omarchy.flux.ui.T
import org.omarchy.flux.ui.TopBar
import org.omarchy.flux.webcam.WebcamPanel

/** The modes of the Camera screen, in the order of the mode row. */
enum class CameraMode(val label: String) { Text("Text"), Qr("QR"), Photo("Photo"), Document("Document"), Webcam("Webcam") }

/** The Camera screen: 1 camera with a mode row at the bottom, like a camera app. */
@Composable
fun CameraScreen(d: DeviceUi, onBack: () -> Unit) {
    var mode by rememberSaveable { mutableStateOf(CameraMode.Text) }
    Column(Modifier.fillMaxSize()) {
        TopBar("Camera", onBack)
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
        ModeRow(mode) { mode = it }
    }
}

@Composable
private fun ModeRow(selected: CameraMode, onSelect: (CameraMode) -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
    ) {
        for (m in CameraMode.entries) {
            val on = m == selected
            Box(
                Modifier.clip(RoundedCornerShape(16.dp))
                    .background(if (on) Palette.accentContainer else androidx.compose.ui.graphics.Color.Transparent)
                    .clickable { onSelect(m) }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            ) {
                T(m.label, size = 14, color = if (on) Palette.onAccentContainer else Palette.secondary, weight = FontWeight.Medium, maxLines = 1)
            }
        }
    }
}
