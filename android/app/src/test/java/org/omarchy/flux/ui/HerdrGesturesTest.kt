package org.omarchy.flux.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The touches of the terminal become wheel steps, zoom, pan, and a fling. */
class HerdrGesturesTest {

    /** A grid of 10x20 pixel cells at the origin, 120x40 cells. */
    private val grid = TerminalGeometry(
        cellW = 10.0, cellH = 20.0, originX = 0.0, originY = 0.0,
        cols = 120, rows = 40, font = 13,
    )

    private class Sink {
        val wheels = mutableListOf<Triple<Int, Int, String>>()
        val fonts = mutableListOf<Triple<Int, Double, Double>>()
        val pans = mutableListOf<Pair<Double, Double>>()
        val taps = mutableListOf<Pair<Int, Int>>()
    }

    private fun gestures(
        sink: Sink,
        clock: () -> Long = { 0L },
        post: (Long, () -> Unit) -> Unit = { _, _ -> },
        scrollScale: Double = 1.0,
    ): TerminalGestures {
        val g = TerminalGestures(
            now = clock,
            onWheel = { column, row, direction -> sink.wheels += Triple(column, row, direction) },
            onFont = { size, x, y -> sink.fonts += Triple(size, x, y) },
            onPan = { dx, dy -> sink.pans += dx to dy },
            post = post,
            scrollScale = scrollScale,
            onTap = { column, row -> sink.taps += column to row },
        )
        g.geometry = grid
        return g
    }

    @Test
    fun aBriefStationaryTouchClicksOnceAtTheTouchedCell() {
        val sink = Sink()
        val g = gestures(sink)
        g.geometry = grid.copy(originX = 30.0, originY = 40.0, cellW = 20.0, cellH = 40.0)
        g.control = true
        g.touch("down", 1, 135.0, 125.0, at = 0)
        assertTrue(sink.taps.isEmpty())
        g.touch("up", 1, 136.0, 126.0, at = 100)
        g.touch("up", 1, 136.0, 126.0, at = 110)
        assertEquals(listOf(5 to 2), sink.taps)
        assertTrue(sink.wheels.isEmpty())
    }

    @Test
    fun draggingAwayAndBackNeverBecomesAClick() {
        for ((dx, dy) in listOf(0.0 to 20.0, 20.0 to 0.0)) {
            val sink = Sink()
            val g = gestures(sink)
            g.control = true
            g.touch("down", 1, 55.0, 205.0, at = 0)
            g.touch("move", 1, 55.0 + dx, 205.0 + dy, at = 20)
            g.touch("up", 1, 55.0, 205.0, at = 40)
            assertTrue(sink.taps.isEmpty())
        }
    }

    @Test
    fun longPressCancelObserveAndMarginsNeverClick() {
        for (scenario in listOf("long", "cancel", "observe", "margin", "release", "resize")) {
            val sink = Sink()
            val g = gestures(sink)
            g.control = scenario != "observe"
            val x = if (scenario == "margin") -1.0 else 55.0
            g.touch("down", 1, x, 205.0, at = 0)
            if (scenario == "release") g.control = false
            if (scenario == "resize") g.geometry = grid.copy(originX = 5.0)
            g.touch(
                if (scenario == "cancel") "cancel" else "up", 1, x, 205.0,
                at = if (scenario == "long") 1000L else 100L,
            )
            assertTrue(scenario, sink.taps.isEmpty())
        }
    }

    @Test
    fun aSecondFingerDisqualifiesTheRemainingFingerFromClicking() {
        val sink = Sink()
        val g = gestures(sink)
        g.control = true
        g.touch("down", 1, 55.0, 205.0, at = 0)
        g.touch("down", 2, 155.0, 205.0, at = 10)
        g.touch("up", 2, 155.0, 205.0, at = 20)
        g.touch("up", 1, 55.0, 205.0, at = 30)
        assertTrue(sink.taps.isEmpty())
    }

    @Test
    fun touchingToStopInertiaDoesNotAlsoClick() {
        val sink = Sink()
        val pending = ArrayDeque<() -> Unit>()
        val g = gestures(sink, { 1000L }, { _, action -> pending.addLast(action) })
        g.control = true
        g.touch("down", 1, 55.0, 400.0, at = 0)
        g.touch("move", 1, 55.0, 340.0, at = 20)
        g.touch("up", 1, 55.0, 280.0, at = 40)
        assertTrue(pending.isNotEmpty())
        g.touch("down", 1, 55.0, 205.0, at = 60)
        g.touch("up", 1, 55.0, 205.0, at = 100)
        assertTrue(sink.taps.isEmpty())
        g.touch("down", 1, 55.0, 205.0, at = 120)
        g.touch("up", 1, 55.0, 205.0, at = 160)
        assertEquals(listOf(5 to 10), sink.taps)
    }

