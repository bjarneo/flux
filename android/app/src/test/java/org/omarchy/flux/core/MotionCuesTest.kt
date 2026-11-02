package org.omarchy.flux.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.OUTGOING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.json
import kotlin.math.abs

class MotionCuesTest {
    private fun roundTrip(m: MotionMessage): MotionMessage? {
        val p = Packet.parse(m.packet().serialize().trim())!!
        assertEquals(Types.FLUX_MOTION, p.type)
        return MotionMessage.parse(p.body)
    }

    private fun body(text: String): JsonObject = json.parseToJsonElement(text).jsonObject

    private fun sample(t: Long, x: Double = 0.0) = MotionSample(t, x, 0.0, 0.0, Mount.Flat)

    @Test
    fun listedBothWays() {
        assertTrue(Types.FLUX_MOTION in INCOMING)
        assertTrue(Types.FLUX_MOTION in OUTGOING)
    }

    // ---------------------------------------------------------------- bodies

    @Test
    fun computerBodies() {
        assertEquals(MotionMessage.Config(enabled = true, auto = false), MotionMessage.parse(body("""{"action":"config","enabled":true,"auto":false}""")))
        assertEquals(MotionMessage.Config(enabled = false, auto = false), MotionMessage.parse(body("""{"action":"config"}""")))
        assertEquals(MotionMessage.Start(30), MotionMessage.parse(body("""{"action":"start","rate":30}""")))
        assertEquals(MotionMessage.Start(25), MotionMessage.parse(body("""{"action":"start","rate":25.0}""")))
        assertEquals(MotionMessage.Start(null), MotionMessage.parse(body("""{"action":"start"}""")))
        assertEquals(MotionMessage.Stop, MotionMessage.parse(body("""{"action":"stop"}""")))
        assertNull(MotionMessage.parse(body("""{"action":"dance"}""")))
        assertNull(MotionMessage.parse(body("""{}""")))
        assertNull(MotionMessage.parse(body("""{"action":"vehicle"}""")))
    }

    @Test
    fun everyActionRoundTrips() {
        val all = listOf(
            MotionMessage.Config(enabled = true, auto = true),
            MotionMessage.Config(enabled = false, auto = true),
            MotionMessage.Start(),
            MotionMessage.Start(42),
            MotionMessage.Stop,
            MotionMessage.State(running = true),
            MotionMessage.State(running = false, error = "no accelerometer"),
            MotionMessage.Vehicle(true),
            MotionMessage.Vehicle(false),
            MotionMessage.Samples(listOf(MotionSample(123456789L, 0.125, -1.5, 9.0, Mount.Upright), sample(123456822L))),
        )
        for (m in all) assertEquals(m, roundTrip(m))
    }

    @Test
    fun wireFormat() {
        assertEquals("""{"action":"start"}""", MotionMessage.Start().body().toString())
        assertEquals("""{"action":"stop"}""", MotionMessage.Stop.body().toString())
        assertEquals("""{"action":"vehicle","in":true}""", MotionMessage.Vehicle(true).body().toString())
        // The state leaves out the error when there is none.
        assertEquals("""{"action":"state","running":true}""", MotionMessage.State(true).body().toString())
        assertEquals("""{"action":"state","running":false,"error":"no accelerometer"}""", MotionMessage.State(false, "no accelerometer").body().toString())
        val s = MotionMessage.Samples(listOf(MotionSample(1000L, 0.12345, -2.0, 0.0, Mount.Upright))).body()
        assertEquals("""{"samples":[{"t":1000,"x":0.123,"y":-2.0,"z":0.0,"mount":"upright"}]}""", s.toString())
        assertNull(s["action"])
        // The time is an integer, not a decimal.
        val t = ((s["samples"] as JsonArray)[0] as JsonObject)["t"] as JsonPrimitive
        assertFalse(t.content.contains('.'))
    }

    @Test
    fun sampleLimits() {
        // A full batch of 16 samples stays far under the 4 KiB limit of the computer.
        val full = MotionMessage.Samples(List(MOTION_BATCH_MAX) { MotionSample(1_700_000_000_000L + it, -199.999, 199.999, -0.001, Mount.Upright) })
        assertTrue(full.body().toString().toByteArray().size < 4096)
        // More than 16 samples is not a valid body.
        val tooMany = MotionMessage.Samples(List(MOTION_BATCH_MAX + 1) { sample(it.toLong()) }).body()
        assertNull(MotionMessage.parse(tooMany))
        // A sample with a value out of the limit drops.
        val bad = MotionMessage.parse(body("""{"samples":[{"t":1,"x":201,"y":0,"z":0,"mount":"flat"},{"t":2,"x":1,"y":0,"z":0}]}""")) as MotionMessage.Samples
        assertEquals(listOf(MotionSample(2, 1.0, 0.0, 0.0, Mount.Flat)), bad.samples)
        assertFalse(validAccel(Double.NaN))
        assertFalse(validAccel(Double.POSITIVE_INFINITY))
        assertTrue(validAccel(-200.0))
    }

    @Test
    fun mountKeys() {
        assertEquals(Mount.Flat, Mount.fromKey("flat"))
        assertEquals(Mount.Upright, Mount.fromKey("upright"))
        assertEquals(Mount.Flat, Mount.fromKey(null))
        assertEquals(Mount.Flat, Mount.fromKey("sideways"))
    }

