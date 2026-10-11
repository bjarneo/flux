package org.omarchy.flux.ui

import android.content.ClipboardManager
import android.content.Context
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.util.Calendar
import org.omarchy.flux.BuildConfig
import org.omarchy.flux.camera.CameraMode
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.DebugDemo
import org.omarchy.flux.core.DebugInbox
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.InboxFeed
import org.omarchy.flux.core.SendEntry
import org.omarchy.flux.core.SendKind
import org.omarchy.flux.core.SendLog
import org.omarchy.flux.core.Share
import org.omarchy.flux.core.Target
import org.omarchy.flux.core.TransferState
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.target

/**
 * The Send destination: what this phone sent to the computers in scope,
 * and the files that came from them, as a thread with the newest at the
 * bottom. The dock under it shows the clipboard of this phone with Send,
 * the tools, and a field for text or a link. With all computers in scope
 * and more than 1 online, each action asks for the computer.
 */
@Composable
fun SendScreen(
    state: UiState,
    scope: String?,
    onScope: (String?) -> Unit,
    picker: TargetPicker,
    tools: SendTools,
    onOpen: (Route) -> Unit,
    onPair: () -> Unit,
) {
    val devices = state.devices
    val t = target(scope, devices)
    val on = t !is Target.None
    fun page(title: String, page: String) = picker.run(t, title) { onOpen(Route(it.id, page)) }
    val logged by SendLog.entries.collectAsStateWithLifecycle()
    val demo = BuildConfig.DEBUG && DebugDemo.on
    val entries = remember(logged, demo, scope) {
        (if (demo) DebugInbox.sends() + logged else logged).filter { scope == null || it.deviceId == scope }.sortedBy { it.at }
    }
    val running = entries.filter { it.kind == SendKind.File && it.state == TransferState.Running }
    val clip = rememberPhoneClip()

    Column(Modifier.fillMaxSize().imePadding()) {
        Box(Modifier.statusBarsPadding()) {
            ScreenHeader("Send", listOf("to ${scopeName(devices, scope)}", onlineText(devices)).filter { it.isNotEmpty() }.joinToString(" · "))
        }
        ComputerStrip(devices, scope, onScope)
        ProgressLine {
            if (running.isNotEmpty()) {
                val size = running.sumOf { it.size }
                LineFill(if (size > 0) running.sumOf { it.done }.toFloat() / size else 0f, Tn.blue)
            }
        }
        DockLayout(
            Modifier.weight(1f).fillMaxWidth(),
            thread = { bottom -> SendThread(entries, showComputer = scope == null, bottom, t, devices, onPair) },
            dock = { shape ->
                SendDock(
                    shape, on, clip, entries,
                    onClip = tools.sendClipboard,
                    tools = listOf(
                        DockTool(Ic.sendFiles, "Files", "Send files", tools.sendFiles),
                        DockTool(Ic.folderOpen, "Get", "Get files from the computer") { page("Get files from", "browse") },
                        DockTool(Ic.camera, "Photo", CameraMode.Photo.hint) { page("Send from the camera to", "camera:photo") },
                        DockTool(Ic.document, "Scan", CameraMode.Document.hint) { page("Send from the camera to", "camera:document") },
                        DockTool(Ic.text, "Text", CameraMode.Text.hint) { page("Send from the camera to", "camera:text") },
                        DockTool(Ic.qr, "QR", CameraMode.Qr.hint) { page("Send from the camera to", "camera:qr") },
                    ),
                    onText = { text -> picker.run(t, "Send to") { Share.sendText(FluxCore, it.id, text) } },
                )
            },
        )
    }
}

// ───────────────────────── Thread ─────────────────────────

/**
 * The entries of the Send thread with the day over each new day, the newest
 * at the bottom. The view follows a new entry. Without entries, a line
 * tells what shows here. Without a computer to send to, the line of the
 * target tells why, with the next step.
 */