    @Test
    fun calibratedDragSendsOneStepPer18PixelsWhileTheFingerIsDown() {
        val sink = Sink()
        val g = gestures(sink, scrollScale = TerminalGestures.SCROLL_SCALE)
        g.control = true
        g.touch("down", 1, 55.0, 400.0)
        for (sample in 1..10) {
            g.touch("move", 1, 55.0, 400.0 - sample * 18.0)
            assertEquals(sample, sink.wheels.size)
        }
    }

    @Test
    fun flingDistanceDoesNotDependOnAnimationCallbackFrequency() {
        fun run(ticks: List<Long>): Int {
            val sink = Sink()
            var time = 0L
            val callbacks = ArrayDeque<() -> Unit>()
            val g = gestures(sink, { time }, { _, action -> callbacks.addLast(action) })
            g.control = true
            g.touch("down", 1, 55.0, 400.0, at = 0)
            g.touch("move", 1, 55.0, 340.0, at = 20)
            g.touch("up", 1, 55.0, 280.0, at = 40)
            val before = sink.wheels.size
            for (tick in ticks) {
                time = tick
                callbacks.removeFirst()()
            }
            return sink.wheels.size - before
        }
        assertEquals(run(listOf(48)), run(listOf(16, 32, 48)))
    }

    @Test
    fun delayedFlingStopsInsteadOfCatchingUpWithABurst() {
        val sink = Sink()
        var time = 0L
        val callbacks = ArrayDeque<() -> Unit>()
        val g = gestures(sink, { time }, { _, action -> callbacks.addLast(action) })
        g.control = true
        g.touch("down", 1, 55.0, 400.0, at = 0)
        g.touch("move", 1, 55.0, 340.0, at = 20)
        g.touch("up", 1, 55.0, 280.0, at = 40)
        val before = sink.wheels.size
        time = 1000
        callbacks.removeFirst()()
        assertEquals(before, sink.wheels.size)
        assertTrue(callbacks.isEmpty())
    }

    @Test
    fun cellAtMapsTheGridAndRejectsMargins() {
        assertEquals(0 to 0, grid.cellAt(5.0, 5.0))
        assertEquals(10 to 2, grid.cellAt(105.0, 55.0))
        assertEquals(119 to 39, grid.cellAt(1199.0, 799.0))
        assertNull(grid.cellAt(-1.0, 5.0))
        assertNull(grid.cellAt(1200.0, 5.0))
        assertNull(grid.cellAt(5.0, 800.0))
    }

    @Test
    fun aControlDragScrollsAtTheTouchedCell() {
        val sink = Sink()
        val g = gestures(sink)
        g.control = true
        g.touch("down", 1, 205.0, 105.0) // the cell (20, 5)
        g.touch("move", 1, 205.0, 99.0) // 6 px up: one step
        assertEquals(listOf(Triple(20, 5, "down")), sink.wheels)
        g.touch("move", 1, 205.0, 111.0) // 12 px down: two steps
        assertEquals(
            listOf(Triple(20, 5, "down"), Triple(20, 5, "up"), Triple(20, 5, "up")),
            sink.wheels,
        )
    }

    @Test
    fun theStepDoesNotChangeWithTheFont() {
        // The same finger travel gives the same number of steps, whatever
        // the height of a cell is: zooming does not change the effort.
        for (cellH in listOf(20.0, 40.0)) {
            val sink = Sink()
            val g = gestures(sink)
            g.geometry = grid.copy(cellH = cellH)
            g.control = true
            g.touch("down", 1, 55.0, 205.0)
            g.touch("move", 1, 55.0, 187.0) // 18 px up
            assertEquals(3, sink.wheels.size)
        }
    }

    @Test
    fun aSidewaysSwipeNeverScrolls() {
        val sink = Sink()
        val g = gestures(sink)
        g.control = true
        g.touch("down", 1, 100.0, 200.0)
        g.touch("move", 1, 130.0, 203.0)
        g.touch("move", 1, 160.0, 206.0)
        assertTrue(sink.wheels.isEmpty())
    }

    @Test
    fun fractionalMovementAccumulatesIntoSteps() {
        val sink = Sink()
        val g = gestures(sink)
        g.control = true
        g.touch("down", 1, 55.0, 205.0) // the cell (5, 10)
        g.touch("move", 1, 55.0, 202.0) // 3 px: the axis is not chosen yet
        assertTrue(sink.wheels.isEmpty())
        g.touch("move", 1, 55.0, 199.0) // 6 px in all: one step
        assertEquals(listOf(Triple(5, 10, "down")), sink.wheels)
        g.touch("move", 1, 55.0, 196.0) // 3 px more: not a step yet
        assertEquals(1, sink.wheels.size)
        g.touch("move", 1, 55.0, 193.0) // 6 px more: the second step
        assertEquals(2, sink.wheels.size)
    }

