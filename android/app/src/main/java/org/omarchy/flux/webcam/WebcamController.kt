package org.omarchy.flux.webcam

import android.content.Context
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.OrientationEventListener
import android.view.Surface
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.omarchy.flux.core.FluxCore
import java.io.OutputStream
import kotlin.math.roundToInt

private const val TAG = "FluxWebcam"

/** The shortest time between 2 config messages to the computer, while a slider moves. */
private const val CONFIG_INTERVAL_MS = 120L

/**
 * Connects the camera, the GL renderer, the encoder, and the network
 * session for 1 Webcam screen. The screen creates it, calls [apply] for
 * each settings change, and calls [release] when it closes.
 */
class WebcamController(context: Context) : WebcamSession.Listener {
    private val renderer = GlRenderer()
    private val camera = CameraSource(context)
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var encoder: H264Encoder? = null
    private var cameraSurface: Surface? = null
    private var applied: WebcamConfig? = null
    private var choice: CameraSource.Choice? = null
    private var sendPending = false
    private val sendConfig = Runnable {
        sendPending = false
        WebcamSession.sendConfig(FluxCore)
    }

    private val _cameraError = MutableStateFlow<String?>(null)
    /** A problem with the camera itself, or null. */
    val cameraError: StateFlow<String?> = _cameraError

    private val orientation = object : OrientationEventListener(context) {
        override fun onOrientationChanged(degrees: Int) {
            if (degrees != ORIENTATION_UNKNOWN) renderer.deviceOrientation = degrees
        }
    }

    init {
        if (orientation.canDetectOrientation()) orientation.enable()
    }

    var extraRotation: Int
        get() = renderer.extraRotation
        set(value) { renderer.extraRotation = value }

    /**
     * Applies new settings. The image values change at once. A new camera
     * switches without a new stream. A new frame size starts the stream
     * again. The computer gets the full settings after each change.
     */
    fun apply(config: WebcamConfig) {
        val old = applied
        applied = config
        renderer.mirror = config.mirror
        renderer.outputAspect = config.width.toFloat() / config.height
        renderer.color = GlRenderer.Color(config.brightness, config.contrast, config.saturation, config.warmth)
        if (old == null || old.camera != config.camera) {
            openCamera(config)
            encoder?.requestKeyFrame()
        } else {
            camera.setControls(controlsFor(config))
        }
        if (old == null) return
        if (old.restartsStream(config) && WebcamSession.status.value.active) {
            // The new "start" carries the new size, and the config follows it.
            WebcamSession.restart(FluxCore, config.width, config.height)
        } else if (!sendPending) {
            sendPending = true
            main.postDelayed(sendConfig, CONFIG_INTERVAL_MS)
        }
    }

    /** Opens the camera again, for example when the app comes back to the front. */
    fun resumeCamera() {
        applied?.let { openCamera(it) }
    }

    private fun openCamera(config: WebcamConfig) {
        val front = config.camera == "front"
        val c = runCatching { camera.choose(front) }.getOrNull()
        if (c == null) {
            _cameraError.value = "This phone has no usable camera"
            return
        }
        choice = c
        _cameraError.value = null
        WebcamSettings.setCaps(
            WebcamCaps(
                zoomMax = c.zoomMax,
                exposureMin = c.exposureRange.lower * c.exposureStep,
                exposureMax = c.exposureRange.upper * c.exposureStep,
                exposureStep = c.exposureStep,
                whiteBalance = c.whiteBalance,
                cameras = camera.facings(),
            ),
        )
        camera.setControls(controlsFor(WebcamSettings.config.value))
        renderer.front = c.facing == "front"
        renderer.sensorOrientation = c.sensorOrientation
        renderer.start(c.size) { texture ->
            val surface = cameraSurface ?: Surface(texture).also { cameraSurface = it }
            camera.open(c, surface) { message -> _cameraError.value = message }
        }
    }

    private fun controlsFor(config: WebcamConfig): CameraSource.Controls {
        val step = choice?.exposureStep ?: 0f
        return CameraSource.Controls(
            zoom = config.zoom,
            exposureIndex = if (step > 0f) (config.exposure / step).roundToInt() else 0,
            awbMode = CameraSource.AWB_MODES[config.whiteBalance] ?: CameraSource.AWB_MODES.getValue("auto"),
        )
    }

    /** Stops the camera, for example when the app goes to the background. */
    fun stopCamera() = camera.close()

    fun attachPreview(texture: SurfaceTexture, width: Int, height: Int) = renderer.setPreview(texture, width, height)

    fun detachPreview() = renderer.setPreview(null, 0, 0)

    /** Starts the stream to the computer with the current settings. */
    fun goLive(deviceId: String) {
        val c = applied ?: WebcamSettings.config.value
        WebcamSession.start(FluxCore, deviceId, c.width, c.height, this)
    }

    /** Stops the stream and tells the computer. */
    fun stopLive() = WebcamSession.stop(FluxCore, notify = true)

    override fun onConnected(out: OutputStream, width: Int, height: Int) {
        try {
            val enc = H264Encoder(width, height, bitrateFor(width, height), out) { message ->
                WebcamSession.stop(FluxCore, notify = true, WebcamSession.Status(WebcamSession.Phase.Error, message))
            }
            encoder = enc
            renderer.setEncoder(enc.inputSurface, width, height)
            enc.requestKeyFrame()
        } catch (e: Exception) {
            Log.w(TAG, "encoder failed", e)
            WebcamSession.stop(FluxCore, notify = true, WebcamSession.Status(WebcamSession.Phase.Error, "The video encoder did not start: ${e.message}"))
        }
    }

    override fun onEnded() {
        // Stop drawing into the encoder before the encoder frees its surface.
        renderer.setEncoder(null, 0, 0)
        encoder?.release()
        encoder = null
    }

    /** Stops everything. The controller cannot start again. */
    fun release() {
        main.removeCallbacks(sendConfig)
        stopLive()
        orientation.disable()
        camera.release()
        renderer.release()
        cameraSurface?.release()
        cameraSurface = null
    }
}
