package org.omarchy.flux.webcam

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
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
    private var active: Pair<Choice, Surface>? = null
    @Volatile private var generation = 0

    /** Zoom, exposure, and white balance. They change without a new session. */
    data class Controls(val zoom: Float = 1f, val exposureIndex: Int = 0, val awbMode: Int = CameraMetadata.CONTROL_AWB_MODE_AUTO)

    /** The controls for the next request. Set them with [setControls]. */
    @Volatile var controls = Controls()
        private set

    /**
     * A camera to open, with the facts that the renderer and the settings
     * need. [exposureStep] is the EV of 1 step of exposure compensation.
     */
    data class Choice(
        val id: String,
        val facing: String,
        val size: Size,
        val sensorOrientation: Int,
        val fps: Range<Int>?,
        val zoomMax: Float,
        val exposureRange: Range<Int>,
        val exposureStep: Float,
        val whiteBalance: List<String>,
        val activeArray: Rect?,
    )

    /** Returns the camera directions of this phone: "back", "front", or both. */
    fun facings(): List<String> {
        val present = runCatching { manager.cameraIdList.map { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) } }.getOrDefault(emptyList())
        return buildList {
            if (CameraCharacteristics.LENS_FACING_BACK in present) add("back")
            if (CameraCharacteristics.LENS_FACING_FRONT in present) add("front")
        }.ifEmpty { listOf("back") }
    }

    /** Picks the first camera that faces the user ([front]) or away from the user. */
    fun choose(front: Boolean): Choice? {
        val facing = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        val id = manager.cameraIdList.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == facing }
            ?: manager.cameraIdList.firstOrNull()
            ?: return null
        val c = manager.getCameraCharacteristics(id)
        val sizes = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)?.getOutputSizes(SurfaceTexture::class.java).orEmpty()
        val zoomMax = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            c.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.upper
        } else {
            c.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)
        } ?: 1f
        val awb = c.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES)?.toSet().orEmpty()
        return Choice(
            id = id,
            facing = if (c.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT) "front" else "back",
            size = pickSize(sizes.toList()),
            sensorOrientation = c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90,
            fps = pickFps(c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)),
            // More than 10x zoom only shows noise on a webcam.
            zoomMax = zoomMax.coerceIn(1f, 10f),
            exposureRange = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE) ?: Range(0, 0),
            exposureStep = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)?.toFloat() ?: 0f,
            whiteBalance = WHITE_BALANCE_MODES.filter { AWB_MODES[it] in awb }.ifEmpty { listOf("auto") },
            activeArray = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE),
        )
    }

    /** Changes zoom, exposure, and white balance on the running camera. */
    fun setControls(next: Controls) {
        if (next == controls) return
        controls = next
        handler.post { repeat() }
    }

    /** Sends the repeating request again with the current controls. */
    private fun repeat() {
        val s = session ?: return
        val (choice, target) = active ?: return
        try {
            val request = s.device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                addTarget(target)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                choice.fps?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
                val c = controls
                set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, c.exposureIndex.coerceIn(choice.exposureRange.lower, choice.exposureRange.upper))
                set(CaptureRequest.CONTROL_AWB_MODE, c.awbMode)
                val zoom = c.zoom.coerceIn(1f, choice.zoomMax)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom)
                } else {
                    choice.activeArray?.let { set(CaptureRequest.SCALER_CROP_REGION, cropFor(it, zoom)) }
                }
            }.build()
            s.setRepeatingRequest(request, null, handler)
        } catch (e: Exception) {
            Log.w(TAG, "camera request failed", e)
        }
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
                active = choice to target
                repeat()
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
        active = null
        runCatching { device?.close() }
        device = null
    }

    /** Closes the camera and stops its thread. */
    fun release() {
        close()
        thread.quitSafely()
    }

    companion object {
        /** The Camera2 white balance mode for each protocol name. */
        val AWB_MODES = mapOf(
            "auto" to CameraMetadata.CONTROL_AWB_MODE_AUTO,
            "daylight" to CameraMetadata.CONTROL_AWB_MODE_DAYLIGHT,
            "cloudy" to CameraMetadata.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT,
            "shade" to CameraMetadata.CONTROL_AWB_MODE_SHADE,
            "incandescent" to CameraMetadata.CONTROL_AWB_MODE_INCANDESCENT,
            "fluorescent" to CameraMetadata.CONTROL_AWB_MODE_FLUORESCENT,
            "twilight" to CameraMetadata.CONTROL_AWB_MODE_TWILIGHT,
        )

        /** Returns the centered crop of [array] for a digital zoom of [zoom]. */
        fun cropFor(array: Rect, zoom: Float): Rect {
            val w = (array.width() / zoom).toInt()
            val h = (array.height() / zoom).toInt()
            val left = array.left + (array.width() - w) / 2
            val top = array.top + (array.height() - h) / 2
            return Rect(left, top, left + w, top + h)
        }

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
