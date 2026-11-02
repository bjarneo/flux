package org.omarchy.flux.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import org.omarchy.flux.protocol.str
import kotlin.math.abs
import kotlin.math.roundToLong

// The motion cues logic that does not need Android: the flux.motion
// bodies, the gravity filter, the sample batches, and the vehicle exit
// delay. MotionCues.kt connects it to the sensor and the links.

/** How the phone sits in the vehicle. The computer reads the axes from it. */
enum class Mount(val key: String, val label: String) {
    /** The phone lies flat, screen up. */
    Flat("flat", "Flat"),

    /** The phone stands in a holder. */
    Upright("upright", "Upright");

    companion object {
        fun fromKey(key: String?): Mount = entries.firstOrNull { it.key == key } ?: Flat
    }
}

/**
 * 1 acceleration sample. [t] is a monotonic time in milliseconds. [x],
 * [y], and [z] are in m/s², without gravity, in the Android device axes.
 */
data class MotionSample(val t: Long, val x: Double, val y: Double, val z: Double, val mount: Mount)

/** The default sample rate in Hz. */
const val MOTION_RATE_DEFAULT = 30

/** The lowest and the highest sample rate that the phone takes, in Hz. */
const val MOTION_RATE_MIN = 5
const val MOTION_RATE_MAX = 60

/** The most samples in 1 packet. */
const val MOTION_BATCH_MAX = 16

/** The shortest time between 2 sample packets, in milliseconds. */
const val MOTION_BATCH_MS = 50L

/** The largest acceleration that the phone sends, in m/s². The computer drops larger values. */
const val MOTION_MAX_ACCEL = 200.0

/** Returns the sample rate in Hz for the rate of a start: [MOTION_RATE_DEFAULT] without one, else the rate in the limits. */
fun clampMotionRate(rate: Int?): Int = rate?.coerceIn(MOTION_RATE_MIN, MOTION_RATE_MAX) ?: MOTION_RATE_DEFAULT

/** 1 flux.motion body, in either direction. */
sealed class MotionMessage {
    /** The computer: its setting and its automatic start setting. */
    data class Config(val enabled: Boolean, val auto: Boolean) : MotionMessage()

    /**
     * Start. From the computer, it starts the sensor at [rate] Hz. From
     * the phone, it asks the computer to start, and has no rate.
     */
    data class Start(val rate: Int? = null) : MotionMessage()

    /** Stop, in either direction. */
    data object Stop : MotionMessage()

    /** The phone: whether the sensor runs, and the error when it failed. */
    data class State(val running: Boolean, val error: String? = null) : MotionMessage()

    /** The phone: it entered or left a vehicle. */
    data class Vehicle(val inside: Boolean) : MotionMessage()

    /** The phone: a batch of samples. */
    data class Samples(val samples: List<MotionSample>) : MotionMessage()

    fun body(): JsonObject = when (this) {
        is Config -> bodyOf("action" to "config", "enabled" to enabled, "auto" to auto)
        is Start -> if (rate == null) bodyOf("action" to "start") else bodyOf("action" to "start", "rate" to rate)
        Stop -> bodyOf("action" to "stop")
        is State -> if (error == null) bodyOf("action" to "state", "running" to running) else bodyOf("action" to "state", "running" to running, "error" to error)
        is Vehicle -> bodyOf("action" to "vehicle", "in" to inside)
        is Samples -> bodyOf(
            "samples" to samples.map { s ->
                mapOf("t" to s.t, "x" to round3(s.x), "y" to round3(s.y), "z" to round3(s.z), "mount" to s.mount.key)
            },
        )
    }

    fun packet(): Packet = Packet(Types.FLUX_MOTION, body())

    companion object {
        /** Reads a flux.motion body. It returns null for a body that it does not know. */
        fun parse(b: JsonObject): MotionMessage? {
            (b["samples"] as? JsonArray)?.let { arr ->
                if (arr.size > MOTION_BATCH_MAX) return null
                return Samples(arr.mapNotNull { (it as? JsonObject)?.let(::parseSample) })
            }
            return when (b.str("action")) {
                "config" -> Config(enabled = b.flag("enabled") ?: false, auto = b.flag("auto") ?: false)
                "start" -> Start((b["rate"] as? JsonPrimitive)?.let { it.longOrNull ?: it.doubleOrNull?.toLong() }?.coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong())?.toInt())
                "stop" -> Stop
                "state" -> State(running = b.flag("running") ?: false, error = b.str("error")?.takeIf { it.isNotEmpty() })
                "vehicle" -> b.flag("in")?.let { Vehicle(it) }
                else -> null
            }
        }

        private fun parseSample(o: JsonObject): MotionSample? {
            val t = (o["t"] as? JsonPrimitive)?.longOrNull ?: return null
            val x = o.num("x") ?: return null
            val y = o.num("y") ?: return null
            val z = o.num("z") ?: return null
            if (!validAccel(x) || !validAccel(y) || !validAccel(z)) return null
            return MotionSample(t, x, y, z, Mount.fromKey(o.str("mount")))
        }

