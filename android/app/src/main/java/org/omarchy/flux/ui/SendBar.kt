package org.omarchy.flux.ui

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.LruCache
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.omarchy.flux.core.CaptureWatch
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Share

/** The number of recent photos under Photo. */
private const val RECENT_PHOTOS = 4

/** The part of the Send bar that is open above the keys. */
internal enum class BarPanel { None, Photos, More }

/** The labels of the Send bar, in the order that the chat shows them. */
internal object SendBarEntries {
    /** The keys that stay open above the field. */
    val bar = listOf("Photo", "File", "Scan", "More")

    /** The tools in the list of More. */
    val more = listOf("Camera", "Text", "QR", "Signature")
}

/** A key of the Send bar or a row of More. [description] is the label for TalkBack. */
private class BarTool(@param:DrawableRes val icon: Int, val label: String, val description: String, val onClick: () -> Unit)

/**
 * The Send bar of the chat of a computer, above the field: the keys Photo,
 * File, Scan, and More. Photo opens the 4 newest photos of this phone and
 * All photos above the keys. A tap on a photo selects it or takes it out,
 * and the send key sends the [photos] in the order of the taps. More opens
 * a list of Camera, Text, QR, and Signature. File opens the file picker,
 * and Scan opens the scan of pages to a PDF. [panel] tells which part is
 * open. A tool opens its screen for the computer [d]. Without access to
 * the photos, a line asks for it.
 */