    @Test
    fun everyStepOfALongDragIsSent() {
        // A long drag must not lose travel to a rate limit: 1400 px of finger
        // movement become every whole 6 px step.
        val sink = Sink()
        val g = gestures(sink)
        g.geometry = grid.copy(rows = 200)
        g.control = true
        g.touch("down", 1, 55.0, 1500.0)
        for (i in 1..70) g.touch("move", 1, 55.0, 1500.0 - 20.0 * i)
        assertEquals(1400 / 6, sink.wheels.size)
    }

    @Test
    fun aHeldFingerScrollsOnEveryPositionBeforeTheLift() {
        val sink = Sink()
        val g = gestures(sink, clock = { 10_000L })
        g.geometry = grid.copy(rows = 200)
        g.control = true
        g.touch("down", 1, 55.0, 1200.0, at = 0)
        for (sample in 1..20) {
            g.touch("move", 1, 55.0, 1200.0 - sample * 12, at = sample * 50L)
            // No lift between these samples: each position advances the pane.
            assertEquals(sample * 2, sink.wheels.size)
        }
        g.touch("up", 1, 55.0, 960.0, at = 1000)
        assertEquals(40, sink.wheels.size)
        assertTrue(sink.taps.isEmpty())
    }

    @Test
    fun batchedPositionsUseTheirOriginalTimesForTheLiftSpeed() {
        val sink = Sink()
        val pending = ArrayDeque<() -> Unit>()
        // All these samples are processed at once, not at their event times.
        var processingTime = 10_000L
        val g = gestures(sink, { processingTime }, { _, action -> pending.addLast(action) })
        g.control = true
        g.touch("down", 1, 55.0, 400.0, at = 100)
        g.touch("move", 1, 55.0, 370.0, at = 120)
        g.touch("move", 1, 55.0, 340.0, at = 140)
        g.touch("up", 1, 55.0, 310.0, at = 160)
        assertEquals(15, sink.wheels.size)
        assertTrue(pending.isNotEmpty())
        processingTime += 16
        pending.removeFirst()()
        // 1.5 px/ms at the lift adds three wheel steps in the first tick.
        assertEquals(18, sink.wheels.size)
        assertEquals("down", sink.wheels.last().third)
    }

    @Test
    fun pausingBeforeTheLiftDoesNotStartAnotherFling() {
        val sink = Sink()
        val pending = ArrayDeque<() -> Unit>()
        val g = gestures(sink, { 1000L }, { _, action -> pending.addLast(action) })
        g.control = true
        g.touch("down", 1, 55.0, 400.0, at = 0)
        g.touch("move", 1, 55.0, 340.0, at = 20)
        g.touch("move", 1, 55.0, 280.0, at = 40)
        g.touch("up", 1, 55.0, 280.0, at = 500)
        assertTrue(pending.isEmpty())
        assertTrue(sink.taps.isEmpty())
    }

    @Test
    fun aCancelledDragStopsInputAndNeverStartsAFling() {
        val sink = Sink()
        val pending = ArrayDeque<() -> Unit>()
        val g = gestures(sink, { 1000L }, { _, action -> pending.addLast(action) })
        g.control = true
        g.touch("down", 1, 55.0, 400.0, at = 0)
        g.touch("move", 1, 55.0, 340.0, at = 20)
        g.touch("cancel", 1, 55.0, 340.0, at = 30)
        val before = sink.wheels.size
        g.touch("move", 1, 55.0, 280.0, at = 40)
        assertEquals(before, sink.wheels.size)
        assertTrue(pending.isEmpty())
        assertTrue(sink.taps.isEmpty())
    }

    @Test
    fun aJumpBeyondAFingerMoveIsBounded() {
        val sink = Sink()
        val g = gestures(sink)
        g.control = true
        g.touch("down", 1, 55.0, 205.0)
        g.touch("move", 1, 55.0, -5000.0) // a lost or reused touch
        assertEquals((TerminalGestures.MAX_DELTA_PX / TerminalGestures.STEP_PX).toInt(),
            sink.wheels.size)
    }

    @Test
    fun aReversalRespondsAtOnce() {
        val sink = Sink()
        val g = gestures(sink)
        g.control = true
        g.touch("down", 1, 55.0, 211.0)
        g.touch("move", 1, 55.0, 200.0) // 11 px up: one step, 5 px pending
        assertEquals(listOf("down"), sink.wheels.map { it.third })
        // Turning around drops the pending travel, so 9 px down sends a step
        // up at once instead of first absorbing the 5 px that were waiting.
        g.touch("move", 1, 55.0, 209.0)
        assertEquals(listOf("down", "up"), sink.wheels.map { it.third })
    }

