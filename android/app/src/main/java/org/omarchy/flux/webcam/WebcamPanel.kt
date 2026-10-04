package org.omarchy.flux.webcam

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.view.TextureView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.camera.CameraRationale
import org.omarchy.flux.camera.rememberCameraPermission
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.StreamKind
import org.omarchy.flux.mic.MicSettings
import org.omarchy.flux.ui.ButtonKind
import org.omarchy.flux.ui.ChoiceChip
import org.omarchy.flux.ui.FluxButton
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.Mono
import org.omarchy.flux.ui.NotReachable
import org.omarchy.flux.ui.Palette
import org.omarchy.flux.ui.PermissionNotice
import org.omarchy.flux.ui.StartAfterTap
import org.omarchy.flux.ui.Sym
import org.omarchy.flux.ui.T
import org.omarchy.flux.ui.TileLabel
import org.omarchy.flux.ui.TiledGutter
import org.omarchy.flux.ui.TiledTopBar
import org.omarchy.flux.ui.Tn
import org.omarchy.flux.ui.rememberStreamStart

/**
 * The Webcam screen of 1 computer, in the Stream band of Control. A stream
 * that runs keeps its Stop button, also when the link drops. The stream
 * keeps running after the screen closes and while Flux is in the
 * background. After a tap on Start in a stream request of the computer,
 * the stream starts when the computer is reachable and the camera is ready.
 */
@Composable
fun WebcamScreen(d: DeviceUi, onBack: () -> Unit) {
    val status by WebcamSession.status.collectAsState()
    val live = status.active
    val startNow = rememberStreamStart(d.id, StreamKind.Webcam)
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.padding(horizontal = TiledGutter)) { TiledTopBar("Webcam", onBack, context = d.name) }
        if (!d.online && !live) {
            Box(Modifier.padding(horizontal = TiledGutter)) { NotReachable(d, "The webcam controls") }
        } else {
            WebcamPanel(d.id, startNow)
        }
    }
}

/**
 * The webcam of the phone. The phone camera becomes a webcam named Flux
 * Camera on the computer. The preview shows what the computer gets, with
 * the same shape, mirror, and colors. The settings open below the
 * preview, so the preview shows each change. While [startNow] is true,
 * the panel starts the stream with the saved settings, as Start webcam
 * does.
 */
