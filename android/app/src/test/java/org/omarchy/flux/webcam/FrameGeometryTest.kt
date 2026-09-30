package org.omarchy.flux.webcam

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// The buffer transform flags of Android. ROT_180 and ROT_270 are made of the others.
private const val FLIP_H = 1
private const val FLIP_V = 2
private const val ROT_90 = 4
private const val ROT_180 = FLIP_H or FLIP_V
private const val ROT_270 = ROT_180 or ROT_90

class FrameGeometryTest {
    private val wide = 16f / 9f
    private val tall = 9f / 16f

    private fun point(m: FloatArray, x: Float, y: Float) = FrameGeometry.apply(m, x, y)

    private fun assertPoint(expected: Pair<Float, Float>, actual: Pair<Float, Float>) {
        assertEquals(expected.first, actual.first, 1e-4f)
        assertEquals(expected.second, actual.second, 1e-4f)
    }

    @Test
    fun landscapeContentWithoutRotationIsIdentity() {
        val m = FrameGeometry.matrix(0, wide, wide, mirror = false)
        assertPoint(0f to 0f, point(m, 0f, 0f))
        assertPoint(1f to 1f, point(m, 1f, 1f))
    }

    @Test
    fun rotation90MapsCornersClockwise() {
        // Portrait content rotated clockwise by 90 degrees becomes landscape,
        // so no crop is needed. The top left of the output comes from the
        // bottom left of the content.
        val m = FrameGeometry.matrix(90, tall, wide, mirror = false)
        assertPoint(0f to 0f, point(m, 0f, 1f))
        assertPoint(1f to 1f, point(m, 1f, 0f))
        assertPoint(0.5f to 0.5f, point(m, 0.5f, 0.5f))
    }

    @Test
    fun rotation180FlipsBothAxes() {
        val m = FrameGeometry.matrix(180, wide, wide, mirror = false)
        assertPoint(1f to 1f, point(m, 0f, 0f))
        assertPoint(0f to 0f, point(m, 1f, 1f))
    }

    @Test
    fun rotation270MapsCornersCounterClockwise() {
        val m = FrameGeometry.matrix(270, tall, wide, mirror = false)
        assertPoint(1f to 1f, point(m, 0f, 1f))
        assertPoint(0f to 0f, point(m, 1f, 0f))
    }

    @Test
    fun portraitContentWithoutRotationIsCroppedToACenterBand() {
        // Upright portrait content in a 16:9 frame: the full width, and a
        // center band of the height.
        val m = FrameGeometry.matrix(0, tall, wide, mirror = false)
        val band = tall / wide
        assertPoint(0f to 0.5f - band / 2, point(m, 0f, 0f))
        assertPoint(1f to 0.5f + band / 2, point(m, 1f, 1f))
    }

    @Test
    fun mirrorFlipsTheOutputHorizontally() {
        val m = FrameGeometry.matrix(0, wide, wide, mirror = true)
        assertPoint(1f to 0f, point(m, 0f, 0f))
        assertPoint(0f to 1f, point(m, 1f, 1f))
    }

    @Test
    fun uprightRotationForNaturalContent() {
        assertEquals(0, FrameGeometry.uprightRotation(0, 90, front = false, naturalContent = true))
        assertEquals(90, FrameGeometry.uprightRotation(90, 90, front = false, naturalContent = true))
        assertEquals(270, FrameGeometry.uprightRotation(270, 90, front = false, naturalContent = true))
        assertEquals(270, FrameGeometry.uprightRotation(90, 270, front = true, naturalContent = true))
    }

    @Test
    fun uprightRotationForSensorContentUsesTheSensorOrientation() {
        assertEquals(90, FrameGeometry.uprightRotation(0, 90, front = false, naturalContent = false))
        assertEquals(180, FrameGeometry.uprightRotation(90, 90, front = false, naturalContent = false))
        assertEquals(0, FrameGeometry.uprightRotation(90, 90, front = true, naturalContent = false))
    }

    @Test
    fun snapRoundsToQuarterTurns() {
        assertEquals(0, FrameGeometry.snap(20))
        assertEquals(90, FrameGeometry.snap(80))
        assertEquals(0, FrameGeometry.snap(350))
        assertEquals(270, FrameGeometry.snap(-80))
    }

    // The SurfaceTexture transform as Android builds it (GLConsumer): a
    // vertical flip, then the crop, then the buffer transform. The buffer
    // transform multiplies FLIP_H, FLIP_V, and ROT_90 in this order.
    private fun times(a: FloatArray, b: FloatArray) = FloatArray(16) { i ->
        val col = i / 4
        val row = i % 4
        (0 until 4).sumOf { k -> (a[k * 4 + row] * b[col * 4 + k]).toDouble() }.toFloat()
    }

