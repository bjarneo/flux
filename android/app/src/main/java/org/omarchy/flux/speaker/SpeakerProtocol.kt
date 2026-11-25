package org.omarchy.flux.speaker

import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf

/**
 * The flux.speaker packets. The phone opens a TLS listener and sends
 * "start" with its port and the mute choice. The computer connects and
 * writes the audio of its default output as frames of the remote desktop,
 * see [org.omarchy.flux.desktop.FrameReader]: 20 ms of stereo, 48 kHz,
 * signed 16-bit little-endian PCM in each frame. The computer answers
 * "live", "muted", "error", or "stop".
 */
object SpeakerPackets {
    const val RATE = 48_000
    const val CHANNELS = 2

    /** The bytes of 1 frame of 20 ms. */
    const val FRAME_BYTES = RATE / 50 * CHANNELS * 2

    fun start(port: Int, mute: Boolean): Packet = Packet(Types.FLUX_SPEAKER, bodyOf("state" to "start", "port" to port, "mute" to mute))

    fun stop(): Packet = Packet(Types.FLUX_SPEAKER, bodyOf("state" to "stop"))

    /** Asks the computer to mute its default output while the phone plays, or to turn its sound on again. */
    fun mute(on: Boolean): Packet = Packet(Types.FLUX_SPEAKER, bodyOf("state" to "mute", "mute" to on))
}

/** An answer from the computer. */
sealed interface SpeakerReply {
    /** The computer captures its audio and writes it to the stream. */
    data object Live : SpeakerReply

    /**
     * The computer muted its output [output], or turned its sound on again
     * when [output] is empty. [message] tells why the computer could not
     * mute its output, or is null.
     */
    data class Muted(val output: String, val message: String?) : SpeakerReply

    data class Failed(val message: String) : SpeakerReply

    /** The user stopped the stream on the computer. */
    data object Stop : SpeakerReply

    companion object {
        /** Parses a flux.speaker packet. It returns null for other packets and unknown states. */
        fun parse(p: Packet): SpeakerReply? {
            if (p.type != Types.FLUX_SPEAKER) return null
            return when (p.string("state")) {
                "live" -> Live
                "muted" -> Muted(p.string("output").orEmpty().take(MAX_TEXT), p.string("message")?.takeIf { it.isNotEmpty() }?.take(MAX_TEXT))
                "error" -> Failed(p.string("message")?.takeIf { it.isNotEmpty() }?.take(MAX_TEXT) ?: "The computer could not play its audio on this phone")
                "stop" -> Stop
                else -> null
            }
        }

        private const val MAX_TEXT = 256
    }
}
