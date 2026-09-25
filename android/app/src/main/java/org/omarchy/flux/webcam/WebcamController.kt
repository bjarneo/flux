package org.omarchy.flux.webcam

import android.content.Context
import android.graphics.SurfaceTexture
import android.util.Log
import android.view.OrientationEventListener
import android.view.Surface
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.omarchy.flux.core.FluxCore
import java.io.OutputStream

private const val TAG = "FluxWebcam"

/**
 * Connects the camera, the GL renderer, the encoder, and the network
 * session for 1 Webcam screen. The screen creates it and calls [release]
 * when it closes.
 */
class WebcamController(context: Context) : WebcamSession.Listener {
    private val renderer = GlRenderer()
    private val camera = CameraSource(context)
    @Volatile private var encoder: H264Encoder? = null
    @Volatile private var resolution = Resolution.HD
    private var cameraSurface: Surface? = null

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

    /** Opens the front or the back camera. A running stream continues with the new camera. */
    fun startCamera(front: Boolean) {
        val choice = runCatching { camera.choose(front) }.getOrNull()
        if (choice == null) {
            _cameraError.value = "This phone has no usable camera"
            return
        }
        _cameraError.value = null
        renderer.front = front
        renderer.sensorOrientation = choice.sensorOrientation
        renderer.start(choice.size) { texture ->
            val surface = cameraSurface ?: Surface(texture).also { cameraSurface = it }
            camera.open(choice, surface) { message -> _cameraError.value = message }
        }
    }

    /** Stops the camera, for example when the app goes to the background. */
    fun stopCamera() = camera.close()

    fun attachPreview(texture: SurfaceTexture, width: Int, height: Int, front: Boolean) =
        renderer.setPreview(texture, width, height, mirror = front)

    fun detachPreview() = renderer.setPreview(null, 0, 0, mirror = false)

    /** Starts the stream to the computer. */
    fun goLive(deviceId: String, resolution: Resolution) {
        this.resolution = resolution
        WebcamSession.start(FluxCore, deviceId, resolution, this)
    }

    /** Stops the stream and tells the computer. */
    fun stopLive() = WebcamSession.stop(FluxCore, notify = true)

    override fun onConnected(out: OutputStream) {
        try {
            val res = resolution
            val enc = H264Encoder(res, out) { message ->
                WebcamSession.stop(FluxCore, notify = true, WebcamSession.Status(WebcamSession.Phase.Error, message))
            }
            encoder = enc
            renderer.setEncoder(enc.inputSurface, res.width, res.height)
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
        stopLive()
        orientation.disable()
        camera.release()
        renderer.release()
        cameraSurface?.release()
        cameraSurface = null
    }
}
