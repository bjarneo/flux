package org.omarchy.flux.mic

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.ui.ButtonKind
import org.omarchy.flux.ui.FluxButton
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.IconBadge
import org.omarchy.flux.ui.NotReachable
import org.omarchy.flux.ui.T
import org.omarchy.flux.ui.TileLabel
import org.omarchy.flux.ui.TiledGutter
import org.omarchy.flux.ui.TiledTopBar
import org.omarchy.flux.ui.Tn
import org.omarchy.flux.ui.openAppSettings

/**
 * The Mic screen. Apps on the computer see this phone as Flux Microphone
 * while the stream runs. The stream stops when the screen closes or the
 * app goes to the background.
 */
@Composable
fun MicScreen(d: DeviceUi, onBack: () -> Unit) {
    val context = LocalContext.current
    fun has() = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    var granted by remember { mutableStateOf(has()) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    // The screen asks for the microphone 1 time, when the computer is first reachable.
    // After a refusal, the Allow microphone button asks again.
    var asked by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(d.online) {
        if (!asked && !granted && d.online) {
            asked = true
            ask.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    val status by MicSession.status.collectAsState()
    val level by MicSession.level.collectAsState()
    val shown by animateFloatAsState(level, tween(90), label = "level")
    val mine = status.deviceId == null || status.deviceId == d.id
    val active = status.active && status.deviceId == d.id

    // The stream stops when the app goes to the background and when the
    // screen closes. Android gives the microphone only to a visible app.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) granted = has()
            if (event == Lifecycle.Event.ON_STOP && MicSession.status.value.active) MicSession.stop(FluxCore, notify = true)
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            if (MicSession.status.value.active) MicSession.stop(FluxCore, notify = true)
        }
    }
    val view = LocalView.current
    DisposableEffect(active) {
        view.keepScreenOn = active
        onDispose { view.keepScreenOn = false }
    }

    Column(Modifier.fillMaxSize().padding(horizontal = TiledGutter)) {
        TiledTopBar("Mic", onBack, context = d.name)
        // A stream that runs keeps its Stop button, also when the link drops.
        if (!d.online && !active) {
            NotReachable(d, "The mic controls")
            return@Column
        }
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
        ) {
            // Green marks a live microphone, as the privacy dot of Android does.
            IconBadge(
                if (active) Ic.micFill else Ic.mic,
                Modifier.scale(1f + shown * 0.25f),
                container = if (active) Tn.green else Tn.tile,
                content = if (active) Tn.onAccent else Tn.sub,
                size = 112.dp,
            )
            Spacer(Modifier.height(4.dp))
            if (!granted) {
                T("Allow the microphone", size = 20, weight = FontWeight.SemiBold, align = TextAlign.Center)
                T(
                    "Flux uses the microphone only while this screen is open and the mic runs.",
                    size = 14, color = Tn.sub, align = TextAlign.Center, lineHeight = 1.35f,
                )
                FluxButton("Allow microphone", { ask.launch(Manifest.permission.RECORD_AUDIO) }, icon = Ic.mic)
                FluxButton("Open app settings", { openAppSettings(context) }, kind = ButtonKind.Outlined, icon = Ic.settings)
                return@Column
            }
            val error = status.phase == MicSession.Phase.Error && mine
            T(
                when {
                    active -> status.message
                    mine && status.message.isNotEmpty() -> status.message
                    else -> "Press Start the mic to use this phone as a microphone on ${d.name}."
                },
                size = 16, color = if (error) Tn.red else Tn.text, align = TextAlign.Center, lineHeight = 1.35f,
            )
            if (error && status.message.contains("app settings")) {
                FluxButton("Open app settings", { openAppSettings(context) }, kind = ButtonKind.Text, icon = Ic.settings)
            }
            Column(Modifier.widthIn(max = 320.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                TileLabel("Input level")
                LinearProgressIndicator(
                    progress = { if (active) shown else 0f },
                    modifier = Modifier.fillMaxWidth().height(8.dp).semantics { contentDescription = "Input level" },
                    color = Tn.green, trackColor = Tn.line, drawStopIndicator = {},
                )
            }
            Spacer(Modifier.height(4.dp))
            FluxButton(
                if (active) "Stop the mic" else "Start the mic",
                { if (active) MicSession.stop(FluxCore, notify = true) else MicSession.start(FluxCore, d.id) },
                Modifier.widthIn(min = 220.dp).heightIn(min = 56.dp),
                kind = if (active) ButtonKind.Tonal else ButtonKind.Filled,
                icon = if (active) Ic.stop else Ic.micFill,
            )
            T(
                "Apps on ${d.name} see this phone as Flux Microphone. Keep this screen open while you talk.",
                size = 13, color = Tn.sub, align = TextAlign.Center, lineHeight = 1.35f,
            )
        }
    }
}
