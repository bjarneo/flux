package org.omarchy.flux.webcam

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.mic.MicSession
import org.omarchy.flux.mic.MicSettings

/**
 * How long the camera stays open after a stream ends. A new frame size
 * stops the stream and starts it again within this time.
 */
private const val IDLE_MS = 1_500L

/**
 * Holds the 1 [WebcamController] of the app. The Webcam screen shows its
 * preview. A stream keeps the controller and the camera after the screen
 * closes and while Flux is in the background. Without a stream, the
 * camera closes when the screen is hidden, and the controller goes away
 * when no Webcam screen shows it. The host also starts and stops the
 * microphone with the webcam, see [MicSettings.withWebcam]. Only the main
 * thread uses this object.
 */
object WebcamHost {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var started = false
    private var controller: WebcamController? = null
    private var settings: Job? = null
    private var idle: Job? = null

    /** The Webcam screens in the composition. */
    private var screens = 0

    /** True while a Webcam screen is visible. */
    private var visible = false

    /** The computer of the microphone that the webcam started, or null. */
    private var micTarget: String? = null

    /** Watches the stream. [org.omarchy.flux.FluxApp] calls it when the app starts. Later calls do nothing. */
    fun start(context: Context) {
        if (started) return
        started = true
        val c = context.applicationContext
        WebcamSettings.load(c)
        MicSettings.load(c)
        scope.launch {
            combine(WebcamSession.status, MicSettings.withWebcam, ::Pair).collect { (s, withMic) -> onStatus(c, s, withMic) }
        }
    }

    /** Returns the controller of the app. It makes a new one when none exists. */
    fun controller(context: Context): WebcamController {
        start(context)
        controller?.let { return it }
        val c = WebcamController(context.applicationContext)
        controller = c
        // The settings also apply while no screen shows the webcam, for example a change from the computer.
        settings = scope.launch { WebcamSettings.config.collect { c.apply(it) } }
        return c
    }

    /** A Webcam screen with [c] entered the composition. */
    fun show(c: WebcamController) {
        if (c === controller) screens++
    }

    /** A Webcam screen with [c] left the composition. Without a stream, the controller goes away with the last screen. */
    fun hide(c: WebcamController) {
        if (c !== controller) return
        screens = (screens - 1).coerceAtLeast(0)
        if (screens == 0 && !WebcamSession.status.value.active) close()
    }

    /**
     * A Webcam screen became visible or hidden. Without a stream, a hidden
     * screen closes the camera, so that other apps can use it.
     */
    fun setVisible(on: Boolean) {
        visible = on
        val c = controller ?: return
        if (on) c.resume() else if (!WebcamSession.status.value.active) c.pause()
    }

    private fun onStatus(context: Context, s: WebcamSession.Status, withMic: Boolean) {
        val target = s.deviceId.takeIf { s.active }
        // With "Also send the microphone", the microphone runs while the webcam is live.
        // The host stops only the microphone that it started.
        val mic = micTarget
        if (mic != null && (target != mic || !withMic)) {
            if (MicSession.runsTo(mic)) MicSession.stop(FluxCore, notify = true)
            micTarget = null
        }
        if (target != null && s.phase == WebcamSession.Phase.Live && withMic && micTarget == null && hasMic(context) && !MicSession.status.value.active) {
            MicSession.start(FluxCore, target)
            micTarget = target
        }
        idle?.cancel()
        idle = null
        if (target != null) return
        idle = scope.launch {
            delay(IDLE_MS)
            if (WebcamSession.status.value.active) return@launch
            if (screens == 0) close() else if (!visible) controller?.pause()
        }
    }

    private fun close() {
        val c = controller ?: return
        controller = null
        settings?.cancel()
        settings = null
        c.release()
    }

    private fun hasMic(context: Context) =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
}