        private fun JsonObject.flag(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
        private fun JsonObject.num(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull
    }
}

/**
 * The answer of the phone to a config from a computer: vehicle in true
 * when the computer has motion cues and automatic start on and the phone
 * is in a vehicle ([inside]), else null. A computer that connects during
 * a trip then learns about the trip. The computer starts only on a change
 * from false to true, so a repeat does no harm.
 */
fun vehicleReplyTo(config: MotionMessage.Config, inside: Boolean): MotionMessage.Vehicle? =
    if (config.enabled && config.auto && inside) MotionMessage.Vehicle(true) else null

/** True for a finite acceleration in the limit of the computer. */
fun validAccel(v: Double): Boolean = v.isFinite() && abs(v) <= MOTION_MAX_ACCEL

/** Rounds to 3 decimals, which is more than the sensor resolution, so that the packets stay small. */
private fun round3(v: Double): Double = (v * 1000).roundToLong() / 1000.0

/**
 * Removes gravity from the raw accelerometer values with a low-pass
 * filter. The phone uses it only when it has no linear acceleration
 * sensor. A higher [alpha] makes the gravity estimate slower. The first
 * sample sets the estimate, so that the first output is 0 and not 9.8.
 */
class GravityFilter(private val alpha: Double = 0.8) {
    private var gx = 0.0
    private var gy = 0.0
    private var gz = 0.0
    private var primed = false

    /** Takes 1 raw sample, and returns the acceleration without gravity. */
    fun update(x: Double, y: Double, z: Double): DoubleArray {
        if (!primed) {
            gx = x
            gy = y
            gz = z
            primed = true
        } else {
            gx = alpha * gx + (1 - alpha) * x
            gy = alpha * gy + (1 - alpha) * y
            gz = alpha * gz + (1 - alpha) * z
        }
        return doubleArrayOf(x - gx, y - gy, z - gz)
    }

    fun reset() {
        primed = false
    }
}

/**
 * Collects samples into batches of at most [max], at most 1 batch each
 * [intervalMs]. It keeps only the newest [max] samples. When the link is
 * busy at the time of a batch, the batch drops, so that the link never
 * holds old samples.
 */
class SampleBatcher(private val max: Int = MOTION_BATCH_MAX, private val intervalMs: Long = MOTION_BATCH_MS) {
    private val buffer = ArrayDeque<MotionSample>(max)
    private var lastSent = Long.MIN_VALUE

    /** The number of samples that wait. */
    val size: Int get() = buffer.size

    /** The number of samples that dropped, because the link was busy or the buffer was full. */
    var dropped = 0L
        private set

    fun add(s: MotionSample) {
        if (buffer.size == max) {
            buffer.removeFirst()
            dropped++
        }
        buffer.addLast(s)
    }

    /**
     * Returns the batch to send at [now], in milliseconds, or null. It
     * returns null while no sample waits and before [intervalMs] since the
     * last batch. When [busy] is true, it drops the waiting samples and
     * returns null.
     */
    fun take(now: Long, busy: Boolean): List<MotionSample>? {
        if (buffer.isEmpty()) return null
        if (lastSent != Long.MIN_VALUE && now - lastSent < intervalMs) return null
        if (busy) {
            dropped += buffer.size
            buffer.clear()
            return null
        }
        val batch = buffer.toList()
        buffer.clear()
        lastSent = now
        return batch
    }

    fun clear() {
        buffer.clear()
    }
}

/**
 * The vehicle state from the enter and exit events of the phone. An exit
 * counts only after it holds for [holdMs] without a new enter, so that a
 * stop at a light does not end the cues. Times are in milliseconds from 1
 * monotonic clock.
 */
class VehicleDebounce(private val holdMs: Long = 60_000L) {
    /** True while the phone is in a vehicle, as the computers know it. */
    var inside = false
        private set

    private var exitAt: Long? = null

    /** The time at which a pending exit counts, or null. */
    val pendingExit: Long? get() = exitAt

    /**
     * Takes an enter event. It returns true when the computers must get
     * vehicle in true. An enter during a pending exit only ends the exit.
     */
    fun enter(): Boolean {
        exitAt = null
        if (inside) return false
        inside = true
        return true
    }

    /**
     * Takes an exit event at [now]. It returns the time at which to call
     * [due], or null when there is nothing to do: the phone is not in a
     * vehicle, or an exit is pending already.
     */
    fun exit(now: Long): Long? {
        if (!inside || exitAt != null) return null
        val at = now + holdMs
        exitAt = at
        return at
    }

    /** Returns true once, when the pending exit holds at [now]. The computers then get vehicle in false. */
    fun due(now: Long): Boolean {
        val at = exitAt ?: return false
        if (now < at) return false
        exitAt = null
        inside = false
        return true
    }

    /** Forgets the state, for example when the phone stops the detection. */
    fun reset() {
        inside = false
        exitAt = null
    }
}
