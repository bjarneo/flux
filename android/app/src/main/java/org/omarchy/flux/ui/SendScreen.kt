package org.omarchy.flux.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import org.omarchy.flux.camera.CameraMode
import org.omarchy.flux.core.Target
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.target

/** The camera modes on the Send destination. Signature is in the mode bar of the camera, and Webcam is under Control. */
private val SendModes = listOf(CameraMode.Photo, CameraMode.Text, CameraMode.Document, CameraMode.Qr)

/**
 * The Send destination: the tools that send to the computer in scope. The
 * most used tool, Send clipboard, takes the master tile. The other tools
 * stack under it in compact rows. With all computers in scope and more
 * than 1 online, each action asks for the computer.
 */
@Composable
fun SendScreen(
    state: UiState,
    scope: String?,
    picker: TargetPicker,
    tools: SendTools,
    onOpen: (Route) -> Unit,
    onSync: () -> Unit,
    onPair: () -> Unit,
) {
    val t = target(scope, state.devices)
    val on = t !is Target.None
    fun page(title: String, page: String) = picker.run(t, title) { onOpen(Route(it.id, page)) }
    CappedScrollColumn {
        TargetLine(t, state.devices, "Sends to", onPair)
        Spacer(Modifier.height(TileGap))
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            MasterTool(Ic.pasteGo, "Send clipboard", "Paste it on the computer", enabled = on, onClick = tools.sendClipboard)
            ClipLine(state, onSync)
        }
        SectionLabel("Files")
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            ToolRow(Ic.sendFiles, "Send files", "Pick files on this phone", enabled = on, onClick = tools.sendFiles)
            ToolRow(Ic.folderOpen, "Get files", "Open the home folder of the computer, read-only", enabled = on) {
                page("Get files from", "browse")
            }
        }
        SectionLabel("Camera")
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            for (m in SendModes) {
                ToolRow(m.icon, m.label, m.hint, enabled = on) { page("Send from the camera to", "camera:${m.name.lowercase()}") }
            }
        }
        T(
            "To send text or a link from another app, select it, then choose Flux in the Share menu.",
            Modifier.padding(start = 4.dp, top = 20.dp), size = 13, color = Tn.sub, lineHeight = 1.35f,
        )
    }
}

/** The state of the automatic clipboard sync. A tap opens the Sync screen, which can set it up. */
@Composable
private fun ClipLine(state: UiState, onSync: () -> Unit) {
    val (label, active) = clipAutoLine(state)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(8.dp))
            .clickable(onClickLabel = "Open the sync settings", onClick = onSync)
            .padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(if (active) Ic.sync else Ic.paste, tint = if (active) Tn.green else Tn.sub, size = 18.dp)
        T(label, Modifier.weight(1f), size = 13, color = if (active) Tn.green else Tn.sub)
        Sym(Ic.chevron, tint = Tn.sub, size = 18.dp)
    }
}
