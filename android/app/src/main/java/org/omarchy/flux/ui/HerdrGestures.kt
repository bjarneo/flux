package org.omarchy.flux.ui

import android.os.SystemClock
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.roundToInt

/**
 * The geometry of the terminal grid as the page draws it, in CSS
 * pixels: the size of one cell, where the grid starts, and the font of
 * the page.
 */
data class TerminalGeometry(
    val cellW: Double = 0.0,
    val cellH: Double = 0.0,
    val originX: Double = 0.0,
    val originY: Double = 0.0,
    val cols: Int = 0,
    val rows: Int = 0,
    val font: Int = 0,
) {
    /**
     * The zero-based cell at the page point ([x], [y]), or null outside
     * the grid: the margins beside the terminal take no input at all.
     */
    fun cellAt(x: Double, y: Double): Pair<Int, Int>? {
        if (cellW <= 0.0 || cellH <= 0.0 || cols < 1 || rows < 1) return null
        val col = floor((x - originX) / cellW).toInt()
        val row = floor((y - originY) / cellH).toInt()
        if (col !in 0 until cols || row !in 0 until rows) return null
        return col to row
    }
}

/**
 * Turns the touches on the terminal into wheel steps and local zoom and
 * pan. While [control] is on, a one-finger drag sends one wheel step per
 * threshold of movement, at the cell where the finger landed, so the
 * gesture scrolls the conversation of the pane on the computer too. In
 * observe mode the same drag only pans the local view. Two fingers
 * always zoom and pan locally and send nothing.
 *
 * At most [RATE] steps leave per second with a burst of [BURST], and
 * nothing is sent after the finger lifts: there is no remote inertia.
 * A change of the grid ends the gesture at once, so a step never
 * reinterprets the coordinates of an older screen.
 *
 * The callbacks run on the thread of the caller, which is the main
 * thread when the page forwards its touches.
 */
class TerminalGestures(
    private val now: () -> Long = { SystemClock.elapsedRealtime() },
    private val onWheel: (column: Int, row: Int, direction: String) -> Unit,
    private val onFont: (size: Int, focalX: Double, focalY: Double) -> Unit,
    private val onPan: (dx: Double, dy: Double) -> Unit,
) {
    companion object {
        /** The wheel steps per second, and how many may burst. */
        const val RATE = 30
        const val BURST = 10

        /** The smallest movement of one wheel step, in CSS pixels. */
        const val STEP_MIN = 14.0

        /** The largest font of the zoom. Smaller than this is the fit of the grid. */
        const val FONT_MAX = 24
    }

    /** True while the phone controls the terminal. */
    var control = false
        set(value) {
            if (field != value) endDrag()
            field = value
        }

    /** The grid as the page draws it. A new grid ends a running gesture. */
    var geometry = TerminalGeometry()
        set(value) {
            if (value.cols != field.cols || value.rows != field.rows) endDrag()
            field = value
        }

    private val points = mutableMapOf<Int, Pair<Double, Double>>()
    private var drag = false
    private var dragCell: Pair<Int, Int>? = null
    private var lastX = 0.0
    private var lastY = 0.0
    private var accum = 0.0
    private var zooming = false
    private var zoomDist = 0.0
    private var zoomFont = 0
    private var zoomSent = 0
    private var midX = 0.0
    private var midY = 0.0
    private var tokens = BURST.toDouble()
    private var tokenAt = 0L

    /** One touch of the page at ([x], [y]) in CSS pixels. Any thread. */
    fun touch(action: String, id: Int, x: Double, y: Double) {
        when (action) {
            "down" -> {
                points[id] = x to y
                if (points.size >= 2) startZoom() else startDrag(x, y)
            }
            "move" -> {
                if (points[id] == null) return
                points[id] = x to y
                if (points.size >= 2) moveZoom() else moveDrag(x, y)
            }
            // A lift or a cancel only ends its gesture: the finger that
            // is left does not inherit it.
            else -> {
                points.remove(id)
                if (points.size < 2) endZoom()
                if (points.isEmpty()) endDrag()
            }
        }
    }

    /** Ends every gesture and forgets the fingers. */
    fun reset() {
        points.clear()
        endDrag()
        endZoom()
    }

    private fun startDrag(x: Double, y: Double) {
        endZoom()
        drag = true
        dragCell = if (control) geometry.cellAt(x, y) else null
        lastX = x
        lastY = y
        accum = 0.0
    }

    private fun moveDrag(x: Double, y: Double) {
        if (!drag) return
        val dx = x - lastX
        val dy = y - lastY
        lastX = x
        lastY = y
        if (!control) {
            if (dx != 0.0 || dy != 0.0) onPan(dx, dy)
            return
        }
        // A drag that began outside the grid sends nothing at all.
        val cell = dragCell ?: return
        accum += dy
        // One step per threshold of movement: a resting finger sends
        // nothing, and the movement of one step is the height of a cell
        // or the minimum, whichever is larger.
        val step = maxOf(geometry.cellH, STEP_MIN)
        while (abs(accum) >= step) {
            if (!take()) {
                // The budget is spent. Keep at most one step pending and
                // wait: never queue a burst of steps for later.
                accum = if (accum < 0) -step else step
                return
            }
            val direction = if (accum < 0) "down" else "up"
            accum = if (accum < 0) accum + step else accum - step
            onWheel(cell.first, cell.second, direction)
        }
    }

    private fun startZoom() {
        endDrag()
        val pair = points.values.take(2)
        if (pair.size < 2) return
        zooming = true
        zoomDist = hypot(pair[0].first - pair[1].first, pair[0].second - pair[1].second)
        zoomFont = geometry.font
        zoomSent = 0
        midX = (pair[0].first + pair[1].first) / 2
        midY = (pair[0].second + pair[1].second) / 2
    }

    private fun moveZoom() {
        if (!zooming) return
        val pair = points.values.take(2)
        if (pair.size < 2) return
        val dist = hypot(pair[0].first - pair[1].first, pair[0].second - pair[1].second)
        val x = (pair[0].first + pair[1].first) / 2
        val y = (pair[0].second + pair[1].second) / 2
        // The fingers walk the view, and the pinch scales it. Both stay
        // local: two fingers never scroll the computer.
        if (x != midX || y != midY) onPan(x - midX, y - midY)
        midX = x
        midY = y
        if (zoomDist <= 0.0 || dist <= 0.0 || zoomFont < 1) return
        val size = (zoomFont * dist / zoomDist).roundToInt().coerceIn(1, FONT_MAX)
        if (size != zoomSent) {
            zoomSent = size
            onFont(size, x, y)
        }
    }

    private fun endDrag() {
        drag = false
        dragCell = null
        accum = 0.0
    }

    private fun endZoom() {
        zooming = false
        zoomDist = 0.0
    }

    /** Takes one step of the budget, or false while the budget is spent. */
    private fun take(): Boolean {
        val t = now()
        tokens = minOf(BURST.toDouble(), tokens + (t - tokenAt) * RATE / 1000.0)
        tokenAt = t
        if (tokens < 1.0) return false
        tokens -= 1.0
        return true
    }
}
