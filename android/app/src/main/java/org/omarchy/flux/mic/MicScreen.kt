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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.IconBadge
import org.omarchy.flux.ui.Sym
import org.omarchy.flux.ui.TopBar

/**
 * The Microphone screen. Apps on the computer see this phone as Flux
 * Microphone while the stream runs. The stream stops when the screen
 * closes or the app goes to the background.
 */
@Composable
fun MicScreen(d: DeviceUi, onBack: () -> Unit) {
    val context = LocalContext.current
    fun has() = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    var granted by remember { mutableStateOf(has()) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    LaunchedEffect(Unit) { if (!granted) ask.launch(Manifest.permission.RECORD_AUDIO) }

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

    val scheme = MaterialTheme.colorScheme
    Column(Modifier.fillMaxSize()) {
        TopBar("Microphone", onBack, subtitle = "For apps on ${d.name}")
        Column(
            Modifier.fillMaxSize().padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
        ) {
            IconBadge(
                if (active) Ic.micFill else Ic.mic,
                Modifier.scale(1f + shown * 0.25f),
                container = if (active) scheme.primaryContainer else scheme.secondaryContainer,
                content = if (active) scheme.onPrimaryContainer else scheme.onSecondaryContainer,
                size = 112.dp,
            )
            Spacer(Modifier.height(4.dp))
            if (!granted) {
                Text("Allow the microphone", style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
                Text(
                    "Flux uses the microphone only while this screen is open and you press Start.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = scheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Button(onClick = { ask.launch(Manifest.permission.RECORD_AUDIO) }) { Text("Allow microphone") }
                OutlinedButton(onClick = { org.omarchy.flux.camera.openAppSettings(context) }) { Text("Open app settings") }
                return@Column
            }
            Text(
                when {
                    active -> status.message
                    mine && status.message.isNotEmpty() -> status.message
                    else -> "Ready. Press Start to use this phone as a microphone on ${d.name}."
                },
                style = MaterialTheme.typography.bodyLarge,
                color = if (status.phase == MicSession.Phase.Error && mine) scheme.error else scheme.onSurface,
                textAlign = TextAlign.Center,
            )
            Column(Modifier.widthIn(max = 320.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Input level", style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant)
                LinearProgressIndicator(progress = { if (active) shown else 0f }, modifier = Modifier.fillMaxWidth().height(8.dp))
            }
            Spacer(Modifier.height(4.dp))
            Button(
                onClick = { if (active) MicSession.stop(FluxCore, notify = true) else MicSession.start(FluxCore, d.id) },
                modifier = Modifier.height(56.dp).widthIn(min = 220.dp),
                colors = if (active) ButtonDefaults.buttonColors(containerColor = scheme.errorContainer, contentColor = scheme.onErrorContainer) else ButtonDefaults.buttonColors(),
            ) {
                Sym(if (active) Ic.stop else Ic.micFill)
                Spacer(Modifier.size(12.dp))
                Text(if (active) "Stop microphone" else "Start microphone", style = MaterialTheme.typography.titleMedium)
            }
            Text(
                "Apps on ${d.name} see this phone as Flux Microphone. Keep this screen open while you talk.",
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}
