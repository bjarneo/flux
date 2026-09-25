package org.omarchy.flux.webcam

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
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.rememberModalBottomSheetState
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
 * gets, with the same shape, mirror, and colors.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WebcamPanel(deviceId: String) {
    val permission = rememberCameraPermission()
    if (!permission.granted) {
        CameraRationale(onAllow = permission.request, onSettings = permission.openSettings, onPhoto = null, what = "use this phone as a webcam")
        return
    }

    val context = LocalContext.current
    remember { WebcamSettings.load(context.applicationContext) }
    val controller = remember { WebcamController(context.applicationContext) }
    val config by WebcamSettings.config.collectAsState()
    val caps by WebcamSettings.caps.collectAsState()
    val status by WebcamSession.status.collectAsState()
    val cameraError by controller.cameraError.collectAsState()
    var rotation by rememberSaveable { mutableIntStateOf(0) }
    var settingsOpen by rememberSaveable { mutableStateOf(false) }
    val pcName = remember(deviceId) { FluxCore.device(deviceId)?.identity?.deviceName ?: "the computer" }

    DisposableEffect(controller) { onDispose { controller.release() } }
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
                Modifier.heightIn(max = 360.dp).aspectRatio(config.width.toFloat() / config.height)
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
                    Box(
                        Modifier.align(Alignment.TopStart).padding(12.dp).clip(RoundedCornerShape(8.dp))
                            .background(MaterialTheme.colorScheme.error).padding(horizontal = 10.dp, vertical = 4.dp),
                    ) { T("● LIVE", size = 12, color = MaterialTheme.colorScheme.onError, weight = FontWeight.Medium) }
                }
            }
        }

        StatusLine(status, cameraError, pcName, config)

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (caps.cameras.size > 1) {
                Pill(if (config.camera == "front") "Back camera" else "Front camera") {
                    WebcamSettings.update { it.copy(camera = if (it.camera == "front") "back" else "front") }
                }
            }
            Pill("Rotate") { rotation = (rotation + 90) % 360 }
            Pill("Settings") { settingsOpen = true }
        }

        val active = status.active
        Box(
            Modifier.fillMaxWidth().height(64.dp).clip(RoundedCornerShape(32.dp))
                .background(if (active) MaterialTheme.colorScheme.errorContainer else Palette.accent)
                .clickable(enabled = cameraError == null || active) {
                    if (active) controller.stopLive() else controller.goLive(deviceId)
                },
            contentAlignment = Alignment.Center,
        ) {
            T(
                if (active) "Stop webcam" else "Start webcam",
                size = 18, weight = FontWeight.Medium,
                color = if (active) MaterialTheme.colorScheme.onErrorContainer else Palette.onAccent,
            )
        }
        T(
            "Apps on $pcName see this phone as Flux Camera. Keep this screen open while you stream.",
            color = Palette.hint, size = 12, align = TextAlign.Center, modifier = Modifier.fillMaxWidth(),
        )
    }

    if (settingsOpen) {
        ModalBottomSheet(
            onDismissRequest = { settingsOpen = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        ) { WebcamSettingsSheet(config, caps, streaming = status.active) }
    }
}

@Composable
private fun StatusLine(status: WebcamSession.Status, cameraError: String?, pcName: String, config: WebcamConfig) {
    val error = MaterialTheme.colorScheme.error
    when {
        cameraError != null -> T(cameraError, color = error)
        status.phase == WebcamSession.Phase.Error -> T(status.message, color = error)
        status.phase == WebcamSession.Phase.Live -> Column {
            T(status.message, weight = FontWeight.Medium)
            T(
                listOf(status.device, "${config.width} × ${config.height}").filter { it.isNotEmpty() }.joinToString(" · "),
                color = Palette.secondary, size = 12, family = Mono,
            )
        }
        status.message.isNotEmpty() -> T(status.message, color = Palette.body)
        else -> T("Ready. Start to use this phone as a webcam on $pcName.", color = Palette.body)
    }
}

