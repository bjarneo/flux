package org.omarchy.flux.webcam

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

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

    @Test
    fun detectsAxisSwap() {
        val flipOnly = floatArrayOf(1f, 0f, 0f, 0f, 0f, -1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 1f, 0f, 1f)
        val rotated = floatArrayOf(0f, -1f, 0f, 0f, -1f, 0f, 0f, 0f, 0f, 0f, 1f, 0f, 1f, 1f, 0f, 1f)
        assertFalse(FrameGeometry.swapsAxes(flipOnly))
        assertTrue(FrameGeometry.swapsAxes(rotated))
    }
}
