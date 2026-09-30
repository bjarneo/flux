package org.omarchy.flux.webcam

import kotlin.math.abs

/**
 * The mapping from an output frame to the camera image. The output has the
 * aspect of the webcam setting, one of 16:9, 4:3, 1:1, and 9:16, and it is
 * upright for the viewer. The camera image is rotated clockwise by a
 * multiple of 90 degrees, cropped in the center to the output shape, and
 * mirrored when the mirror setting is on. The computer and the preview get
 * the same frame.
 *
 * Coordinates run from 0 to 1, with y up, as in OpenGL texture space.
 */
object FrameGeometry {
    /**
     * Returns a column-major 4x4 matrix that maps an output coordinate to a
     * coordinate in the camera image, before the SurfaceTexture transform.
     *
     * [rotation] is the clockwise rotation in degrees that makes the camera
     * image upright. [contentAspect] is the width divided by the height of
     * the camera image. [outputAspect] is the same for the output frame.
     */
    fun matrix(rotation: Int, contentAspect: Float, outputAspect: Float, mirror: Boolean): FloatArray {
        val r = ((rotation % 360) + 360) % 360
        // The shape of the camera image after the rotation.
        val rotatedAspect = if (r == 90 || r == 270) 1f / contentAspect else contentAspect
        var sx = 1f
        var sy = 1f
        if (rotatedAspect > outputAspect) sx = outputAspect / rotatedAspect else sy = rotatedAspect / outputAspect

        // Step 1, the mirror setting: x -> 1 - x.
        var a = Affine(if (mirror) -1f else 1f, 0f, 0f, 1f, if (mirror) 1f else 0f, 0f)
        // Step 2, the center crop in the rotated image.
        a = Affine(sx, 0f, 0f, sy, 0.5f - 0.5f * sx, 0.5f - 0.5f * sy).after(a)
        // Step 3, from the rotated image back to the camera image.
        val back = when (r) {
            90 -> Affine(0f, 1f, -1f, 0f, 1f, 0f) // s = (1 - y, x)
            180 -> Affine(-1f, 0f, 0f, -1f, 1f, 1f) // s = (1 - x, 1 - y)
            270 -> Affine(0f, -1f, 1f, 0f, 0f, 1f) // s = (y, 1 - x)
            else -> Affine(1f, 0f, 0f, 1f, 0f, 0f)
        }
        return back.after(a).toMatrix()
    }

    /** Applies a matrix from [matrix] to a point. Tests use it. */
    fun apply(m: FloatArray, x: Float, y: Float): Pair<Float, Float> =
        Pair(m[0] * x + m[4] * y + m[12], m[1] * x + m[5] * y + m[13])

    /**
     * Reports whether a SurfaceTexture transform swaps the axes. The camera
     * framework rotates preview outputs to the natural orientation of the
     * device, and that rotation swaps the axes of the sensor image.
     */
    fun swapsAxes(transform: FloatArray): Boolean = abs(transform[0]) < 0.5f && abs(transform[5]) < 0.5f

    /**
     * Reports whether a SurfaceTexture transform mirrors the camera image.
     * Before Android 13, the camera framework mirrors the front camera, and
     * an app cannot turn this off. A transform without a mirror has a
     * negative determinant, because SurfaceTexture adds a vertical flip.
     */
    fun mirrors(transform: FloatArray): Boolean = transform[0] * transform[5] - transform[1] * transform[4] > 0f

    /**
     * Removes the mirror of the camera framework from [transform], in place.
     * The camera adds FLIP_H to the buffer transform before its rotation, so
     * the mirror is a horizontal flip of the upright image: the transform
     * is T * G, where G is x -> 1 - x in the coordinates before the
     * transform. A second G before the transform gives T, the image as the
     * camera sees it. [uprightRotation] and the mirror setting then work as
     * on Android 13 and later.
     */
    fun unmirror(transform: FloatArray) {
        if (!mirrors(transform)) return
        // T * G: the first column changes its sign, and the offset column gets the old first column.
        for (i in 0 until 4) {
            transform[12 + i] += transform[i]
            transform[i] = -transform[i]
        }
    }

    /**
     * Returns the clockwise rotation that makes the camera image upright,
     * from the device orientation in degrees (0 in the natural orientation,
     * 90 when the left side of the device is at the top).
     *
     * When the framework already rotated the image to the natural
     * orientation ([naturalContent]), only the device orientation counts.
     * Otherwise the sensor orientation counts too.
     */
    fun uprightRotation(deviceOrientation: Int, sensorOrientation: Int, front: Boolean, naturalContent: Boolean): Int {
        val d = snap(deviceOrientation)
        val signed = if (front) -d else d
        val base = if (naturalContent) 0 else sensorOrientation
        return ((base + signed) % 360 + 360) % 360
    }

    /** Rounds an orientation to the nearest multiple of 90 degrees. */
    fun snap(degrees: Int): Int = ((((degrees % 360) + 360) % 360 + 45) / 90 * 90) % 360

    /** A 2D affine map: x' = a*x + c*y + tx, y' = b*x + d*y + ty. */
    private data class Affine(val a: Float, val b: Float, val c: Float, val d: Float, val tx: Float, val ty: Float) {
        /** Returns this map applied after [first]. */
        fun after(first: Affine) = Affine(
            a * first.a + c * first.b,
            b * first.a + d * first.b,
            a * first.c + c * first.d,
            b * first.c + d * first.d,
            a * first.tx + c * first.ty + tx,
            b * first.tx + d * first.ty + ty,
        )

        fun toMatrix(): FloatArray = floatArrayOf(
            a, b, 0f, 0f,
            c, d, 0f, 0f,
            0f, 0f, 1f, 0f,
            tx, ty, 0f, 1f,
        )
    }
}
