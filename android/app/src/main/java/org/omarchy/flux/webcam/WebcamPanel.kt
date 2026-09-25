package org.omarchy.flux.webcam

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import org.omarchy.flux.mic.MicSession
import org.omarchy.flux.mic.MicSettings
import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.ui.semantics.Role
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.Sym
import android.graphics.SurfaceTexture
import android.view.TextureView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.camera.CameraRationale
import org.omarchy.flux.camera.rememberCameraPermission
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.ui.Mono
import org.omarchy.flux.ui.Palette
import org.omarchy.flux.ui.T
import kotlin.math.roundToInt

/**
 * The Webcam mode of the Camera screen. The phone camera becomes a webcam
 * named Flux Camera on the computer. The preview shows what the computer
 * gets, with the same shape, mirror, and colors. The settings open below
 * the preview, so the preview shows each change.
 */
@Composable
fun WebcamPanel(deviceId: String) {
    val permission = rememberCameraPermission()
    if (!permission.granted) {
        CameraRationale(onAllow = permission.request, onSettings = permission.openSettings, onPhoto = null, what = "use this phone as a webcam")
        return
    }

    val context = LocalContext.current
    LaunchedEffect(context) { WebcamSettings.load(context.applicationContext) }
    val controller = remember { WebcamController(context.applicationContext) }
    val config by WebcamSettings.config.collectAsState()
    val caps by WebcamSettings.caps.collectAsState()
    val status by WebcamSession.status.collectAsState()
    val cameraError by controller.cameraError.collectAsState()
    var rotation by rememberSaveable { mutableIntStateOf(0) }
    var settingsOpen by rememberSaveable { mutableStateOf(false) }
    val pcName = remember(deviceId) { FluxCore.device(deviceId)?.identity?.deviceName ?: "the computer" }

    // "Also send the microphone": the microphone streams while the webcam
    // is live. The webcam stops it when the webcam stops.
    LaunchedEffect(context) { MicSettings.load(context.applicationContext) }
    val withMic by MicSettings.withWebcam.collectAsState()
    var micByWebcam by remember { mutableStateOf(false) }
    fun hasMicPermission() = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        MicSettings.setWithWebcam(context.applicationContext, ok)
        if (!ok) FluxCore.toast("Allow the microphone for Flux to send it with the webcam")
    }
    val setWithMic = { on: Boolean ->
        if (on && !hasMicPermission()) askMic.launch(Manifest.permission.RECORD_AUDIO)
        else MicSettings.setWithWebcam(context.applicationContext, on)
    }
    LaunchedEffect(status.phase, withMic) {
        val live = status.phase == WebcamSession.Phase.Live
        if (live && withMic && hasMicPermission() && !MicSession.status.value.active) {
            MicSession.start(FluxCore, deviceId)
            micByWebcam = true
        } else if ((!status.active || !withMic) && micByWebcam) {
            MicSession.stop(FluxCore, notify = true)
            micByWebcam = false
        }
    }

    DisposableEffect(controller) {
        onDispose {
            controller.release()
            if (micByWebcam) MicSession.stop(FluxCore, notify = true)
        }
    }
    LaunchedEffect(config) { controller.apply(config) }
    LaunchedEffect(rotation) { controller.extraRotation = rotation }

    // The stream stops when the app goes to the background, and the camera
    // closes, so that other apps can use it.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> {
                    controller.stopLive()
                    controller.stopCamera()
                }
                Lifecycle.Event.ON_START -> controller.resumeCamera()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // The screen stays on while the phone streams.
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
                                    controller.detachPreview()
                                    return true
                                }

                                override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = Unit
                            }
                        }
                    },
                )
                if (status.phase == WebcamSession.Phase.Live) {
                    Surface(
                        Modifier.align(Alignment.TopStart).padding(12.dp),
                        shape = RoundedCornerShape(8.dp),
                        color = MaterialTheme.colorScheme.error,
                        contentColor = MaterialTheme.colorScheme.onError,
                    ) {
                        Row(Modifier.padding(horizontal = 10.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Sym(Ic.live, size = 10.dp)
                            Text("LIVE", style = MaterialTheme.typography.labelMedium)
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
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                LiveButton(active, canStart, Modifier.weight(1f).height(48.dp), onClick = toggleLive)
                FilledTonalButton(onClick = { settingsOpen = false }, modifier = Modifier.height(48.dp)) {
                    Sym(Ic.check, size = ButtonDefaults.IconSize)
                    Spacer(Modifier.size(ButtonDefaults.IconSpacing))
                    Text("Done")
                }
            }
            WebcamSettingsPanel(
                config, caps, streaming = active,
                onRotate = { rotation = (rotation + 90) % 360 },
                withMic = withMic,
                onWithMic = setWithMic,
                modifier = Modifier.weight(1f),
            )
        } else {
            StatusLine(status, cameraError, pcName, config)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (caps.cameras.size > 1) {
                    ActionChip(Ic.switchCamera, if (config.camera == "front") "Back camera" else "Front camera") {
                        WebcamSettings.update { it.copy(camera = if (it.camera == "front") "back" else "front") }
                    }
                }
                ActionChip(Ic.rotate, "Rotate") { rotation = (rotation + 90) % 360 }
                ActionChip(Ic.tune, "Settings") { settingsOpen = true }
            }
            LiveButton(active, canStart, Modifier.fillMaxWidth().height(64.dp), onClick = toggleLive)
            Text(
                "Apps on $pcName see this phone as Flux Camera. Keep this screen open while you stream.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/** Start webcam, or Stop webcam while the phone streams. */
@Composable
private fun LiveButton(active: Boolean, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Button(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        colors = if (active) ButtonDefaults.buttonColors(containerColor = scheme.errorContainer, contentColor = scheme.onErrorContainer) else ButtonDefaults.buttonColors(),
    ) {
        Sym(if (active) Ic.stop else Ic.videocam)
        Spacer(Modifier.size(12.dp))
        Text(if (active) "Stop webcam" else "Start webcam", style = MaterialTheme.typography.titleMedium)
    }
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
    modifier: Modifier = Modifier,
) {
    fun set(change: (WebcamConfig) -> WebcamConfig) = WebcamSettings.update(change)
    Column(
        modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("The computer can change these settings too.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

        Section("Shape") {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                for (a in caps.aspects) Choice(a, selected = a == config.aspect) { set { it.copy(aspect = a) } }
            }
        }
        Section("Quality") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                for (r in caps.resolutions) Choice("${r}p", selected = r == config.resolution) { set { it.copy(resolution = r) } }
                Text("${config.width} × ${config.height}", style = MaterialTheme.typography.bodySmall.copy(fontFamily = Mono), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (streaming) Text("A new shape or quality starts the stream again.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Section("Camera") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (caps.cameras.size > 1) {
                    for (c in caps.cameras) Choice(c.replaceFirstChar { it.uppercase() }, selected = c == config.camera) { set { it.copy(camera = c) } }
                }
                ActionChip(Ic.rotate, "Rotate", onRotate)
            }
        }
        Row(
            Modifier.fillMaxWidth().toggleable(value = config.mirror, role = Role.Switch) { on -> set { it.copy(mirror = on) } },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Mirror", style = MaterialTheme.typography.bodyLarge)
                Text("Flip the image from left to right", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Switch(checked = config.mirror, onCheckedChange = null)
        }
        Row(
            Modifier.fillMaxWidth().toggleable(value = withMic, role = Role.Switch) { on -> onWithMic(on) },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Also send the microphone", style = MaterialTheme.typography.bodyLarge)
                Text("Apps on the computer also get Flux Microphone", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Switch(checked = withMic, onCheckedChange = null)
        }
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
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
        OutlinedButton(onClick = { set { it.reset() } }, contentPadding = ButtonDefaults.ButtonWithIconContentPadding) {
            Sym(Ic.refresh, size = ButtonDefaults.IconSize)
            Spacer(Modifier.size(ButtonDefaults.IconSpacing))
            Text("Reset image")
        }
    }
}

private fun warmthLabel(v: Float): String = when {
    v <= -0.01f -> "Cooler %.2f".format(-v)
    v >= 0.01f -> "Warmer %.2f".format(v)
    else -> "Neutral"
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
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
        Slider(value = value.coerceIn(range.start, range.endInclusive), onValueChange = onChange, valueRange = range, steps = steps)
    }
}

/** 1 choice of a setting, such as a shape or a white balance mode. */
@Composable
private fun Choice(label: String, selected: Boolean, onClick: () -> Unit) {
    FilterChip(selected = selected, onClick = onClick, label = { Text(label) })
}

/** An action with an icon, such as Rotate. */
@Composable
private fun ActionChip(@DrawableRes icon: Int, label: String, onClick: () -> Unit) {
    AssistChip(onClick = onClick, label = { Text(label) }, leadingIcon = { Sym(icon, size = AssistChipDefaults.IconSize) })
}