@Composable
fun WebcamPanel(deviceId: String, startNow: MutableState<Boolean>) {
    val permission = rememberCameraPermission()
    if (!permission.granted) {
        CameraRationale(onAllow = permission.request, onSettings = permission.openSettings, onPhoto = null, what = "use this phone as a webcam")
        return
    }

    val context = LocalContext.current
    // The controller of the app. A running stream keeps it, with its settings, after this screen closes.
    val controller = remember { WebcamHost.controller(context) }
    val config by WebcamSettings.config.collectAsState()
    val caps by WebcamSettings.caps.collectAsState()
    val status by WebcamSession.status.collectAsState()
    val cameraError by controller.cameraError.collectAsState()
    var rotation by rememberSaveable { mutableIntStateOf(controller.extraRotation) }
    var settingsOpen by rememberSaveable { mutableStateOf(false) }
    val pcName = remember(deviceId) { FluxCore.device(deviceId)?.identity?.deviceName ?: "the computer" }

    // "Also send the microphone": the microphone streams while the webcam
    // is live. WebcamHost starts it, and stops it when the webcam stops.
    val withMic by MicSettings.withWebcam.collectAsState()
    fun hasMicPermission() = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    // True after the user refused the microphone. The settings then offer the app settings.
    var micRefused by rememberSaveable { mutableStateOf(false) }
    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        MicSettings.setWithWebcam(context.applicationContext, ok)
        micRefused = !ok
    }
    val setWithMic = { on: Boolean ->
        if (on && !hasMicPermission()) askMic.launch(Manifest.permission.RECORD_AUDIO)
        else MicSettings.setWithWebcam(context.applicationContext, on)
    }
    DisposableEffect(controller) {
        WebcamHost.show(controller)
        onDispose { WebcamHost.hide(controller) }
    }
    LaunchedEffect(rotation) { controller.extraRotation = rotation }
    // A tap on Start in a stream request starts the stream with the same path as Start webcam.
    StartAfterTap(startNow, ready = cameraError == null, StreamKind.Webcam, key = config) {
        if (!WebcamSession.runsTo(deviceId)) controller.goLive(deviceId)
    }

    // A stream keeps running when the app goes to the background. Without
    // a stream, the camera closes, so that other apps can use it.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> WebcamHost.setVisible(false)
                Lifecycle.Event.ON_START -> WebcamHost.setVisible(true)
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // The screen stays on while it shows the preview of a stream.
    val view = LocalView.current
    DisposableEffect(status.active) {
        view.keepScreenOn = status.active
        onDispose { view.keepScreenOn = false }
    }

    Column(
        Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Box(
                Modifier.heightIn(max = if (settingsOpen) 220.dp else 360.dp).aspectRatio(config.width.toFloat() / config.height)
                    .clip(RoundedCornerShape(24.dp)).background(Palette.pad),
            ) {
                AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { ctx ->
                        TextureView(ctx).apply {
                            surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                                override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) =
                                    controller.attachPreview(texture, width, height)

                                override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) =
                                    controller.attachPreview(texture, width, height)

                                override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
                                    controller.detachPreview(texture)
                                    return true
                                }

                                override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = Unit
                            }
                        }
                    },
                )
                if (status.phase == WebcamSession.Phase.Live) {
                    // Green marks a live camera, as the privacy dot of Android does. Red is for errors.
                    Surface(
                        Modifier.align(Alignment.TopStart).padding(12.dp),
                        shape = RoundedCornerShape(8.dp),
                        color = Tn.green,
                        contentColor = Tn.onAccent,
                    ) {
                        Row(Modifier.padding(horizontal = 10.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Sym(Ic.live, size = 10.dp)
                            T("LIVE", size = 12, color = Tn.onAccent, weight = FontWeight.SemiBold, family = Mono)
                        }
                    }
                }
            }
        }

        val active = status.active
        val canStart = cameraError == null || active
        val toggleLive = { if (active) controller.stopLive() else controller.goLive(deviceId) }
        if (settingsOpen) {
            // The settings get the most room. Rotate and the camera switch
            // move into the panel, and the status shows only when it matters.
            if (active || status.phase == WebcamSession.Phase.Error || cameraError != null) {
                StatusLine(status, cameraError, pcName, config)
            }
            Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                LiveButton(active, canStart, Modifier.weight(1f).fillMaxHeight(), onClick = toggleLive)
                FluxButton("Done", { settingsOpen = false }, Modifier.fillMaxHeight(), kind = ButtonKind.Tonal, icon = Ic.check)
            }
            WebcamSettingsPanel(
                config, caps, streaming = active,
                onRotate = { rotation = (rotation + 90) % 360 },
                withMic = withMic,
                onWithMic = setWithMic,
                micRefused = micRefused,
                modifier = Modifier.weight(1f),
            )
        } else {
            StatusLine(status, cameraError, pcName, config)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (caps.cameras.size > 1) {
                    ActionChip(Ic.switchCamera, if (config.camera == "front") "Back camera" else "Front camera") {
                        WebcamSettings.update { it.copy(camera = if (it.camera == "front") "back" else "front") }
                    }
                }
                ActionChip(Ic.rotate, "Rotate") { rotation = (rotation + 90) % 360 }
                ActionChip(Ic.tune, "Settings") { settingsOpen = true }
            }
            LiveButton(active, canStart, Modifier.fillMaxWidth().heightIn(min = 64.dp), onClick = toggleLive)
            T(
                "Apps on $pcName see this phone as Flux Camera. The webcam keeps streaming when you leave this screen.",
                Modifier.fillMaxWidth(), size = 13, color = Tn.sub, align = TextAlign.Center, lineHeight = 1.35f,
            )
        }
    }
}

/** Start webcam, or Stop webcam while the phone streams. Stop is a tonal button, because red is for errors. */
@Composable
private fun LiveButton(active: Boolean, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    FluxButton(
        if (active) "Stop webcam" else "Start webcam", onClick, modifier,
        kind = if (active) ButtonKind.Tonal else ButtonKind.Filled,
        icon = if (active) Ic.stop else Ic.videocam,
        enabled = enabled,
    )
}

@Composable
private fun StatusLine(status: WebcamSession.Status, cameraError: String?, pcName: String, config: WebcamConfig) {
    val scheme = MaterialTheme.colorScheme
    val body = MaterialTheme.typography.bodyMedium
    when {
        cameraError != null -> Text(cameraError, style = body, color = scheme.error)
        status.phase == WebcamSession.Phase.Error -> Text(status.message, style = body, color = scheme.error)
        status.phase == WebcamSession.Phase.Live -> Column {
            Text(status.message, style = MaterialTheme.typography.titleSmall)
            Text(
                listOf(status.device, "${config.width} × ${config.height}").filter { it.isNotEmpty() }.joinToString(" · "),
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = Mono),
                color = scheme.onSurfaceVariant,
            )
        }
        status.message.isNotEmpty() -> Text(status.message, style = body, color = scheme.onSurfaceVariant)
        else -> Text("Ready. Press Start webcam to use this phone as a webcam on $pcName.", style = body, color = scheme.onSurfaceVariant)
    }
}