    private val flipH = floatArrayOf(-1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f, 0f, 1f, 0f, 0f, 1f)
    private val flipV = floatArrayOf(1f, 0f, 0f, 0f, 0f, -1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 1f, 0f, 1f)
    private val rot90 = floatArrayOf(0f, 1f, 0f, 0f, -1f, 0f, 0f, 0f, 0f, 0f, 1f, 0f, 1f, 0f, 0f, 1f)
    private val identity = floatArrayOf(1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f)

    private fun surfaceTransform(h: Boolean, v: Boolean, r90: Boolean, shrink: Float = 0f): FloatArray {
        var x = identity
        if (h) x = times(x, flipH)
        if (v) x = times(x, flipV)
        if (r90) x = times(x, rot90)
        // A crop that makes each side smaller by the same amount, as the filter of GLConsumer does.
        val s = 1f - 2 * shrink
        val crop = floatArrayOf(s, 0f, 0f, 0f, 0f, s, 0f, 0f, 0f, 0f, 1f, 0f, shrink, shrink, 0f, 1f)
        return times(flipV, times(crop, x))
    }

    private fun assertMatrix(expected: FloatArray, actual: FloatArray) {
        for (i in 0 until 16) assertEquals("element $i", expected[i], actual[i], 1e-5f)
    }

    private fun surfaceTransform(flags: Int, shrink: Float = 0f) =
        surfaceTransform((flags and FLIP_H) != 0, (flags and FLIP_V) != 0, (flags and ROT_90) != 0, shrink)

    @Test
    fun theMirrorOfTheFrontCameraBeforeAndroid13GoesAway() {
        // CameraUtils gives a back camera the rotation of its sensor. It
        // gives a front camera FLIP_H XOR a rotation: the rotation of the
        // sensor for 0 and 180, and the opposite rotation for 90 and 270. A
        // flip comes before a rotation. Android 13 and later with
        // MIRROR_MODE_NONE give the front camera the rotation only. For each
        // sensor orientation: the flags without the mirror, and the flags
        // with it.
        val cameras = mapOf(
            0 to (0 to FLIP_H),
            90 to (ROT_90 to (FLIP_H xor ROT_270)), // FLIP_V and ROT_90
            180 to (ROT_180 to (FLIP_H xor ROT_180)), // FLIP_V
            270 to (ROT_270 to (FLIP_H xor ROT_90)), // FLIP_H and ROT_90
        )
        for (shrink in listOf(0f, 0.5f / 1080)) {
            for ((sensor, flags) in cameras) {
                val real = surfaceTransform(flags.first, shrink)
                val mirrored = surfaceTransform(flags.second, shrink)
                assertFalse("sensor $sensor", FrameGeometry.mirrors(real))
                assertTrue("sensor $sensor", FrameGeometry.mirrors(mirrored))
                // The mirror is a horizontal flip of the upright image: a
                // flip of the x axis before the real transform.
                assertMatrix(times(real, flipH), mirrored)
                FrameGeometry.unmirror(mirrored)
                assertMatrix(real, mirrored)
                assertEquals("the rotation rule does not change", FrameGeometry.swapsAxes(real), FrameGeometry.swapsAxes(mirrored))
            }
        }
        // On a phone, a front sensor has orientation 90 or 270, so its transform swaps the axes.
        assertTrue(FrameGeometry.swapsAxes(surfaceTransform(ROT_270)))
        assertTrue(FrameGeometry.swapsAxes(surfaceTransform(ROT_90)))
    }

    @Test
    fun aTransformWithoutAMirrorStaysTheSame() {
        for (t in listOf(
            surfaceTransform(h = false, v = false, r90 = true), // back camera, sensor 90
            surfaceTransform(h = true, v = true, r90 = false), // sensor 180
            surfaceTransform(h = false, v = false, r90 = false), // sensor 0
        )) {
            val copy = t.copyOf()
            FrameGeometry.unmirror(copy)
            assertMatrix(t, copy)
        }
    }

    @Test
    fun detectsAxisSwap() {
        val flipOnly = floatArrayOf(1f, 0f, 0f, 0f, 0f, -1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 1f, 0f, 1f)
        val rotated = floatArrayOf(0f, -1f, 0f, 0f, -1f, 0f, 0f, 0f, 0f, 0f, 1f, 0f, 1f, 1f, 0f, 1f)
        assertFalse(FrameGeometry.swapsAxes(flipOnly))
        assertTrue(FrameGeometry.swapsAxes(rotated))
    }
}
