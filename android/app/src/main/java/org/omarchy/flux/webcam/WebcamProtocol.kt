package org.omarchy.flux.webcam

import kotlinx.serialization.json.JsonObject
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf

/**
 * The flux.webcam extension. The phone opens a TLS listener, sends "start"
 * with its port, and writes a raw H.264 Annex-B stream to the computer that
 * connects. The computer answers "live", "error", or "stop". Both sides send
 * "config" to change the settings.
 */
object WebcamPackets {
    const val FPS = 30

    fun start(port: Int, width: Int, height: Int): Packet = Packet(
        Types.FLUX_WEBCAM,
        bodyOf(
            "state" to "start", "port" to port,
            "width" to width, "height" to height,
            "fps" to FPS, "codec" to "h264",
        ),
    )

    fun stop(): Packet = Packet(Types.FLUX_WEBCAM, bodyOf("state" to "stop"))

    /** The full settings and what the camera supports. The phone sends it after "start" and after each change. */
    fun config(config: WebcamConfig, caps: WebcamCaps): Packet = Packet(
        Types.FLUX_WEBCAM,
        bodyOf("state" to "config", "config" to config.toJson(), "caps" to caps.toJson()),
    )
}

/** An answer from the computer. */
sealed interface WebcamReply {
    /** Frames reach the virtual camera [device], named [label]. */
    data class Live(val device: String, val label: String) : WebcamReply

    data class Failed(val message: String) : WebcamReply

    /** The user stopped the camera on the computer. */
    data object Stop : WebcamReply

    /**
     * The computer changes settings. [reset] sets the neutral image values
     * first, and [partial] then sets the fields that it names.
     */
    data class Config(val partial: JsonObject?, val reset: Boolean) : WebcamReply

    companion object {
        /** Parses a flux.webcam packet. It returns null for other packets and unknown states. */
        fun parse(p: Packet): WebcamReply? {
            if (p.type != Types.FLUX_WEBCAM) return null
            return when (p.string("state")) {
                "live" -> Live(p.string("device") ?: "", p.string("label")?.takeIf { it.isNotEmpty() } ?: "Flux Camera")
                "error" -> Failed(p.string("message")?.takeIf { it.isNotEmpty() } ?: "The computer could not start the camera")
                "stop" -> Stop
                "config" -> Config(p.obj("config"), p.bool("reset") == true).takeIf { it.partial != null || it.reset }
                else -> null
            }
        }
    }
}