/** All webcam settings, in a panel that scrolls. The computer can change the same settings. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WebcamSettingsPanel(
    config: WebcamConfig,
    caps: WebcamCaps,
    streaming: Boolean,
    onRotate: () -> Unit,
    withMic: Boolean,
    onWithMic: (Boolean) -> Unit,
    micRefused: Boolean,
    modifier: Modifier = Modifier,
) {
    fun set(change: (WebcamConfig) -> WebcamConfig) = WebcamSettings.update(change)
    Column(
        modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("The computer can change these settings too.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

        Section("Shape") {
            FlowRow(Modifier.selectableGroup(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                for (a in caps.aspects) Choice(a, selected = a == config.aspect) { set { it.copy(aspect = a) } }
            }
        }
        Section("Quality") {
            FlowRow(
                Modifier.selectableGroup(),
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
                itemVerticalAlignment = Alignment.CenterVertically,
            ) {
                for (r in caps.resolutions) Choice("${r}p", selected = r == config.resolution) { set { it.copy(resolution = r) } }
                Text("${config.width} × ${config.height}", style = MaterialTheme.typography.bodySmall.copy(fontFamily = Mono), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (streaming) Text("A new shape or quality starts the stream again.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Section("Camera") {
            FlowRow(Modifier.selectableGroup(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (caps.cameras.size > 1) {
                    for (c in caps.cameras) Choice(c.replaceFirstChar { it.uppercase() }, selected = c == config.camera) { set { it.copy(camera = c) } }
                }
                ActionChip(Ic.rotate, "Rotate", onRotate)
            }
        }
        Row(
            Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(value = config.mirror, role = Role.Switch) { on -> set { it.copy(mirror = on) } },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Mirror", style = MaterialTheme.typography.bodyLarge)
                Text("Flip the image from left to right", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Switch(checked = config.mirror, onCheckedChange = null)
        }
        Row(
            Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(value = withMic, role = Role.Switch) { on -> onWithMic(on) },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Also send the microphone", style = MaterialTheme.typography.bodyLarge)
                Text("Apps on the computer also get Flux Microphone", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Switch(checked = withMic, onCheckedChange = null)
        }
        if (micRefused && !withMic) PermissionNotice("The webcam sends the microphone only with access to it. Allow it in the app settings.")
        if (caps.zoomMax > 1f) {
            SliderRow("Zoom", config.zoom, 1f..caps.zoomMax, "%.1f×".format(config.zoom)) { v -> set { it.copy(zoom = v) } }
        }
        if (caps.exposureMax > caps.exposureMin) {
            // The phone rounds the value to the exposure step of the camera.
            SliderRow("Exposure", config.exposure, caps.exposureMin..caps.exposureMax, "%+.1f EV".format(config.exposure)) { v ->
                set { it.copy(exposure = v) }
            }
        }
        if (caps.whiteBalance.size > 1) {
            Section("White balance") {
                FlowRow(Modifier.selectableGroup(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (w in caps.whiteBalance) {
                        Choice(w.replaceFirstChar { it.uppercase() }, selected = w == config.whiteBalance) { set { it.copy(whiteBalance = w) } }
                    }
                }
            }
        }
        SliderRow("Brightness", config.brightness, -1f..1f, "%+.2f".format(config.brightness)) { v -> set { it.copy(brightness = v) } }
        SliderRow("Contrast", config.contrast, 0f..2f, "%.2f".format(config.contrast)) { v -> set { it.copy(contrast = v) } }
        SliderRow("Saturation", config.saturation, 0f..2f, "%.2f".format(config.saturation)) { v -> set { it.copy(saturation = v) } }
        SliderRow("Warmth", config.warmth, -1f..1f, warmthLabel(config.warmth)) { v -> set { it.copy(warmth = v) } }
        FluxButton("Reset image", { set { it.reset() } }, kind = ButtonKind.Outlined, icon = Ic.refresh)
    }
}

private fun warmthLabel(v: Float): String = when {
    v <= -0.01f -> "Cooler %.2f".format(-v)
    v >= 0.01f -> "Warmer %.2f".format(v)
    else -> "Neutral"
}

/** A group of settings under a label. The label is a heading for TalkBack. */
@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TileLabel(title, Modifier.semantics { heading() })
        content()
    }
}

@Composable
private fun SliderRow(
    title: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    label: String,
    steps: Int = 0,
    onChange: (Float) -> Unit,
) {
    Column {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
            Text(label, style = MaterialTheme.typography.bodySmall.copy(fontFamily = Mono), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Slider(
            value = value.coerceIn(range.start, range.endInclusive), onValueChange = onChange, valueRange = range, steps = steps,
            modifier = Modifier.semantics { contentDescription = title },
        )
    }
}

/** 1 choice of a setting, such as a shape or a white balance mode. */
@Composable
private fun Choice(label: String, selected: Boolean, onClick: () -> Unit) {
    ChoiceChip(label, selected, onClick)
}

/** An action with an icon, such as Rotate. */
@Composable
private fun ActionChip(@DrawableRes icon: Int, label: String, onClick: () -> Unit) {
    FluxButton(label, onClick, kind = ButtonKind.Tonal, icon = icon)
}
