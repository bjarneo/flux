package org.omarchy.flux.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.omarchy.flux.camera.CameraMode
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Share
import org.omarchy.flux.core.Target
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.WebUrl
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
    onPair: () -> Unit,
) {
    val t = target(scope, state.devices)
    val on = t !is Target.None
    fun page(title: String, page: String) = picker.run(t, title) { onOpen(Route(it.id, page)) }
    CappedScrollColumn {
        TargetLine(t, state.devices, "Sends to", onPair)
        Spacer(Modifier.height(TileGap))
        MasterTool(Ic.pasteGo, "Send clipboard", "Paste it on the computer", enabled = on, onClick = tools.sendClipboard)
        SectionLabel("Files")
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            ToolRow(Ic.sendFiles, "Send files", "Pick files on this phone", enabled = on, onClick = tools.sendFiles)
            ToolRow(Ic.folderOpen, "Get files", "Open the home folder of the computer, read-only", enabled = on) {
                page("Get files from", "browse")
            }
        }
        SectionLabel("Links")
        ToolRow(Ic.web, "Open a link", "Show a web page in the browser of the computer", enabled = on, onClick = tools.openLink)
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

/**
 * The dialog of Open a link: a web link for the browser of the computer in
 * [SendTools.linkTo]. The field starts with the clip when the clip is a
 * web link. Flux skips a clip that its app marks as sensitive.
 */
@Composable
fun LinkDialog(tools: SendTools) {
    val d = tools.linkTo.value ?: return
    val context = LocalContext.current
    var text by rememberSaveable(d.id) { mutableStateOf(WebUrl.of(Android.clipboardText(context, automatic = true)) ?: "") }
    val link = WebUrl.typed(text)
    val wrong = text.isNotBlank() && link == null
    val close = { tools.linkTo.value = null }
    val send = {
        if (link != null) {
            close()
            FluxCore.toast(if (Share.sendLink(FluxCore, d.id, link)) "Link sent to ${d.name}" else "${d.name} is not reachable")
        }
    }
    val focus = remember { FocusRequester() }
    LaunchedEffect(d.id) { focus.requestFocus() }
    AlertDialog(
        onDismissRequest = close,
        title = { Text("Open a link on ${d.name}") },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
                placeholder = { T("https://omarchy.org", color = Tn.sub, maxLines = 1) },
                trailingIcon = if (text.isEmpty()) null else { { ClearKey({ text = "" }, "Clear the link") } },
                supportingText = {
                    T(if (wrong) "Enter an http or https link" else "The browser of ${d.name} opens it", size = 12, color = if (wrong) Tn.red else Tn.sub)
                },
                isError = wrong,
                singleLine = true,
                textStyle = TextStyle(color = Tn.text, fontSize = 14.sp),
                shape = TileShape,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { send() }),
            )
        },
        confirmButton = { FluxButton("Open", send, icon = Ic.openInNew, enabled = link != null) },
        dismissButton = { FluxButton("Cancel", close, kind = ButtonKind.Text) },
    )
}