@Composable
internal fun SendBar(d: DeviceUi, photos: SnapshotStateList<Uri>, actions: ChatActions, panel: BarPanel, onPanel: (BarPanel) -> Unit) {
    val context = LocalContext.current
    val on = d.online
    val demo = isDemo(d.id)
    var access by remember { mutableStateOf(hasPhotoAccess(context)) }
    LifecycleResumeEffect(context) {
        access = hasPhotoAccess(context)
        onPauseOrDispose { }
    }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { access = hasPhotoAccess(context) }
    // The photos load each time Photo opens and after a new access.
    var reload by remember { mutableIntStateOf(0) }
    val recent by produceState(emptyList<Uri>(), access, reload) {
        value = if (access) withContext(Dispatchers.IO) { recentPhotos(context, RECENT_PHOTOS) } else emptyList()
    }
    LaunchedEffect(panel) { if (panel == BarPanel.Photos) reload++ }
    val pickPhotos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris ->
        if (uris.isNotEmpty()) {
            Share.sendFiles(FluxCore, d.id, uris)
            onPanel(BarPanel.None)
        }
    }
    // The file picker is another activity, so the bar sends to the computer of this chat when it comes back.
    var picking by rememberSaveable { mutableStateOf(false) }
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (picking && uris.isNotEmpty()) {
            Share.sendFiles(FluxCore, d.id, uris)
            onPanel(BarPanel.None)
        }
        picking = false
    }
    fun go(page: String) {
        onPanel(BarPanel.None)
        actions.open(Route(d.id, page))
    }
    val sample = { FluxCore.toast("This is a sample computer") }
    val keys = listOf(
        BarTool(Ic.gallery, "Photo", "Show the newest photos to send to ${d.name}") {
            onPanel(if (panel == BarPanel.Photos) BarPanel.None else BarPanel.Photos)
        },
        BarTool(Ic.sendFiles, "File", "Send files to ${d.name}") {
            onPanel(BarPanel.None)
            if (demo) {
                sample()
            } else {
                picking = true
                pickFiles.launch(arrayOf("*/*"))
            }
        },
        BarTool(Ic.document, "Scan", "Scan pages to a PDF") { go("camera:document") },
        BarTool(Ic.more, "More", "Show more tools") { onPanel(if (panel == BarPanel.More) BarPanel.None else BarPanel.More) },
    )
    val more = listOf(
        BarTool(Ic.camera, "Camera", "Take a photo for ${d.name}") { go("camera:photo") },
        BarTool(Ic.text, "Text", "Scan text and send it") { go("camera:text") },
        BarTool(Ic.qr, "QR", "Read a QR code or barcode") { go("camera:qr") },
        BarTool(Ic.signature, "Signature", "Sign on paper, paste on the computer") { go("camera:signature") },
    )
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        AnimatedVisibility(
            panel == BarPanel.More,
            enter = expandVertically(expandFrom = Alignment.Bottom) + fadeIn(),
            exit = shrinkVertically(shrinkTowards = Alignment.Bottom) + fadeOut(),
        ) {
            val shape = RoundedCornerShape(14.dp)
            Column(Modifier.fillMaxWidth().clip(shape).background(Tn.bg).border(1.dp, Tn.lineHi, shape)) {
                more.forEachIndexed { i, t ->
                    if (i > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(Tn.line))
                    MoreRow(t, enabled = on)
                }
            }
        }
        AnimatedVisibility(
            panel == BarPanel.Photos,
            enter = expandVertically(expandFrom = Alignment.Bottom) + fadeIn(),
            exit = shrinkVertically(shrinkTowards = Alignment.Bottom) + fadeOut(),
        ) {
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    T("Recent photos", Modifier.weight(1f).semantics { heading() }, size = 12, color = Tn.sub, weight = FontWeight.Medium)
                    TextAction(
                        "All photos",
                        {
                            if (demo) sample() else pickPhotos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                        },
                        enabled = on, size = 12, height = 32.dp, pad = 4.dp,
                    )
                }
                if (access && recent.isNotEmpty()) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        for (uri in recent) {
                            val n = photos.indexOf(uri) + 1
                            PhotoCell(uri, n, enabled = on, modifier = Modifier.weight(1f)) {
                                if (n > 0) photos.remove(uri) else photos.add(uri)
                            }
                        }
                        repeat(RECENT_PHOTOS - recent.size) { Spacer(Modifier.weight(1f)) }
                    }
                } else if (access) {
                    T("No photos on this phone yet.", Modifier.padding(horizontal = 4.dp), size = 12, color = Tn.sub)
                } else {
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(10.dp)).background(Tn.bg).padding(start = 12.dp, end = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Sym(Ic.gallery, tint = Tn.blue, size = 20.dp)
                        T("Allow access to show your newest photos here.", Modifier.weight(1f), size = 12, color = Tn.sub, lineHeight = 1.3f)
                        TextAction("Allow", { ask.launch(CaptureWatch.permissions()) }, size = 13, height = 40.dp, pad = 8.dp)
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (k in keys) {
                val open = (k.label == "Photo" && panel == BarPanel.Photos) || (k.label == "More" && panel == BarPanel.More)
                BarKey(k, enabled = on, open = open, modifier = Modifier.weight(1f))
            }
        }
    }
}

/** A key of the Send bar: an accent icon beside a 13 sp label, 48 dp high, on `bg` with a `line` border. It has an accent border while its part is open. */
@Composable
private fun BarKey(t: BarTool, enabled: Boolean, open: Boolean, modifier: Modifier) {
    val shape = RoundedCornerShape(12.dp)
    Row(
        modifier.heightIn(min = 48.dp).alpha(if (enabled) 1f else DimAlpha).clip(shape).background(Tn.bg)
            .border(1.dp, if (open) Tn.blue else Tn.line, shape)
            .clickable(enabled = enabled, onClickLabel = t.description, role = Role.Button, onClick = t.onClick)
            .clearAndSetSemantics { contentDescription = t.label }
            .padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(t.icon, tint = Tn.blue, size = 18.dp)
        T(t.label, size = 13, weight = FontWeight.Medium, align = TextAlign.Center, maxLines = 1, fit = true)
    }
}

