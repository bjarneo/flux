package org.omarchy.flux.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The touches of the terminal become wheel steps, zoom, and pan. */
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
    }

    private fun gestures(sink: Sink, clock: () -> Long = { 0L }): TerminalGestures {
        val g = TerminalGestures(
            now = clock,
            onWheel = { column, row, direction -> sink.wheels += Triple(column, row, direction) },
            onFont = { size, x, y -> sink.fonts += Triple(size, x, y) },
            onPan = { dx, dy -> sink.pans += dx to dy },
        )
        g.geometry = grid
        return g
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
        g.touch("move", 1, 205.0, 85.0) // one step up
        assertEquals(listOf(Triple(20, 5, "down")), sink.wheels)
        g.touch("move", 1, 205.0, 125.0) // two steps down
        assertEquals(
            listOf(Triple(20, 5, "down"), Triple(20, 5, "up"), Triple(20, 5, "up")),
            sink.wheels,
        )
    }

    @Test
    fun fractionalMovementAccumulatesIntoSteps() {
        val sink = Sink()
        val g = gestures(sink)
        g.control = true
        g.touch("down", 1, 55.0, 205.0) // the cell (5, 10)
        g.touch("move", 1, 55.0, 195.0) // half a step
        assertTrue(sink.wheels.isEmpty())
        g.touch("move", 1, 55.0, 185.0) // the other half
        assertEquals(listOf(Triple(5, 10, "down")), sink.wheels)
        g.touch("move", 1, 55.0, 170.0) // three quarters: still nothing
        assertEquals(1, sink.wheels.size)
        g.touch("move", 1, 55.0, 160.0) // one more step
        assertEquals(2, sink.wheels.size)
    }

    @Test
    fun theBudgetAllowsABurstAndThenWaits() {
        val sink = Sink()
        var now = 0L
        val g = gestures(sink) { now }
        g.control = true
        g.touch("down", 1, 55.0, 205.0)
        repeat(15) { g.touch("move", 1, 55.0, 205.0 - 20.0 * (it + 1)) }
        assertEquals(TerminalGestures.BURST, sink.wheels.size)
        // One second later the budget refills and a new drag scrolls again.
        now = 1000
        g.touch("up", 1, 55.0, 0.0)
        g.touch("down", 1, 55.0, 205.0)
        repeat(5) { g.touch("move", 1, 55.0, 205.0 - 20.0 * (it + 1)) }
        assertEquals(TerminalGestures.BURST + 5, sink.wheels.size)
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
        g.touch("move", 1, 105.0, 95.0) // half a step
        g.geometry = grid.copy(cols = 80) // the screen changed under the finger
        g.touch("move", 1, 105.0, 85.0)
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
        g.touch("move", 1, 55.0, 195.0) // half a step
        g.touch("up", 1, 55.0, 195.0)
        g.touch("move", 1, 55.0, 155.0) // the lifted finger sends nothing
        assertTrue(sink.wheels.isEmpty())
        g.touch("down", 1, 55.0, 205.0) // a new gesture starts clean
        g.touch("move", 1, 55.0, 185.0)
        assertEquals(listOf(Triple(5, 10, "down")), sink.wheels)
    }
}