@Composable
private fun SendThread(entries: List<SendEntry>, showComputer: Boolean, bottom: Dp, t: Target, devices: List<DeviceUi>, onPair: () -> Unit) {
    val scroll = rememberScrollState()
    LaunchedEffect(entries.size, entries.lastOrNull()?.id) { scroll.scrollTo(scroll.maxValue) }
    val context = LocalContext.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize().verticalScroll(scroll).heightIn(min = maxHeight)
                .padding(start = 14.dp, end = 14.dp, top = 16.dp, bottom = bottom),
            verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.Bottom),
        ) {
            if (entries.isEmpty() && t !is Target.None) {
                T(
                    "Links, text, and files that you send show here. To send from another app, select the text or the file, then choose Flux in the Share menu.",
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp), size = 13, color = Tn.sub, align = TextAlign.Center, lineHeight = 1.4f,
                )
            }
            var day = -1L
            for (e in entries) {
                val d = dayOf(e.at)
                if (d != day) {
                    day = d
                    T(dayText(e.at), Modifier.fillMaxWidth(), size = 12, color = Tn.sub, align = TextAlign.Center)
                }
                when (e.kind) {
                    SendKind.File, SendKind.ClipImage -> SendFile(e, sendMeta(context, e, showComputer))
                    else -> SendBubble(e.text, sendMeta(context, e, showComputer))
                }
            }
            if (t is Target.None) TargetLine(t, devices, "Sends to", onPair)
        }
    }
}

/** Text, a link, or a clip that went out: a bubble at the right in mono, with [meta] under it. */
@Composable
private fun SendBubble(text: String, meta: String) {
    BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
        Column(Modifier.widthIn(max = maxWidth * 0.85f), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            val shape = RoundedCornerShape(16.dp, 16.dp, 4.dp, 16.dp)
            SelectionContainer {
                LineText(
                    breakAll(text), Modifier.clip(shape).background(Tn.accentTile).border(1.dp, Tn.lineHi, shape).padding(horizontal = 14.dp, vertical = 8.dp),
                    size = 12.5f, lineHeight = 1.45f, family = Mono,
                )
            }
            T(meta, size = 11, color = Tn.sub)
        }
    }
}

/**
 * A file or an image clip: a card of 244 dp with its icon, its name, and
 * [meta], and a bar while it runs. A file from the computer is at the left.
 */
@Composable
private fun SendFile(e: SendEntry, meta: String) {
    val shape = RoundedCornerShape(12.dp)
    Box(Modifier.fillMaxWidth(), contentAlignment = if (e.incoming) Alignment.CenterStart else Alignment.CenterEnd) {
        Column(
            Modifier.width(244.dp).clip(shape).background(Tn.tile).border(1.dp, Tn.line, shape).padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Sym(if (e.kind == SendKind.ClipImage) Ic.image else sendFileIcon(e.text), tint = Tn.blue, size = 22.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    T(if (e.kind == SendKind.ClipImage) "Image" else e.text, size = 13, weight = FontWeight.Medium, family = Mono, maxLines = 1)
                    T(meta, size = 12, color = if (e.state == TransferState.Failed) Tn.red else Tn.sub)
                }
                when (e.state) {
                    TransferState.Running -> RingSpinner(14.dp, color = Tn.blue)
                    TransferState.Done -> Sym(Ic.check, "Done", tint = Tn.green, size = 18.dp)
                    TransferState.Failed -> Sym(Ic.close, "Failed", tint = Tn.red, size = 18.dp)
                }
            }
            if (e.state == TransferState.Running) {
                Box(Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(Tn.line)) { LineFill(e.progress, Tn.blue) }
            }
        }
    }
}

/** The icon of a file of the Send thread: an image, or a document. */
@DrawableRes
private fun sendFileIcon(name: String): Int = if (fileIcon(name, false) == Ic.image) Ic.image else Ic.textFile

/** The line under an entry, such as "Link · opened in the browser · 13:20". [showComputer] adds the computer. */
private fun sendMeta(context: Context, e: SendEntry, showComputer: Boolean): String {
    val time = android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(e.at))
    val pct = "${(e.progress * 100).toInt()}% of ${bytes(e.size)}"
    return when (e.kind) {
        SendKind.Link -> if (showComputer) "Link · opened on ${e.computer} · $time" else "Link · opened in the browser · $time"
        SendKind.Text -> if (showComputer) "Text · on the clipboard of ${e.computer} · $time" else "Text · on the clipboard · $time"
        SendKind.Scan -> if (showComputer) "Scan · saved on ${e.computer} · $time" else "Scan · saved as a text file · $time"
        SendKind.Clip, SendKind.ClipImage -> if (showComputer) "Clipboard · to ${e.computer} · $time" else "Clipboard · $time"
        SendKind.File -> when {
            e.incoming && e.state == TransferState.Running -> "From ${e.computer} · $pct"
            e.incoming && e.state == TransferState.Done -> "Received · in Downloads"
            e.incoming -> "Not received · $time"
            e.state == TransferState.Running -> (if (showComputer) "Sending to ${e.computer}" else "Sending") + " · $pct"
            e.state == TransferState.Done -> (if (showComputer) "Sent to ${e.computer}" else "Sent") + " · $time"
            else -> "Not sent · $time"
        }
    }
}

