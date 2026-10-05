package org.omarchy.flux.ui

import android.os.SystemClock
import kotlin.math.abs
import kotlin.math.exp
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
 * What one finished control gesture did, for tuning the feel on a real
 * phone. It carries numbers only: never the text of a conversation.
 */
data class GestureStats(
    /** The finger travel along the scroll axis, in CSS pixels. */
    val distance: Double,
    /** The wheel steps the gesture sent while the finger was down. */
    val steps: Int,
    /** From the first touch to the lift, in milliseconds. */
    val durationMs: Long,
    /** The finger speed at the lift, in pixels per millisecond. */
    val speed: Double,
    /** Positions processed while the finger was down, including batched ones. */
    val moves: Int,
    /** Whether the gesture ended with a lift or an Android cancellation. */
    val endReason: String,
)

/**
 * Turns the touches on the terminal into wheel steps and local zoom and
 * pan. While [control] is on, a one-finger drag scales its travel by
 * [SCROLL_SCALE] and sends one wheel step per [STEP_PX], at the touched cell, so the
 * gesture scrolls the conversation of the pane on the computer too. In
 * observe mode the same drag only pans the local view. Two fingers
 * always zoom and pan locally and send nothing.
 *
 * The step is a fixed distance of the finger, so a font change or a
 * zoom does not change the effort to scroll. A gesture picks its axis
 * after a short travel, so a sideways swipe never scrolls. A quick
 * gesture keeps scrolling for a short, decelerating moment after the
 * lift (see [startFling]); a new touch stops it at once.
 *
 * Every step of the finger travel is sent: the engine never drops
 * movement to stay under a rate. The touches and the fling ticks pace
 * the steps, and the bridge coalesces the redraws it cannot use. A
 * change of the grid ends the gesture at once, so a step never
 * reinterprets the coordinates of an older screen.
 *
 * The callbacks run on the thread of the caller, which is the main
 * thread when the page forwards its touches. [post] schedules the fling
 * ticks on that same thread; it is a no-op by default, for tests.
 */
