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
import java.util.concurrent.atomic.AtomicInteger

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

    // Each open and close takes a new number, so that callbacks of an
    // earlier open do nothing. The GL thread opens and the main thread
    // closes, so the number is atomic.
    private val generation = AtomicInteger()

    // True after release(). No camera opens after it.
    @Volatile private var released = false

    /** Zoom, exposure, and white balance. They change without a new session. */
    data class Controls(val zoom: Float = 1f, val exposureIndex: Int = 0, val awbMode: Int = CameraMetadata.CONTROL_AWB_MODE_AUTO)

    /** The controls for the next request. Set them with [setControls]. */
    @Volatile var controls = Controls()
        private set

    /**
     * A camera to open, with the facts that the renderer and the settings
     * need. [exposureStep] is the EV of 1 step of exposure compensation.
     * With a [physicalId], the frames come from that lens of camera [id].
     */
    data class Choice(
        val id: String,
        val physicalId: String?,
        val name: String,
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

    /**
     * Returns the cameras of this phone, named as [nameLenses] names them:
     * "back", "front", and the other back and front lenses, such as
     * "back 0.6x" or "back 3x". The extra lenses of a logical camera count
     * too, as many phones show them only this way.
     */
    fun cameras(): List<NamedLens> {
        cached?.let { return it }
        val lenses = runCatching { lenses() }.getOrDefault(emptyList())
        val all = nameLenses(lenses).ifEmpty { listOf(NamedLens("back", Lens(manager.cameraIdList.firstOrNull() ?: "0", null, "back", 0f))) }
        // The lenses of a phone do not change, so they are read once.
        if (lenses.isNotEmpty()) cached = all
        return all
    }

    @Volatile private var cached: List<NamedLens>? = null

    private fun lenses(): List<Lens> {
        val ids = manager.cameraIdList.toList()
        val chars = ids.associateWith { manager.getCameraCharacteristics(it) }
        val plain = ids.mapNotNull { id -> chars.getValue(id).takeIf { colorCamera(it) }?.let { lensOf(id, null, it) } }
        val physical = ids.flatMap { id ->
            val c = chars.getValue(id)
            val logical = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
                ?.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA) == true
            if (!logical) return@flatMap emptyList()
            c.physicalCameraIds.mapNotNull { pid ->
                runCatching { manager.getCameraCharacteristics(pid) }.getOrNull()?.let { pc ->
                    // A lens that cannot stream on its own surface, or that
                    // sees no color, such as a depth or mono lens, is left out.
                    if (pc.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) == null || !colorCamera(pc)) null
                    else lensOf(id, pid, pc, facingOf(c))
                }
            }
        }
        return plain + physical
    }

    /** Reports whether [c] streams a color image, and is not only a depth or mono sensor. */
    private fun colorCamera(c: CameraCharacteristics): Boolean {
        val caps = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
        // A physical lens may leave out its capabilities. It then counts as a color lens.
        if (caps != null && CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE !in caps) return false
        val cfa = c.get(CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && cfa != null &&
            (cfa == CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_MONO || cfa == CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_NIR)
        ) return false
        return true
    }

    private fun facingOf(c: CameraCharacteristics): String? = when (c.get(CameraCharacteristics.LENS_FACING)) {
        CameraCharacteristics.LENS_FACING_BACK -> "back"
        CameraCharacteristics.LENS_FACING_FRONT -> "front"
        else -> null
    }

    private fun lensOf(id: String, physicalId: String?, c: CameraCharacteristics, facing: String? = facingOf(c)): Lens? {
        facing ?: return null
        val focal = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull() ?: 0f
        val width = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)?.width ?: 0f
        return Lens(id, physicalId, facing, if (focal > 0f && width > 0f) focal / width else 0f)
    }

    /**
     * Picks the camera named [name]. An unknown name picks the main camera
     * of the same direction, and then the first camera.
     */
    fun choose(name: String): Choice? {
        val named = pickNamed(cameras(), name) ?: return null
        return choiceFor(named)
    }

    private fun choiceFor(named: NamedLens): Choice {
        val lens = named.lens
        val id = lens.id
        // The request controls belong to the opened camera. The sizes, the
        // orientation, and the crop of a lens come from that lens, which
        // zooms by its crop, see repeat().
        val c = manager.getCameraCharacteristics(id)
        val p = lens.physicalId?.let { manager.getCameraCharacteristics(it) } ?: c
        val pmap = p.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        var sizes = pmap?.getOutputSizes(SurfaceTexture::class.java).orEmpty().toList()
        if (lens.physicalId != null) {
            // The logical camera streams the lens, so the size must suit both.
            val logical = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)?.getOutputSizes(SurfaceTexture::class.java).orEmpty().toSet()
            sizes = sizes.filter { it in logical }.ifEmpty { sizes }
        }
        // A size that the lens cannot stream at 30 fps is left out, when another size can.
        val fast = sizes.filter { size -> pmap?.let { it.getOutputMinFrameDuration(SurfaceTexture::class.java, size) <= FRAME_NS } ?: true }
        sizes = fast.ifEmpty { sizes }
        val zoomMax = (if (lens.physicalId != null) {
            p.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            c.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.upper
        } else {
            c.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)
        }) ?: 1f
        val awb = c.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES)?.toSet().orEmpty()
        return Choice(
            id = id,
            physicalId = lens.physicalId,
            name = named.name,
            facing = lens.facing,
            size = pickSize(sizes),
            sensorOrientation = p.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90,
            fps = pickFps(c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)),
            // More than 10x zoom only shows noise on a webcam.
            zoomMax = zoomMax.coerceIn(1f, 10f),
            exposureRange = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE) ?: Range(0, 0),
            exposureStep = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)?.toFloat() ?: 0f,
            whiteBalance = WHITE_BALANCE_MODES.filter { AWB_MODES[it] in awb }.ifEmpty { listOf("auto") },
            activeArray = p.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE),
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
            // A request that sets keys of a lens must name that lens when it is made.
            val builder = choice.physicalId?.let { s.device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD, setOf(it)) }
                ?: s.device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            val request = builder.apply {
                addTarget(target)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                choice.fps?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
                val c = controls
                set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, c.exposureIndex.coerceIn(choice.exposureRange.lower, choice.exposureRange.upper))
                set(CaptureRequest.CONTROL_AWB_MODE, c.awbMode)
                val zoom = c.zoom.coerceIn(1f, choice.zoomMax)
                val physical = choice.physicalId
                if (physical != null) {
                    // A zoom ratio on the logical camera can switch lenses, so a chosen lens zooms by its own crop.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) set(CaptureRequest.CONTROL_ZOOM_RATIO, 1f)
                    choice.activeArray?.let { setPhysicalCameraKey(CaptureRequest.SCALER_CROP_REGION, cropFor(it, zoom), physical) }
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
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
     * the UI can show. Only the newest open reports to [fail], so a late
     * error of an earlier camera does not change the screen.
     */
    @SuppressLint("MissingPermission")
    fun open(choice: Choice, target: Surface, fail: (String) -> Unit) {
        if (released) return
        val gen = generation.incrementAndGet()
        fun current() = gen == generation.get() && !released
        handler.post { closeNow() }
        fun attempt(left: Int) {
            if (!current()) return
            try {
                manager.openCamera(choice.id, executor, object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        if (!current()) return camera.close()
                        device = camera
                        startSession(camera, choice, target, { current() }, fail)
                    }

                    override fun onDisconnected(camera: CameraDevice) {
                        camera.close()
                        val opened = device === camera
                        if (opened) closeNow()
                        if (!current()) return
                        when {
                            // Another app took the camera. The image stops, so the screen tells the user.
                            opened -> fail("Another app uses the camera now. Close this screen and open it again.")
                            // Android can call this instead of onOpened when the open fails.
                            left > 0 -> handler.postDelayed({ attempt(left - 1) }, 300)
                            else -> fail("The camera is not available")
                        }
                    }

                    override fun onError(camera: CameraDevice, error: Int) {
                        camera.close()
                        if (device === camera) closeNow()
                        if (!current()) return
                        if (error == ERROR_CAMERA_IN_USE && left > 0) {
                            handler.postDelayed({ attempt(left - 1) }, 300)
                        } else {
                            fail("The camera is not available (error $error)")
                        }
                    }
                })
            } catch (e: Exception) {
                if (!current()) return
                if (left > 0) handler.postDelayed({ attempt(left - 1) }, 300) else fail("Cannot open the camera: ${e.message}")
            }
        }
        handler.post { attempt(6) }
    }

    private fun startSession(camera: CameraDevice, choice: Choice, target: Surface, current: () -> Boolean, fail: (String) -> Unit) {
        val output = OutputConfiguration(target).apply {
            // The computer and the preview get the image as the camera sees
            // it, and only the mirror setting mirrors it. Before Android 13,
            // the framework mirrors the front camera, and GlRenderer removes
            // that mirror, see FrameGeometry.unmirror.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) mirrorMode = OutputConfiguration.MIRROR_MODE_NONE
            choice.physicalId?.let { setPhysicalCameraId(it) }
        }
        val config = SessionConfiguration(SessionConfiguration.SESSION_REGULAR, listOf(output), executor, object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(s: CameraCaptureSession) {
                if (device !== camera) return s.close()
                session = s
                active = choice to target
                repeat()
            }

            override fun onConfigureFailed(s: CameraCaptureSession) {
                if (current()) fail("The camera cannot stream at this size")
            }
        })
        try {
            val physical = choice.physicalId
            if (physical != null && runCatching { camera.isSessionConfigurationSupported(config) }.getOrDefault(true) == false) {
                // The phone cannot stream this lens alone. The logical camera
                // streams instead, so the image keeps going.
                Log.w(TAG, "lens $physical cannot stream alone, using camera ${choice.id}")
                return startSession(camera, choice.copy(physicalId = null, activeArray = null), target, current, fail)
            }
            camera.createCaptureSession(config)
        } catch (e: Exception) {
            Log.w(TAG, "session failed", e)
            if (current()) fail("The camera stopped: ${e.message}")
        }
    }

    /** Closes the camera. */
    fun close() {
        generation.incrementAndGet()
        handler.post { closeNow() }
    }

    private fun closeNow() {
        runCatching { session?.close() }
        session = null
        active = null
        runCatching { device?.close() }
        device = null
    }

    /**
     * Closes the camera and stops its thread. The stop waits behind the
     * callbacks that the camera already posted. So a camera that opens
     * during the release still gets to onOpened, which closes it.
     */
    fun release() {
        released = true
        generation.incrementAndGet()
        handler.post {
            closeNow()
            thread.quitSafely()
        }
    }

    companion object {
        /** The longest frame at 30 fps, in nanoseconds, with a little room. */
        private const val FRAME_NS = 34_000_000L

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