/** The day of [at] as a number, to find the first entry of each day. */
private fun dayOf(at: Long): Long {
    val c = Calendar.getInstance().apply { timeInMillis = at }
    return c.get(Calendar.YEAR) * 1000L + c.get(Calendar.DAY_OF_YEAR)
}

/** "Today", "Yesterday", or the date of [at]. */
private fun dayText(at: Long): String {
    val now = System.currentTimeMillis()
    return when (dayOf(at)) {
        dayOf(now) -> "Today"
        dayOf(now - 24 * 60 * 60_000L) -> "Yesterday"
        else -> java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(java.util.Date(at))
    }
}

/**
 * Text that breaks at any character, as a link or a command in mono does in
 * the design. A zero-width space goes between 2 characters that are not
 * white space.
 */
internal fun breakAll(text: String): String {
    val b = StringBuilder(text.length * 2)
    var i = 0
    while (i < text.length) {
        val n = Character.charCount(text.codePointAt(i))
        if (i > 0 && !text[i].isWhitespace() && !text[i - 1].isWhitespace()) b.append('​')
        b.append(text, i, i + n)
        i += n
    }
    return b.toString()
}

// ───────────────────────── Dock ─────────────────────────

/** A tool of the Send dock. [description] is the label for TalkBack. */
private class DockTool(@param:DrawableRes val icon: Int, val label: String, val description: String, val onClick: () -> Unit)

/**
 * The dock of Send: the clipboard of this phone with Send, the 6 tools,
 * and the field for text or a link. [entries] tell whether the clip went
 * out already.
 */
@Composable
private fun SendDock(
    shape: DockShape,
    on: Boolean,
    clip: PhoneClip,
    entries: List<SendEntry>,
    onClip: () -> Unit,
    tools: List<DockTool>,
    onText: (String) -> Unit,
) {
    val now by rememberTicker(30_000L)
    val sent = clip.stamp.takeIf { it != 0L }?.let { s -> entries.lastOrNull { it.clipStamp == s } }
    val context = LocalContext.current
    Column(
        Modifier.fillMaxWidth().dockFrame(shape).padding(start = 12.dp, end = 12.dp, top = 14.dp, bottom = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(Modifier.padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Dot(Tn.cyan, 8.dp)
            T("Clipboard", size = 12, color = Tn.cyan, weight = FontWeight.Medium)
            val meta = when {
                sent != null -> "sent to ${sent.computer} at ${android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(sent.at))}"
                clip.empty -> "empty"
                clip.from != null -> "from ${clip.from}" + (if (clip.stamp > 0) " ${agoText(clip.stamp, now)}" else "")
                clip.stamp > 0 -> "copied ${agoText(clip.stamp, now)} on this phone"
                else -> "on this phone"
            }
            T("· $meta", Modifier.weight(1f), size = 11, color = Tn.sub, family = Mono, maxLines = 1)
        }
        Row(Modifier.fillMaxWidth().height(56.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(10.dp)).background(Tn.bg).padding(horizontal = 11.dp, vertical = 9.dp)) {
                val text = clip.text
                if (text != null) {
                    LineText(breakAll(text), Modifier.clearAndSetSemantics { contentDescription = text }, size = 12f, lineHeight = 1.45f, family = Mono, maxLines = 2)
                } else {
                    T(
                        when {
                            clip.image -> "An image"
                            clip.hidden -> "Hidden, because the app that copied it marks it as private"
                            else -> "Copy text or an image on this phone"
                        },
                        size = 12, color = Tn.sub, lineHeight = 1.45f, maxLines = 2,
                    )
                }
            }
            val can = on && !clip.empty
            val ink = if (sent != null) Tn.text else Tn.onAccent
            Column(
                Modifier.width(88.dp).fillMaxHeight().alpha(if (can) 1f else DimAlpha).clip(RoundedCornerShape(12.dp))
                    .background(if (sent != null) Tn.line else Tn.blue)
                    .clickable(enabled = can, onClickLabel = "Send the clipboard", role = Role.Button) {
                        if (sent != null) FluxCore.toast("The clip is on ${sent.computer} already") else onClip()
                    },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
            ) {
                Sym(if (sent != null) Ic.check else Ic.pasteGo, tint = ink, size = 20.dp)
                T(if (sent != null) "Sent" else "Send", size = 14, color = ink, weight = FontWeight.SemiBold)
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (k in tools) {
                DockKey(k.description, Modifier.weight(1f).height(56.dp), enabled = on, onClick = k.onClick) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Sym(k.icon, tint = Tn.blue, size = 21.dp)
                        T(k.label, size = 11, weight = FontWeight.Medium, maxLines = 1, fit = true)
                    }
                }
            }
        }
        SendComposer(on, onText)
    }
}