class TerminalGestures(
    private val now: () -> Long = { SystemClock.uptimeMillis() },
    private val onWheel: (column: Int, row: Int, direction: String) -> Unit,
    private val onFont: (size: Int, focalX: Double, focalY: Double) -> Unit,
    private val onPan: (dx: Double, dy: Double) -> Unit,
    private val onStats: (GestureStats) -> Unit = {},
    private val post: (delayMs: Long, action: () -> Unit) -> Unit = { _, _ -> },
    private val scrollScale: Double = SCROLL_SCALE,
    private val onTap: (column: Int, row: Int) -> Unit = { _, _ -> },
) {
    companion object {
        /**
         * The scaled travel of one wheel step. Dividing by SCROLL_SCALE
         * gives the CSS pixel distance of the finger, independent of font.
         */
        const val STEP_PX = 6.0

        /** Initial phone calibration: one wheel step per 18 CSS px of finger travel. */
        const val SCROLL_SCALE = 1.0 / 3.0

        /** The travel after which a gesture is vertical or horizontal. */
        const val LOCK_PX = 6.0

        /** A click requires a brief touch that never leaves this radius. */
        const val TAP_SLOP_PX = 6.0
        const val TAP_MAX_MS = 350L

        /**
         * The largest movement of one touch event that counts as a finger
         * move, in CSS pixels. A larger jump is a lost or reused touch, not
         * a swipe, so it must not become a burst of steps.
         */
        const val MAX_DELTA_PX = 240.0

        /** A bound on the movement that waits for the fling ticks. */
        const val MAX_PENDING_PX = 1200.0

        /** The largest font of the zoom. Smaller than this is the fit of the grid. */
        const val FONT_MAX = 24

        /** The lift speed of the smallest fling, in pixels per millisecond. */
        const val FLING_MIN = 0.35

        /** The fastest fling, in pixels per millisecond. */
        const val FLING_MAX = 3.0

        /** The time constant of the fling slowdown, in milliseconds. */
        const val FLING_TAU_MS = 250.0

        /** A delayed animation must stop instead of catching up in one large jump. */
        const val FLING_MAX_GAP_MS = 64.0

        /** The fling ends below this speed, in pixels per millisecond. */
        const val FLING_STOP = 0.3

        /** The fling ends after this long, in milliseconds. */
        const val FLING_MAX_MS = 900.0

        /** The distance of one fling tick, and its length in milliseconds. */
        const val FLING_TICK_MS = 16L

        /** The window of the lift speed, in milliseconds. */
        const val FLING_WINDOW_MS = 100L
    }

    /** True while the phone controls the terminal. */
    var control = false
        set(value) {
            if (field != value) {
                endDrag()
                endFling()
            }
            field = value
        }

    /** The grid as the page draws it. A new grid ends a running gesture. */
    var geometry = TerminalGeometry()
        set(value) {
            if (value != field) tapEligible = false
            if (value.cols != field.cols || value.rows != field.rows) {
                endDrag()
                endFling()
            }
            field = value
        }

    private val points = mutableMapOf<Int, Pair<Double, Double>>()
    private var drag = false
    private var dragCell: Pair<Int, Int>? = null
    private var lastX = 0.0
    private var lastY = 0.0
    private var totalX = 0.0
    private var totalY = 0.0
    private var vertical = false
    private var tapEligible = false
    private var startX = 0.0
    private var startY = 0.0

    /** The finger travel that still owes wheel steps, in CSS pixels. */
    private var pending = 0.0
    private var zooming = false
    private var zoomDist = 0.0
    private var zoomFont = 0
    private var zoomSent = 0
    private var midX = 0.0
    private var midY = 0.0

    // The lift speed uses the recent positions of the finger.
    private val vel = ArrayDeque<Pair<Long, Double>>()

    // A fling runs on the ticks that [post] schedules. The generation
    // ends it: an old tick sees a newer number and does nothing.
    private var flingGen = 0
    private var flingV = 0.0
    private var flingCell: Pair<Int, Int>? = null
    private var flingAt = 0L
    private var flingMs = 0.0

    // The numbers of one control gesture, reported at the lift.
    private var statStart = 0L
    private var statDistance = 0.0
    private var statSteps = 0
    private var statMoves = 0

    /** One touch of the page at ([x], [y]) in CSS pixels. Any thread. */
    fun touch(action: String, id: Int, x: Double, y: Double, at: Long = now()) {
        when (action) {
            "down" -> {
                val stoppingFling = flingCell != null
                endFling()
                points[id] = x to y
                if (points.size >= 2) startZoom() else startDrag(x, y, at)
                // Touching a moving terminal stops inertia, not a remote button.
                if (stoppingFling) tapEligible = false
            }
            "move" -> {
                if (points[id] == null) return
                points[id] = x to y
                if (points.size >= 2) moveZoom() else moveDrag(x, y, at)
            }
            // A lift or a cancel only ends its gesture: the finger that
            // is left does not inherit it.
            else -> {
                if (points[id] == null) return
                if (action == "up" && points.size == 1) moveDrag(x, y, at)
                points.remove(id)
                if (points.size < 2) endZoom()
                if (points.isEmpty()) lift(action == "up", at)
            }
        }
    }

    /** Ends every gesture and forgets the fingers. */
    fun reset() {
        points.clear()
        endDrag()
        endZoom()
        endFling()
    }

    private fun startDrag(x: Double, y: Double, at: Long) {
        endZoom()
        drag = true
        dragCell = if (control) geometry.cellAt(x, y) else null
        tapEligible = dragCell != null
        startX = x
        startY = y
        lastX = x
        lastY = y
        totalX = 0.0
        totalY = 0.0
        vertical = false
        pending = 0.0
        statStart = at
        statDistance = 0.0
        statSteps = 0
        statMoves = 0
        vel.clear()
        vel.addLast(statStart to y)
    }

    private fun moveDrag(x: Double, y: Double, at: Long) {
        if (!drag) return
        val rawX = x - lastX
        val rawY = y - lastY
        lastX = x
        lastY = y
        if (hypot(x - startX, y - startY) >= TAP_SLOP_PX) tapEligible = false
        if (!control) {
            if (rawX != 0.0 || rawY != 0.0) onPan(rawX, rawY)
            return
        }
        // A drag that began outside the grid sends nothing at all.
        val cell = dragCell ?: return
        statMoves++
        // A jump beyond a finger move is a lost or reused touch, not a
        // swipe, so it must not become a burst of steps.
        val dx = rawX.coerceIn(-MAX_DELTA_PX, MAX_DELTA_PX)
        val dy = rawY.coerceIn(-MAX_DELTA_PX, MAX_DELTA_PX)
        totalX += dx
        totalY += dy
        if (!vertical) {
            // The gesture picks its axis after a short travel, so a
            // mainly sideways swipe does not scroll the conversation.
            if (abs(totalY) < LOCK_PX || abs(totalY) <= abs(totalX)) return
            vertical = true
            pending = totalY * scrollScale
        } else {
            // A change of direction drops the pending travel, so turning
            // around responds at once instead of waiting for it.
            if (pending != 0.0 && pending * dy < 0.0) pending = 0.0
            pending += dy * scrollScale
        }
        pending = pending.coerceIn(-MAX_PENDING_PX, MAX_PENDING_PX)
        statDistance += abs(dy)
        vel.addLast(at to y)
        while (vel.size > 2 && at - vel.first().first > FLING_WINDOW_MS) vel.removeFirst()
        emit(cell)
    }

    private fun startZoom() {
        endDrag()
        endFling()
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

    /** Ends the gesture of the last finger, and reports what it did. */
    private fun lift(fling: Boolean, at: Long) {
        val active = drag && control
        val speed = if (fling && active) dragSpeed() else 0.0
        val cell = dragCell
        val wasVertical = vertical
        val tap = active && fling && tapEligible && at - statStart in 0..TAP_MAX_MS &&
            geometry.cellAt(lastX, lastY) != null
        if (active) {
            onStats(GestureStats(
                statDistance, statSteps, at - statStart, speed, statMoves,
                if (fling) "up" else "cancel",
            ))
        }
        endDrag()
        if (tap && cell != null) onTap(cell.first, cell.second)
        if (fling && control && wasVertical && cell != null) startFling(speed, cell)
    }

    /** The speed of the last window of finger movement, in pixels per millisecond. */
    private fun dragSpeed(): Double {
        if (vel.size < 2) return 0.0
        val first = vel.first()
        val last = vel.last()
        val dt = (last.first - first.first).toDouble()
        if (dt <= 0.0) return 0.0
        return (last.second - first.second) / dt
    }

    /**
     * A quick lift keeps scrolling for a short, decelerating moment. The
     * ticks add the travel of the fling and send it, so every step of the
     * finger still goes out: nothing is dropped to stay under a rate.
     */
    private fun startFling(speed: Double, cell: Pair<Int, Int>) {
        if (abs(speed) < FLING_MIN) return
        val gen = ++flingGen
        flingV = speed.coerceIn(-FLING_MAX, FLING_MAX)
        flingCell = cell
        flingAt = now()
        flingMs = 0.0
        post(FLING_TICK_MS) { flingTick(gen) }
    }

    private fun flingTick(gen: Int) {
        if (gen != flingGen || !control || drag || zooming) return
        val cell = flingCell ?: return
        val t = now()
        val dt = (t - flingAt).toDouble()
        if (dt <= 0.0) {
            post(FLING_TICK_MS) { flingTick(gen) }
            return
        }
        if (dt > FLING_MAX_GAP_MS || flingMs + dt > FLING_MAX_MS) {
            endFling()
            return
        }
        flingAt = t
        flingMs += dt
        // Integrate v(t) = v0 * exp(-t / tau) exactly. Distance then depends
        // on elapsed time, not on how many animation callbacks were delivered.
        val decay = exp(-dt / FLING_TAU_MS)
        pending += flingV * FLING_TAU_MS * (1.0 - decay) * scrollScale
        pending = pending.coerceIn(-MAX_PENDING_PX, MAX_PENDING_PX)
        emit(cell)
        flingV *= decay
        if (abs(flingV) >= FLING_STOP && flingMs < FLING_MAX_MS) {
            post(FLING_TICK_MS) { flingTick(gen) }
        } else {
            endFling()
        }
    }

    private fun emit(cell: Pair<Int, Int>) {
        while (abs(pending) >= STEP_PX) {
            val direction = if (pending < 0) "down" else "up"
            pending += if (pending < 0) STEP_PX else -STEP_PX
            statSteps++
            onWheel(cell.first, cell.second, direction)
        }
    }

    private fun endDrag() {
        drag = false
        tapEligible = false
        dragCell = null
        pending = 0.0
        vel.clear()
    }

    private fun endZoom() {
        zooming = false
        zoomDist = 0.0
    }

    private fun endFling() {
        flingGen++
        flingV = 0.0
        flingCell = null
        flingMs = 0.0
    }
}
