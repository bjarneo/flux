package org.omarchy.flux.mic

import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import kotlin.math.abs
import kotlin.math.max

/**
 * The flux.mic extension. The phone opens a TLS listener, sends "start"
 * with its port and the audio format, and writes raw PCM to the computer
 * that connects. The computer answers "live", "error", or "stop".
 */
object MicPackets {
    const val RATE = 48_000
    const val CHANNELS = 1
    const val FORMAT = "s16le"

    fun start(port: Int): Packet = Packet(
        Types.FLUX_MIC,
        bodyOf("state" to "start", "port" to port, "rate" to RATE, "channels" to CHANNELS, "format" to FORMAT),
    )

    fun stop(): Packet = Packet(Types.FLUX_MIC, bodyOf("state" to "stop"))
}

/** An answer from the computer. */
sealed interface MicReply {
    /** The audio reaches the virtual source [source]. */
    data class Live(val source: String) : MicReply

    data class Failed(val message: String) : MicReply

    /** The user stopped the microphone on the computer. */
    data object Stop : MicReply

    companion object {
        /** Parses a flux.mic packet. It returns null for other packets and unknown states. */
        fun parse(p: Packet): MicReply? {
            if (p.type != Types.FLUX_MIC) return null
            return when (p.string("state")) {
                "live" -> Live(p.string("source")?.takeIf { it.isNotEmpty() } ?: "Flux Microphone")
                "error" -> Failed(p.string("message")?.takeIf { it.isNotEmpty() } ?: "The computer could not start the microphone")
                "stop" -> Stop
                else -> null
            }
        }
    }
}

/** Helpers for 16-bit PCM. */
object Pcm {
    /** Writes the first [n] samples to [out] in little-endian order, 2 bytes each. */
    fun toLittleEndian(samples: ShortArray, n: Int, out: ByteArray) {
        for (i in 0 until n) {
            val v = samples[i].toInt()
            out[2 * i] = (v and 0xff).toByte()
            out[2 * i + 1] = ((v shr 8) and 0xff).toByte()
        }
    }

    /** Returns the peak of the first [n] samples, from 0 for silence to 1 for full scale. */
    fun peak(samples: ShortArray, n: Int): Float {
        var m = 0
        for (i in 0 until n) m = max(m, abs(samples[i].toInt()))
        return (m / 32768f).coerceIn(0f, 1f)
    }
}
