package org.omarchy.flux.desktop

/**
 * The zoom and the pan of the remote desktop on the phone. At scale 1, the
 * video fits the view and has the same shape. A point of the video at
 * (x, y) at scale 1 shows at (x × scale + offsetX, y × scale + offsetY) on
 * the view. Positions on the video go from 0 to 1.
 */
data class DesktopViewport(
    val viewWidth: Float,
    val viewHeight: Float,
    val videoWidth: Int,
    val videoHeight: Int,
    val scale: Float = 1f,
    val offsetX: Float = 0f,
    val offsetY: Float = 0f,
) {
    private val fit: Float = minOf(viewWidth / videoWidth, viewHeight / videoHeight)

    /** The width of the video at scale 1, in view pixels. */
    val fitWidth: Float get() = videoWidth * fit

    /** The height of the video at scale 1, in view pixels. */
    val fitHeight: Float get() = videoHeight * fit

    /** The left edge of the video at scale 1. */
    val fitLeft: Float get() = (viewWidth - fitWidth) / 2

    /** The top edge of the video at scale 1. */
    val fitTop: Float get() = (viewHeight - fitHeight) / 2

    /** The number of view pixels for 1 video pixel. */
    val pixel: Float get() = fit * scale

    /**
     * Returns the position on the video for a point on the view, from 0 to
     * 1. It returns null for a point outside the video, unless [clamp] moves
     * the point to the nearest edge.
     */
    fun toVideo(x: Float, y: Float, clamp: Boolean = false): Pair<Float, Float>? {
        val u = ((x - offsetX) / scale - fitLeft) / fitWidth
        val v = ((y - offsetY) / scale - fitTop) / fitHeight
        if (clamp) return u.coerceIn(0f, 1f) to v.coerceIn(0f, 1f)
        return if (u in 0f..1f && v in 0f..1f) u to v else null
    }

    /**
     * Zooms by [factor] around the point ([focusX], [focusY]) of the view,
     * and moves by ([panX], [panY]). The scale stays from 1 to [MAX_SCALE],
     * and the video stays on the view.
     */
    fun zoom(factor: Float, focusX: Float, focusY: Float, panX: Float = 0f, panY: Float = 0f): DesktopViewport {
        val next = (scale * factor).coerceIn(1f, MAX_SCALE)
        // The point under the focus stays under the focus.
        val x = focusX - (focusX - offsetX) / scale * next + panX
        val y = focusY - (focusY - offsetY) / scale * next + panY
        return copy(scale = next, offsetX = x, offsetY = y).clamped()
    }

    /** Moves the view by ([dx], [dy]) view pixels. */
    fun pan(dx: Float, dy: Float): DesktopViewport = copy(offsetX = offsetX + dx, offsetY = offsetY + dy).clamped()

    /** Returns the viewport for a new view or video size, at scale 1. */
    fun resized(viewWidth: Float, viewHeight: Float, videoWidth: Int, videoHeight: Int): DesktopViewport =
        if (viewWidth == this.viewWidth && viewHeight == this.viewHeight && videoWidth == this.videoWidth && videoHeight == this.videoHeight) this
        else DesktopViewport(viewWidth, viewHeight, videoWidth, videoHeight)

    /**
     * Keeps the video on the view. A video that is smaller than the view
     * stays in the center. A larger video covers the view.
     */
    private fun clamped(): DesktopViewport {
        fun axis(offset: Float, start: Float, length: Float, view: Float): Float {
            val shown = length * scale
            if (shown <= view) return (view - shown) / 2 - start * scale
            return offset.coerceIn(view - (start + length) * scale, -start * scale)
        }
        return copy(
            offsetX = axis(offsetX, fitLeft, fitWidth, viewWidth),
            offsetY = axis(offsetY, fitTop, fitHeight, viewHeight),
        )
    }

    companion object {
        const val MAX_SCALE = 6f
    }
}
