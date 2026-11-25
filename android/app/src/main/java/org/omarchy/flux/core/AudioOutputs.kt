package org.omarchy.flux.core

import kotlinx.serialization.json.JsonObject
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import org.omarchy.flux.protocol.bool
import org.omarchy.flux.protocol.long
import org.omarchy.flux.protocol.str

/**
 * 1 audio output of a computer, such as its speakers or an HDMI monitor.
 * [name] is the name that the computer knows. [volume] is the volume of
 * the loudest channel in percent, and can be more than 100. [isDefault]
 * is true for the output that the apps of the computer play to.
 */
data class AudioOutput(
    val name: String,
    val description: String,
    val volume: Int,
    val muted: Boolean,
    val isDefault: Boolean,
)

/** The audio outputs of a computer, or the [error] that the computer sent. */
data class AudioOutputs(val list: List<AudioOutput> = emptyList(), val error: String? = null) {
    /** The default output, or null. */
    val current: AudioOutput? get() = list.firstOrNull { it.isDefault }
}

/**
 * The flux.audio packets. The phone asks with flux.audio.request, and the
 * computer answers each request with flux.audio and the outputs.
 */
object AudioOutputPackets {
    /** The most outputs that the phone shows. */
    const val MAX_OUTPUTS = 32

    /** The longest name or description that the phone keeps. */
    private const val MAX_TEXT = 256

    fun request(): Packet = Packet(Types.FLUX_AUDIO_REQUEST, bodyOf("request" to true))

    fun select(name: String): Packet = Packet(Types.FLUX_AUDIO_REQUEST, bodyOf("output" to name, "default" to true))

    fun volume(name: String, percent: Int): Packet = Packet(Types.FLUX_AUDIO_REQUEST, bodyOf("output" to name, "volume" to percent.coerceIn(0, 100)))

    fun mute(name: String, muted: Boolean): Packet = Packet(Types.FLUX_AUDIO_REQUEST, bodyOf("output" to name, "mute" to muted))

    /** Parses a flux.audio packet. It returns null for other packets. An output without a name does not count. */
    fun parse(p: Packet): AudioOutputs? {
        if (p.type != Types.FLUX_AUDIO) return null
        val list = p.array("outputs").orEmpty().mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            val name = o.str("name")?.take(MAX_TEXT)?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            AudioOutput(
                name = name,
                description = o.str("description")?.take(MAX_TEXT)?.takeIf { it.isNotBlank() } ?: name,
                volume = (o.long("volume") ?: 0L).coerceIn(0L, 1000L).toInt(),
                muted = o.bool("muted") == true,
                isDefault = o.bool("default") == true,
            )
        }.take(MAX_OUTPUTS)
        return AudioOutputs(list, p.string("error")?.takeIf { it.isNotBlank() })
    }
}

/** The audio outputs of the computers on the Media screen. */
object AudioOutputsSync {
    /** Takes flux.audio from the computer. The core lock is held. */
    fun onPacket(d: Device, p: Packet) {
        d.outputs = AudioOutputPackets.parse(p) ?: return
    }

    /** Asks the computer [id] for its outputs. A computer without the feature gets nothing. */
    fun request(core: FluxCore, id: String) {
        val d = core.device(id) ?: return
        if (Types.FLUX_AUDIO_REQUEST in d.identity.incoming) d.send(AudioOutputPackets.request())
    }

    /** Makes [name] the default output of the computer [id]. */
    fun select(core: FluxCore, id: String, name: String) =
        change(core, id, AudioOutputPackets.select(name)) { o -> o.copy(isDefault = o.name == name) }

    /** Sets the volume of the output [name], from 0 to 100. */
    fun setVolume(core: FluxCore, id: String, name: String, percent: Int) {
        val v = percent.coerceIn(0, 100)
        change(core, id, AudioOutputPackets.volume(name, v)) { o -> if (o.name == name) o.copy(volume = v) else o }
    }

    /** Mutes the output [name], or turns its sound on again. */
    fun setMute(core: FluxCore, id: String, name: String, muted: Boolean) =
        change(core, id, AudioOutputPackets.mute(name, muted)) { o -> if (o.name == name) o.copy(muted = muted) else o }

    /**
     * Sends [p] and shows the change at once. The answer of the computer
     * then replaces it, also when the change failed.
     */
    private fun change(core: FluxCore, id: String, p: Packet, apply: (AudioOutput) -> AudioOutput) {
        val d = core.device(id) ?: return
        if (!d.send(p)) return
        core.locked { d.outputs = d.outputs?.let { it.copy(list = it.list.map(apply)) } }
    }
}
