package org.omarchy.flux.screen

import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import kotlin.math.max
import kotlin.math.min

/**
 * The flux.screen extension. The phone opens a TLS listener, sends "start"
 * with its port and the frame size, and writes a raw H.264 Annex-B stream
 * of its screen to the computer that connects. The computer answers
 * "live", "error", or "stop". The computer only shows the screen.
 */
object ScreenPackets {
    fun start(port: Int, width: Int, height: Int): Packet = Packet(
        Types.FLUX_SCREEN,
        bodyOf("state" to "start", "port" to port, "width" to width, "height" to height, "codec" to "h264"),
    )

    fun stop(): Packet = Packet(Types.FLUX_SCREEN, bodyOf("state" to "stop"))
}

/** An answer from the computer. */
sealed interface ScreenReply {
    /** The computer shows the stream in [player]. */
    data class Live(val player: String) : ScreenReply

    data class Failed(val message: String) : ScreenReply

    /** The user closed the window or stopped the mirror on the computer. */
    data object Stop : ScreenReply

    companion object {
        /** Parses a flux.screen packet. It returns null for other packets and unknown states. */
        fun parse(p: Packet): ScreenReply? {
            if (p.type != Types.FLUX_SCREEN) return null
            return when (p.string("state")) {
                "live" -> Live(p.string("player") ?: "")
                "error" -> Failed(p.string("message")?.takeIf { it.isNotEmpty() } ?: "The computer could not show the screen")
                "stop" -> Stop
                else -> null
            }
        }
    }
}

/** The frame size of the mirror. */
object MirrorSize {
    /** The longest side of the stream, in pixels. */
    const val MAX_LONG = 1080

    /**
     * Returns the encoder size for a screen of [width] × [height]: the same
     * shape, at most [maxLong] pixels on the long side, and both sides a
     * multiple of [align], as hardware encoders want.
     */
    fun fit(width: Int, height: Int, maxLong: Int = MAX_LONG, align: Int = 16): Pair<Int, Int> {
        require(width > 0 && height > 0) { "the screen size must be positive" }
        val scale = min(1.0, maxLong.toDouble() / max(width, height))
        fun down(v: Int) = max(align, (v * scale).toInt() / align * align)
        return down(width) to down(height)
    }

    /** Returns the bitrate for a frame size. Screen text needs more bits than a camera image. */
    fun bitrate(width: Int, height: Int): Int = max(2_000_000, (width.toLong() * height * 8).toInt())
}