    @Test
    fun aFastSwipeKeepsScrollingAfterTheLift() {
        val sink = Sink()
        var now = 0L
        val pending = ArrayDeque<() -> Unit>()
        val g = gestures(sink, { now }, { _, action -> pending.addLast(action) })
        g.control = true
        g.touch("down", 1, 55.0, 400.0)
        now = 20
        g.touch("move", 1, 55.0, 360.0)
        now = 40
        g.touch("move", 1, 55.0, 320.0)
        now = 60
        g.touch("up", 1, 55.0, 320.0)
        // A quick lift schedules the fling.
        assertTrue(pending.isNotEmpty())
        val atLift = sink.wheels.size
        now = 76
        pending.removeFirst()()
        assertTrue(sink.wheels.size > atLift)
    }

    @Test
    fun aNewTouchStopsTheFling() {
        val sink = Sink()
        var now = 0L
        val pending = ArrayDeque<() -> Unit>()
        val g = gestures(sink, { now }, { _, action -> pending.addLast(action) })
        g.control = true
        g.touch("down", 1, 55.0, 400.0)
        now = 20
        g.touch("move", 1, 55.0, 360.0)
        now = 40
        g.touch("up", 1, 55.0, 360.0)
        val stale = pending.removeFirst()
        // A new touch cancels the fling: the tick that was queued does nothing.
        g.touch("down", 1, 55.0, 400.0)
        val before = sink.wheels.size
        now = 5_000
        stale()
        assertEquals(before, sink.wheels.size)
    }

    @Test
    fun aControlGestureSendsTwoStepsWithoutATap() {
        val sink = Sink()
        val g = gestures(sink)
        g.control = true
        g.touch("down", 1, 55.0, 205.0)
        g.touch("move", 1, 55.0, 193.0) // 12 px up: two steps
        g.touch("up", 1, 55.0, 193.0)
        assertEquals(2, sink.wheels.size)
        assertTrue(sink.taps.isEmpty())
    }

    @Test
    fun twoFingersZoomAndPanButNeverScroll() {
        val sink = Sink()
        val g = gestures(sink)
        g.control = true
        g.touch("down", 1, 100.0, 100.0)
        g.touch("down", 2, 200.0, 100.0) // a drag becomes a pinch
        g.touch("move", 1, 50.0, 100.0) // 1.5x wider
        assertTrue(sink.wheels.isEmpty())
        assertTrue(sink.pans.isNotEmpty())
        assertEquals(listOf(Triple(20, 125.0, 100.0)), sink.fonts)
        g.touch("up", 1, 50.0, 100.0) // the finger that is left inherits nothing
        g.touch("move", 2, 200.0, 300.0)
        assertTrue(sink.wheels.isEmpty())
        assertEquals(1, sink.pans.size)
    }

    @Test
    fun anObserveDragOnlyPans() {
        val sink = Sink()
        val g = gestures(sink) // control is off
        g.touch("down", 1, 100.0, 100.0)
        g.touch("move", 1, 130.0, 140.0)
        assertEquals(listOf(30.0 to 40.0), sink.pans)
        assertTrue(sink.wheels.isEmpty())
    }

    @Test
    fun aNewGridEndsADrag() {
        val sink = Sink()
        val g = gestures(sink)
        g.control = true
        g.touch("down", 1, 105.0, 105.0)
        g.touch("move", 1, 105.0, 102.0) // the axis is not chosen yet
        g.geometry = grid.copy(cols = 80) // the screen changed under the finger
        g.touch("move", 1, 105.0, 95.0)
        assertTrue(sink.wheels.isEmpty())
    }

    @Test
    fun aDragOutsideTheGridSendsNothing() {
        val sink = Sink()
        val g = gestures(sink)
        g.control = true
        g.touch("down", 1, 5000.0, 5000.0)
        repeat(4) { g.touch("move", 1, 5000.0, 5000.0 - 20.0 * (it + 1)) }
        assertTrue(sink.wheels.isEmpty())
        assertTrue(sink.pans.isEmpty())
    }

    @Test
    fun liftingAFingerEndsItsGesture() {
        val sink = Sink()
        val g = gestures(sink)
        g.control = true
        g.touch("down", 1, 55.0, 205.0)
        g.touch("move", 1, 55.0, 199.0) // one step
        g.touch("up", 1, 55.0, 199.0)
        g.touch("move", 1, 55.0, 145.0) // the lifted finger sends nothing
        assertEquals(1, sink.wheels.size)
        g.touch("down", 1, 55.0, 205.0) // a new gesture starts clean
        g.touch("move", 1, 55.0, 199.0)
        assertEquals(listOf(Triple(5, 10, "down"), Triple(5, 10, "down")), sink.wheels)
    }
}
