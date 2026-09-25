package org.omarchy.flux.webcam

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** The frame shapes that the phone offers, as width:height. */
val ASPECTS = listOf("16:9", "4:3", "1:1", "9:16")

/** The short side of the frame, in pixels. */
val RESOLUTIONS = listOf(720, 1080)

/** The white balance modes in the protocol, in the order that the phone shows them. */
val WHITE_BALANCE_MODES = listOf("auto", "daylight", "cloudy", "shade", "incandescent", "fluorescent", "twilight")

/**
 * The webcam settings. The phone and the computer can both change them.
 * [aspect], [resolution], and [camera] set the stream. The other fields
 * change the image while it streams.
 */
data class WebcamConfig(
    val aspect: String = "16:9",
    val resolution: Int = 720,
    val camera: String = "back",
    val mirror: Boolean = false,
    val zoom: Float = 1f,
    val exposure: Float = 0f,
    val whiteBalance: String = "auto",
    val brightness: Float = 0f,
    val contrast: Float = 1f,
    val saturation: Float = 1f,
    val warmth: Float = 0f,
) {
    val width: Int get() = frameSize(aspect, resolution).first
    val height: Int get() = frameSize(aspect, resolution).second
    val bitrate: Int get() = bitrateFor(width, height)

    /**
     * Returns the config with the fields of [partial] applied. A field with
     * the wrong type or a value that is not a finite number is ignored.
     */
    fun merged(partial: JsonObject?): WebcamConfig {
        if (partial == null) return this
        return copy(
            aspect = partial.text("aspect") ?: aspect,
            resolution = partial.number("resolution")?.roundToInt() ?: resolution,
            camera = partial.text("camera")?.lowercase() ?: camera,
            mirror = partial.flag("mirror") ?: mirror,
            zoom = partial.number("zoom")?.toFloat() ?: zoom,
            exposure = partial.number("exposure")?.toFloat() ?: exposure,
            whiteBalance = partial.text("whiteBalance")?.lowercase() ?: whiteBalance,
            brightness = partial.number("brightness")?.toFloat() ?: brightness,
            contrast = partial.number("contrast")?.toFloat() ?: contrast,
            saturation = partial.number("saturation")?.toFloat() ?: saturation,
            warmth = partial.number("warmth")?.toFloat() ?: warmth,
        )
    }

    /** Returns the config with each field inside the limits of [caps]. */
    fun clamped(caps: WebcamCaps): WebcamConfig {
        val evMin = min(caps.exposureMin, caps.exposureMax)
        val evMax = max(caps.exposureMin, caps.exposureMax)
        var ev = exposure.coerceIn(evMin, evMax)
        if (caps.exposureStep > 0f) ev = ((ev / caps.exposureStep).roundToInt() * caps.exposureStep).coerceIn(evMin, evMax)
        return copy(
            aspect = if (aspect in caps.aspects) aspect else caps.aspects.firstOrNull() ?: "16:9",
            resolution = caps.resolutions.minByOrNull { abs(it - resolution) } ?: 720,
            camera = if (camera in caps.cameras) camera else caps.cameras.firstOrNull() ?: "back",
            zoom = round(zoom.coerceIn(1f, max(1f, caps.zoomMax)), 100f),
            exposure = round(ev, 1000f),
            whiteBalance = if (whiteBalance in caps.whiteBalance) whiteBalance else "auto",
            brightness = round(brightness.coerceIn(-1f, 1f), 100f),
            contrast = round(contrast.coerceIn(0f, 2f), 100f),
            saturation = round(saturation.coerceIn(0f, 2f), 100f),
            warmth = round(warmth.coerceIn(-1f, 1f), 100f),
        )
    }

    /** Returns the neutral image values. The shape, the quality, and the camera stay. */
    fun reset(): WebcamConfig {
        val neutral = WebcamConfig()
        return neutral.copy(aspect = aspect, resolution = resolution, camera = camera)
    }

    /** Reports whether a change to [next] needs a new stream with a new frame size. */
    fun restartsStream(next: WebcamConfig): Boolean = width != next.width || height != next.height

    fun toJson(): JsonObject = buildJsonObject {
        put("aspect", aspect)
        put("resolution", resolution)
        put("camera", camera)
        put("mirror", mirror)
        put("zoom", zoom)
        put("exposure", exposure)
        put("whiteBalance", whiteBalance)
        put("brightness", brightness)
        put("contrast", contrast)
        put("saturation", saturation)
        put("warmth", warmth)
    }
}

/** What the current camera and the encoder support. */
data class WebcamCaps(
    val zoomMax: Float = 1f,
    val exposureMin: Float = 0f,
    val exposureMax: Float = 0f,
    val exposureStep: Float = 0f,
    val whiteBalance: List<String> = listOf("auto"),
    val cameras: List<String> = listOf("back"),
    val aspects: List<String> = ASPECTS,
    val resolutions: List<Int> = RESOLUTIONS,
) {
    companion object {
        /** Wide limits for the time before the camera reports its real limits. */
        val LOOSE = WebcamCaps(
            zoomMax = 10f, exposureMin = -10f, exposureMax = 10f,
            whiteBalance = WHITE_BALANCE_MODES, cameras = listOf("back", "front"),
        )
    }

    fun toJson(): JsonObject = buildJsonObject {
        put("zoomMax", zoomMax)
        put("exposureMin", exposureMin)
        put("exposureMax", exposureMax)
        put("exposureStep", exposureStep)
        put("whiteBalance", JsonArray(whiteBalance.map { JsonPrimitive(it) }))
        put("cameras", JsonArray(cameras.map { JsonPrimitive(it) }))
        put("aspects", JsonArray(aspects.map { JsonPrimitive(it) }))
        put("resolutions", JsonArray(resolutions.map { JsonPrimitive(it) }))
    }
}

/**
 * Returns the frame size for [aspect] with [short] pixels on the short
 * side. Both sides are even, as H.264 needs. An unknown aspect is 16:9.
 */
fun frameSize(aspect: String, short: Int): Pair<Int, Int> {
    val parts = aspect.split(":").mapNotNull { it.trim().toIntOrNull() }
    val (a, b) = if (parts.size == 2 && parts[0] > 0 && parts[1] > 0) parts[0] to parts[1] else 16 to 9
    fun even(v: Double) = ((v / 2.0).roundToInt() * 2)
    return if (a >= b) even(short.toDouble() * a / b) to short else short to even(short.toDouble() * b / a)
}

/**
 * Returns the encoder bitrate for a frame size: 4 Mbit/s for 1280x720 and
 * 8 Mbit/s for 1920x1080, scaled by the number of pixels for other shapes.
 */
fun bitrateFor(width: Int, height: Int): Int {
    val perPixel = if (min(width, height) >= 1080) 8_000_000.0 / (1920 * 1080) else 4_000_000.0 / (1280 * 720)
    return max(1_000_000, (width.toDouble() * height * perPixel).roundToInt())
}

private fun round(v: Float, scale: Float): Float = (v * scale).roundToInt() / scale

private fun JsonObject.text(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim()?.takeIf { it.isNotEmpty() }

private fun JsonObject.number(key: String): Double? {
    val p = this[key] as? JsonPrimitive ?: return null
    val v = if (p.isString) p.content.trim().toDoubleOrNull() else p.doubleOrNull
    return v?.takeIf { it.isFinite() }
}

private fun JsonObject.flag(key: String): Boolean? {
    val p = this[key] as? JsonPrimitive ?: return null
    return if (p.isString) p.content.trim().lowercase().toBooleanStrictOrNull() else p.booleanOrNull
}
