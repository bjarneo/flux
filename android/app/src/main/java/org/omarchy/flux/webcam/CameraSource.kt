package org.omarchy.flux.webcam

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import java.util.concurrent.Executor

private const val TAG = "FluxWebcamCamera"

/**
 * Opens a camera with Camera2 and sends its frames to 1 Surface. Camera2
 * and not CameraX, because the frames go to a GL texture that feeds both
 * the encoder and the preview.
 */
class CameraSource(context: Context) {
    private val manager = context.getSystemService(CameraManager::class.java)
    private val thread = HandlerThread("flux-webcam-camera").apply { start() }
    private val handler = Handler(thread.looper)
    private val executor = Executor { handler.post(it) }
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    @Volatile private var generation = 0

    /** A camera to open, with the facts that the renderer needs. */
    data class Choice(val id: String, val size: Size, val sensorOrientation: Int, val fps: Range<Int>?)

    /** Picks the first camera that faces the user ([front]) or away from the user. */
    fun choose(front: Boolean): Choice? {
        val facing = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        val id = manager.cameraIdList.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == facing }
            ?: manager.cameraIdList.firstOrNull()
            ?: return null
        val c = manager.getCameraCharacteristics(id)
        val sizes = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)?.getOutputSizes(SurfaceTexture::class.java).orEmpty()
        return Choice(id, pickSize(sizes.toList()), c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90, pickFps(c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)))
    }

    /**
     * Opens [choice] and streams to [target]. A camera that another screen
     * still holds is tried again for 2 seconds. [fail] gets a message that
     * the UI can show.
     */
    @SuppressLint("MissingPermission")
    fun open(choice: Choice, target: Surface, fail: (String) -> Unit) {
        val gen = ++generation
        handler.post { closeNow() }
        fun attempt(left: Int) {
            if (gen != generation) return
            try {
                manager.openCamera(choice.id, executor, object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        if (gen != generation) return camera.close()
                        device = camera
                        startSession(camera, choice, target, fail)
                    }

                    override fun onDisconnected(camera: CameraDevice) {
                        camera.close()
                        if (device === camera) device = null
                    }

                    override fun onError(camera: CameraDevice, error: Int) {
                        camera.close()
                        if (device === camera) device = null
                        if (error == ERROR_CAMERA_IN_USE && left > 0) {
                            handler.postDelayed({ attempt(left - 1) }, 300)
                        } else {
                            fail("The camera is not available (error $error)")
                        }
                    }
                })
            } catch (e: Exception) {
                if (left > 0) handler.postDelayed({ attempt(left - 1) }, 300) else fail("Cannot open the camera: ${e.message}")
            }
        }
        handler.post { attempt(6) }
    }

    private fun startSession(camera: CameraDevice, choice: Choice, target: Surface, fail: (String) -> Unit) {
        val output = OutputConfiguration(target).apply {
            // The computer gets the real image. The preview mirrors the front
            // camera on its own.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) mirrorMode = OutputConfiguration.MIRROR_MODE_NONE
        }
        val config = SessionConfiguration(SessionConfiguration.SESSION_REGULAR, listOf(output), executor, object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(s: CameraCaptureSession) {
                if (device !== camera) return s.close()
                session = s
                try {
                    val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                        addTarget(target)
                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                        choice.fps?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
                    }.build()
                    s.setRepeatingRequest(request, null, handler)
                } catch (e: Exception) {
                    fail("The camera stopped: ${e.message}")
                }
            }

            override fun onConfigureFailed(s: CameraCaptureSession) {
                fail("The camera cannot stream at this size")
            }
        })
        try {
            camera.createCaptureSession(config)
        } catch (e: Exception) {
            Log.w(TAG, "session failed", e)
            fail("The camera stopped: ${e.message}")
        }
    }

    /** Closes the camera. */
    fun close() {
        generation++
        handler.post { closeNow() }
    }

    private fun closeNow() {
        runCatching { session?.close() }
        session = null
        runCatching { device?.close() }
        device = null
    }

    /** Closes the camera and stops its thread. */
    fun release() {
        close()
        thread.quitSafely()
    }

    companion object {
        /** Prefers 1920x1080, then the largest 16:9 size up to 1920 wide, then the largest size up to 1920 wide. */
        fun pickSize(sizes: List<Size>): Size {
            sizes.firstOrNull { it.width == 1920 && it.height == 1080 }?.let { return it }
            val fit = sizes.filter { it.width <= 1920 }
            fit.filter { it.width * 9 == it.height * 16 }.maxByOrNull { it.width }?.let { return it }
            return fit.maxByOrNull { it.width * it.height } ?: Size(1280, 720)
        }

        /** Prefers a fixed 30 fps range, then the range that reaches 30 fps with the highest minimum. */
        fun pickFps(ranges: Array<Range<Int>>?): Range<Int>? {
            val list = ranges?.toList().orEmpty()
            list.firstOrNull { it.lower == 30 && it.upper == 30 }?.let { return it }
            return list.filter { it.upper == 30 }.maxByOrNull { it.lower } ?: list.maxByOrNull { it.upper }
        }
    }
}
