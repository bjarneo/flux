package org.omarchy.flux.webcam

import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf

/**
 * The flux.webcam extension. The phone opens a TLS listener, sends "start"
 * with its port, and writes a raw H.264 Annex-B stream to the computer that
 * connects. The computer answers "live", "error", or "stop".
 */
object WebcamPackets {
    const val FPS = 30

    fun start(port: Int, resolution: Resolution): Packet = Packet(
        Types.FLUX_WEBCAM,
        bodyOf(
            "state" to "start", "port" to port,
            "width" to resolution.width, "height" to resolution.height,
            "fps" to FPS, "codec" to "h264",
        ),
    )

    fun stop(): Packet = Packet(Types.FLUX_WEBCAM, bodyOf("state" to "stop"))
}

/** The frame sizes that the phone offers. Both are 16:9. */
enum class Resolution(val width: Int, val height: Int, val bitrate: Int, val label: String) {
    HD(1280, 720, 4_000_000, "720p"),
    FULL_HD(1920, 1080, 8_000_000, "1080p"),
}

/** An answer from the computer. */
sealed interface WebcamReply {
    /** Frames reach the virtual camera [device], named [label]. */
    data class Live(val device: String, val label: String) : WebcamReply

    data class Failed(val message: String) : WebcamReply

    /** The user stopped the camera on the computer. */
    data object Stop : WebcamReply

    companion object {
        /** Parses a flux.webcam packet. It returns null for other packets and unknown states. */
        fun parse(p: Packet): WebcamReply? {
            if (p.type != Types.FLUX_WEBCAM) return null
            return when (p.string("state")) {
                "live" -> Live(p.string("device") ?: "", p.string("label")?.takeIf { it.isNotEmpty() } ?: "Flux Camera")
                "error" -> Failed(p.string("message")?.takeIf { it.isNotEmpty() } ?: "The computer could not start the camera")
                "stop" -> Stop
                else -> null
            }
        }
    }
}