    @Test
    fun rateClamp() {
        assertEquals(30, clampMotionRate(null))
        assertEquals(30, clampMotionRate(30))
        assertEquals(5, clampMotionRate(1))
        assertEquals(5, clampMotionRate(-10))
        assertEquals(60, clampMotionRate(1000))
        assertEquals(60, clampMotionRate(60))
        assertEquals(5, clampMotionRate(5))
        assertEquals(5, clampMotionRate(0))
    }

    // ---------------------------------------------------------------- gravity

    @Test
    fun gravityFilterRemovesASteadyPull() {
        val f = GravityFilter(0.8)
        // The first sample primes the estimate, so a phone at rest reads 0 and not 9.8.
        val first = f.update(0.0, 0.0, 9.81)
        assertEquals(0.0, first[2], 1e-9)
        repeat(100) { f.update(0.0, 0.0, 9.81) }
        assertEquals(0.0, f.update(0.0, 0.0, 9.81)[2], 1e-9)
        // A step of 2 m/s² shows at once, then fades as the estimate follows it.
        val step = f.update(2.0, 0.0, 9.81)
        assertEquals(2.0 * 0.8, step[0], 1e-9)
        var last = step[0]
        repeat(50) { last = f.update(2.0, 0.0, 9.81)[0] }
        assertTrue(abs(last) < 0.01)
    }

    @Test
    fun gravityFilterReset() {
        val f = GravityFilter()
        f.update(0.0, 9.81, 0.0)
        f.reset()
        assertEquals(0.0, f.update(9.81, 0.0, 0.0)[0], 1e-9)
    }

    // --------------------------------------------------------------- batching

    @Test
    fun batchesAtMost16() {
        val b = SampleBatcher()
        repeat(40) { b.add(sample(it.toLong())) }
        val batch = b.take(0, busy = false)!!
        assertEquals(MOTION_BATCH_MAX, batch.size)
        // The newest samples stay.
        assertEquals(24L, batch.first().t)
        assertEquals(39L, batch.last().t)
        assertEquals(24L, b.dropped)
    }

    @Test
    fun batchesAtLeast50MsApart() {
        val b = SampleBatcher()
        assertNull(b.take(0, busy = false))
        b.add(sample(1))
        assertEquals(1, b.take(1000, busy = false)!!.size)
        b.add(sample(2))
        assertNull(b.take(1049, busy = false))
        assertEquals(1, b.size)
        b.add(sample(3))
        val next = b.take(1050, busy = false)!!
        assertEquals(listOf(2L, 3L), next.map { it.t })
        assertEquals(0, b.size)
    }

    @Test
    fun dropsWhenTheLinkIsBehind() {
        val b = SampleBatcher()
        b.add(sample(1))
        b.add(sample(2))
        assertNull(b.take(0, busy = true))
        assertEquals(0, b.size)
        assertEquals(2L, b.dropped)
        // A drop is not a send, so the next batch can go at once.
        b.add(sample(3))
        assertEquals(listOf(3L), b.take(1, busy = false)!!.map { it.t })
    }

    // ----------------------------------------------------------- vehicle exit

    @Test
    fun exitHoldsFor60Seconds() {
        val v = VehicleDebounce(60_000)
        assertTrue(v.enter())
        assertTrue(v.inside)
        assertEquals(70_000L, v.exit(10_000))
        assertFalse(v.due(69_999))
        assertTrue(v.inside)
        assertTrue(v.due(70_000))
        assertFalse(v.inside)
        // It reports the exit only once.
        assertFalse(v.due(80_000))
    }

    @Test
    fun enterCancelsAPendingExit() {
        val v = VehicleDebounce(60_000)
        v.enter()
        v.exit(0)
        // A stop at a light: the next enter comes before the exit holds, and the computers hear nothing.
        assertFalse(v.enter())
        assertNull(v.pendingExit)
        assertFalse(v.due(120_000))
        assertTrue(v.inside)
    }

    @Test
    fun exitWithoutEnterAndRepeats() {
        val v = VehicleDebounce(60_000)
        // An exit before any enter does not stop a run that started by hand.
        assertNull(v.exit(0))
        assertFalse(v.due(100_000))
        v.enter()
        assertFalse(v.enter())
        // A second exit does not move the time of the first.
        assertEquals(60_000L, v.exit(0))
        assertNull(v.exit(30_000))
        assertTrue(v.due(60_000))
    }

    @Test
    fun configDuringATripGetsVehicleIn() {
        val v = VehicleDebounce(60_000)
        val on = MotionMessage.Config(enabled = true, auto = true)
        // Not in a vehicle: no answer, also no vehicle in false.
        assertNull(vehicleReplyTo(on, v.inside))
        v.enter()
        assertEquals(MotionMessage.Vehicle(true), vehicleReplyTo(on, v.inside))
        assertEquals("""{"action":"vehicle","in":true}""", vehicleReplyTo(on, v.inside)!!.body().toString())
        // A computer without motion cues or without automatic start gets nothing.
        assertNull(vehicleReplyTo(MotionMessage.Config(enabled = true, auto = false), v.inside))
        assertNull(vehicleReplyTo(MotionMessage.Config(enabled = false, auto = true), v.inside))
        // During a pending exit the phone is still in the vehicle.
        v.exit(0)
        assertEquals(MotionMessage.Vehicle(true), vehicleReplyTo(on, v.inside))
        // After the exit holds, the answer stops.
        v.due(60_000)
        assertNull(vehicleReplyTo(on, v.inside))
    }

    @Test
    fun resetForgetsTheTrip() {
        val v = VehicleDebounce(60_000)
        v.enter()
        v.exit(0)
        v.reset()
        assertFalse(v.inside)
        assertFalse(v.due(60_000))
        assertTrue(v.enter())
    }
}