/** All webcam settings. The computer can change the same settings. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WebcamSettingsSheet(config: WebcamConfig, caps: WebcamCaps, streaming: Boolean) {
    fun set(change: (WebcamConfig) -> WebcamConfig) = WebcamSettings.update(change)
    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            T("Webcam settings", size = 20)
            T("The computer can change these settings too.", color = Palette.secondary, size = 13)
        }

        Section("Shape") {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                for (a in caps.aspects) Pill(a, selected = a == config.aspect) { set { it.copy(aspect = a) } }
            }
        }
        Section("Quality") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                for (r in caps.resolutions) Pill("${r}p", selected = r == config.resolution) { set { it.copy(resolution = r) } }
                T("${config.width} × ${config.height}", color = Palette.secondary, size = 13, family = Mono)
            }
            if (streaming) T("A new shape or quality starts the stream again.", color = Palette.hint, size = 12)
        }
        if (caps.cameras.size > 1) {
            Section("Camera") {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (c in caps.cameras) Pill(c.replaceFirstChar { it.uppercase() }, selected = c == config.camera) { set { it.copy(camera = c) } }
                }
            }
        }
        Row(Modifier.fillMaxWidth().clickable { set { it.copy(mirror = !it.mirror) } }, verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                T("Mirror", size = 16)
                T("Flip the image from left to right", color = Palette.secondary, size = 13)
            }
            Switch(checked = config.mirror, onCheckedChange = { on -> set { it.copy(mirror = on) } })
        }
        if (caps.zoomMax > 1f) {
            SliderRow("Zoom", config.zoom, 1f..caps.zoomMax, "%.1f×".format(config.zoom)) { v -> set { it.copy(zoom = v) } }
        }
        if (caps.exposureMax > caps.exposureMin) {
            val steps = if (caps.exposureStep > 0f) ((caps.exposureMax - caps.exposureMin) / caps.exposureStep).roundToInt() - 1 else 0
            SliderRow("Exposure", config.exposure, caps.exposureMin..caps.exposureMax, "%+.1f EV".format(config.exposure), steps.coerceAtLeast(0)) { v ->
                set { it.copy(exposure = v) }
            }
        }
        if (caps.whiteBalance.size > 1) {
            Section("White balance") {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (w in caps.whiteBalance) {
                        Pill(w.replaceFirstChar { it.uppercase() }, selected = w == config.whiteBalance) { set { it.copy(whiteBalance = w) } }
                    }
                }
            }
        }
        SliderRow("Brightness", config.brightness, -1f..1f, "%+.2f".format(config.brightness)) { v -> set { it.copy(brightness = v) } }
        SliderRow("Contrast", config.contrast, 0f..2f, "%.2f".format(config.contrast)) { v -> set { it.copy(contrast = v) } }
        SliderRow("Saturation", config.saturation, 0f..2f, "%.2f".format(config.saturation)) { v -> set { it.copy(saturation = v) } }
        SliderRow("Warmth", config.warmth, -1f..1f, warmthLabel(config.warmth)) { v -> set { it.copy(warmth = v) } }
        Pill("Reset image") { set { it.reset() } }
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
        T(title, color = Palette.secondary, size = 13, weight = FontWeight.Medium)
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
            T(title, size = 16, modifier = Modifier.weight(1f))
            T(label, color = Palette.secondary, size = 13, family = Mono)
        }
        Slider(value = value.coerceIn(range.start, range.endInclusive), onValueChange = onChange, valueRange = range, steps = steps)
    }
}

@Composable
private fun Pill(label: String, selected: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    val shape = RoundedCornerShape(20.dp)
    val base = Modifier.clip(shape).alpha(if (enabled) 1f else 0.45f)
    val styled = if (selected) base.background(Palette.accentContainer) else base.border(1.dp, Palette.borderStrong, shape)
    Box(styled.clickable(enabled = enabled, onClick = onClick).padding(horizontal = 16.dp, vertical = 9.dp)) {
        T(label, color = if (selected) Palette.onAccentContainer else Palette.text, size = 14, maxLines = 1)
    }
}