/** A row of the list of More, 48 dp high: an accent icon and the label. */
@Composable
private fun MoreRow(t: BarTool, enabled: Boolean) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).alpha(if (enabled) 1f else DimAlpha)
            .clickable(enabled = enabled, onClickLabel = t.description, role = Role.Button, onClick = t.onClick)
            .clearAndSetSemantics { contentDescription = t.label }
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(t.icon, tint = Tn.blue, size = 20.dp)
        T(t.label, size = 15, maxLines = 1)
    }
}

/**
 * A recent photo under Photo, 80 dp high. A selected photo has a 2 dp
 * accent border and its number in an accent circle at the top right.
 */
@Composable
private fun PhotoCell(uri: Uri, number: Int, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val shape = RoundedCornerShape(10.dp)
    val picture = rememberThumbnail(uri.toString(), 240)
    val selected = number > 0
    Box(
        modifier.height(80.dp).alpha(if (enabled) 1f else DimAlpha).clip(shape)
            .border(if (selected) 2.dp else 1.dp, if (selected) Tn.blue else Tn.line, shape)
            .toggleable(selected, enabled = enabled, role = Role.Checkbox) { onClick() }
            .semantics {
                contentDescription = "Photo"
                stateDescription = if (selected) "Selected, number $number" else "Not selected"
            },
    ) {
        if (picture != null) Image(picture, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) else Stripes(Modifier.fillMaxSize())
        if (selected) {
            Box(
                Modifier.align(Alignment.TopEnd).padding(5.dp).size(20.dp).clip(CircleShape).background(Tn.blue),
                contentAlignment = Alignment.Center,
            ) { T("$number", size = 11, color = Tn.onAccent, weight = FontWeight.Bold, maxLines = 1) }
        }
    }
}

/** Diagonal stripes on `bg`, the place of a picture that did not load. */
@Composable
internal fun Stripes(modifier: Modifier) {
    val a = Tn.bg
    val b = Tn.offTile
    Canvas(modifier.background(a)) {
        val step = 14.dp.toPx()
        val w = 7.dp.toPx()
        var x = -size.height
        while (x < size.width) {
            drawLine(b, Offset(x, size.height), Offset(x + size.height, 0f), strokeWidth = w)
            x += step
        }
    }
}

/** True when Flux may read the photos of this phone, all of them or the ones that the user picked. */
private fun hasPhotoAccess(context: Context): Boolean {
    fun granted(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED
    return when {
        Build.VERSION.SDK_INT >= 34 -> granted(Manifest.permission.READ_MEDIA_IMAGES) || granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        Build.VERSION.SDK_INT >= 33 -> granted(Manifest.permission.READ_MEDIA_IMAGES)
        else -> granted(Manifest.permission.READ_EXTERNAL_STORAGE)
    }
}

/** The [limit] newest images of this phone, the newest first. */
private fun recentPhotos(context: Context, limit: Int): List<Uri> = runCatching {
    val images = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    val out = ArrayList<Uri>()
    context.contentResolver.query(
        images, arrayOf(MediaStore.Images.Media._ID), null, null, "${MediaStore.Images.Media.DATE_ADDED} DESC",
    )?.use { c ->
        while (out.size < limit && c.moveToNext()) out += ContentUris.withAppendedId(images, c.getLong(0))
    }
    out
}.getOrDefault(emptyList())

/** The pictures that the chat loaded, by uri and size. */
private val thumbnails = LruCache<String, ImageBitmap>(32)

/**
 * The picture of the image [uri], at most [px] pixels on its long side, or
 * null while it loads or when the phone cannot read it.
 */
@Composable
internal fun rememberThumbnail(uri: String, px: Int): ImageBitmap? {
    val context = LocalContext.current
    val key = "$px|$uri"
    val picture by produceState(thumbnails.get(key), key) {
        if (value != null || uri.isEmpty()) return@produceState
        value = withContext(Dispatchers.IO) {
            runCatching { context.contentResolver.loadThumbnail(uri.toUri(), Size(px, px), null).asImageBitmap() }.getOrNull()
        }?.also { thumbnails.put(key, it) }
    }
    return picture
}