/** The field for text or a link, and its send key. A web link opens in the browser of the computer, and other text goes to its clipboard. */
@Composable
private fun SendComposer(on: Boolean, onSend: (String) -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    val can = on && text.isNotBlank()
    val send = {
        if (can) {
            onSend(text.trim())
            text = ""
        }
    }
    val shape = RoundedCornerShape(24.dp)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Bottom) {
        BasicTextField(
            value = text,
            onValueChange = { text = it },
            modifier = Modifier.weight(1f).semantics { contentDescription = "Text or a link" },
            enabled = on,
            textStyle = TextStyle(color = Tn.text, fontSize = 14.sp, lineHeight = 20.sp),
            cursorBrush = SolidColor(Tn.blue),
            maxLines = 4,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { send() }),
            decorationBox = { inner ->
                Box(
                    Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(shape).background(Tn.bg).border(1.dp, Tn.lineHi, shape)
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    if (text.isEmpty()) T("Type text or a link", Modifier.clearAndSetSemantics {}, size = 14, color = Tn.sub, maxLines = 1)
                    inner()
                }
            },
        )
        Box(
            Modifier.size(48.dp).clip(CircleShape).background(if (can) Tn.blue else Tn.line)
                .clickable(enabled = can, onClickLabel = "Send", role = Role.Button, onClick = send)
                .semantics { contentDescription = "Send" },
            contentAlignment = Alignment.Center,
        ) { Sym(Ic.up, tint = if (can) Tn.onAccent else Tn.sub, size = 22.dp) }
    }
}

// ───────────────────────── Clipboard ─────────────────────────

/**
 * The clipboard of this phone for the Send dock. [text] is null for an
 * image, a clip that its app marks as private ([hidden]), or an empty
 * clipboard. [from] names the computer when the clip came from Flux.
 * [stamp] is the time that Android set on the clip.
 */
internal data class PhoneClip(
    val text: String? = null,
    val image: Boolean = false,
    val hidden: Boolean = false,
    val stamp: Long = 0,
    val from: String? = null,
) {
    val empty: Boolean get() = text == null && !image && !hidden
}

/** The last clip that the Send dock read. A clip with the same time comes from here, so that Android shows its paste notice once for each clip. */
private var lastClip: PhoneClip? = null

/**
 * Reads the clipboard of this phone. Android lets the app read it only
 * while the window has focus, so the dock reads it again when the window
 * gets the focus, when the app comes back, and when the clip changes.
 */
@Composable
private fun rememberPhoneClip(): PhoneClip {
    val context = LocalContext.current
    val focused = LocalWindowInfo.current.isWindowFocused
    var clip by remember { mutableStateOf(lastClip ?: PhoneClip()) }
    LaunchedEffect(focused) { if (focused) clip = readClip(context) }
    LifecycleResumeEffect(context) {
        clip = readClip(context)
        onPauseOrDispose { }
    }
    DisposableEffect(context) {
        val cm = context.getSystemService(ClipboardManager::class.java)
        val listener = ClipboardManager.OnPrimaryClipChangedListener { clip = readClip(context) }
        cm?.addPrimaryClipChangedListener(listener)
        onDispose { cm?.removePrimaryClipChangedListener(listener) }
    }
    return clip
}

private fun readClip(context: Context): PhoneClip {
    val cm = context.getSystemService(ClipboardManager::class.java) ?: return PhoneClip()
    val desc = runCatching { cm.primaryClipDescription }.getOrNull() ?: return PhoneClip().also { lastClip = it }
    val stamp = Android.clipTimestamp(context)
    lastClip?.let { if (stamp != 0L && it.stamp == stamp) return it }
    // Flux puts the clip of a computer on the clipboard with its own label.
    val from = InboxFeed.clip.value?.takeIf { !it.sent && desc.label?.toString() == "Flux" }?.computer
    val read = when {
        desc.hasMimeType("image/*") -> PhoneClip(image = true, stamp = stamp, from = from)
        Android.clipboardSensitive(context) -> PhoneClip(hidden = true, stamp = stamp)
        else -> {
            // Without the focus, Android gives no text. The next read gets it.
            val text = Android.clipboardText(context, automatic = true)?.takeIf { it.isNotBlank() } ?: return PhoneClip(stamp = stamp)
            PhoneClip(text = text.trim().take(400), stamp = stamp, from = from)
        }
    }
    lastClip = read
    return read
}
