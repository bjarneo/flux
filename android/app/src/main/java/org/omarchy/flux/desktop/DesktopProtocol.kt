package org.omarchy.flux.desktop

import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import org.omarchy.flux.webcam.AnnexB
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream

/**
 * The flux.desktop packets. The phone opens a TLS listener and sends
 * "start" with its port, the longest side of the stream, and optionally
 * a monitor. The computer connects and writes frames, see [FrameReader].
 * The computer answers "live" with the monitor and the size, "error", or
 * "stop". The touches go as flux.mousepad.request with a position.
 */
object DesktopPackets {
    /** The longest side of the stream that the phone asks for, in pixels. */
    const val MAX_SIZE = 1920

    fun start(port: Int, monitor: String? = null, maxSize: Int = MAX_SIZE, audio: Boolean = false): Packet {
        val fields = mutableListOf<Pair<String, Any?>>("state" to "start", "port" to port, "maxSize" to maxSize)
        if (!monitor.isNullOrEmpty()) fields += "monitor" to monitor
        if (audio) fields += "audio" to true
        return Packet(Types.FLUX_DESKTOP, bodyOf(*fields.toTypedArray()))
    }

    fun stop(): Packet = Packet(Types.FLUX_DESKTOP, bodyOf("state" to "stop"))
}

/** An answer from the computer. */
sealed interface DesktopReply {
    /** The computer streams [monitor] at [width] × [height]. [monitors] are all the monitors that it can stream. */
    data class Live(val monitor: String, val monitors: List<String>, val width: Int, val height: Int) : DesktopReply

    data class Failed(val message: String) : DesktopReply

    /** The user stopped the stream on the computer. */
    data object Stop : DesktopReply

    companion object {
        /** Parses a flux.desktop packet. It returns null for other packets and unknown states. */
        fun parse(p: Packet): DesktopReply? {
            if (p.type != Types.FLUX_DESKTOP) return null
            return when (p.string("state")) {
                "live" -> Live(
                    p.string("monitor") ?: "",
                    p.strings("monitors"),
                    p.int("width") ?: 0,
                    p.int("height") ?: 0,
                )
                "error" -> Failed(p.string("message")?.takeIf { it.isNotEmpty() } ?: "The computer could not stream its screen")
                "stop" -> Stop
                else -> null
            }
        }
    }
}

/**
 * 1 frame of the stream. The first [length] bytes of [data] are H.264 in
 * Annex-B form, or the video size for [FORMAT].
 */
class Frame(val flags: Int, val data: ByteArray, val length: Int = data.size) {
    val isConfig: Boolean get() = flags and CONFIG != 0
    val isKey: Boolean get() = flags and KEY != 0
    val isFormat: Boolean get() = flags and FORMAT != 0
    val isAudio: Boolean get() = flags == AUDIO

    /** The width and the height of a [FORMAT] frame. */
    fun size(): Pair<Int, Int>? {
        if (!isFormat || length < 4) return null
        fun u16(i: Int) = (data[i].toInt() and 0xff) shl 8 or (data[i + 1].toInt() and 0xff)
        return u16(0) to u16(2)
    }

    companion object {
        /** The SPS and the PPS. */
        const val CONFIG = 1

        /** A frame that a decoder can start at. */
        const val KEY = 2

        /** The video size: the width and the height as 2 big-endian 16-bit numbers. */
        const val FORMAT = 4
        const val AUDIO = 8
    }
}

/**
 * Reads the frames that the computer writes: the size of the data as a
 * big-endian 32-bit number, 1 byte of flags, and the data. The size comes
 * first, so a frame is complete as soon as its last byte arrives.
 */
class FrameReader(input: InputStream, private val maxFrame: Int = MAX_FRAME) {
    private val input = DataInputStream(BufferedInputStream(input, 64 * 1024))

    // All frames use 1 array, which grows to the largest frame.
    private var buffer = ByteArray(0)

    /**
     * Returns the next frame, or null at the end of the stream. The frame
     * uses the array of the reader, so it is valid only until the next call.
     */
    fun next(): Frame? {
        val size = try {
            input.readInt()
        } catch (e: EOFException) {
            return null
        }
        if (size < 0 || size > maxFrame) throw IOException("A frame of $size bytes is too large")
        val flags = input.readUnsignedByte()
        if (buffer.size < size) buffer = ByteArray(size)
        input.readFully(buffer, 0, size)
        return Frame(flags, buffer, size)
    }

    companion object {
        const val MAX_FRAME = 16 * 1024 * 1024
    }
}

/**
 * Returns the SPS and the PPS of a [Frame.CONFIG] frame in the first
 * [length] bytes of [data], each with its start code, as the decoder takes
 * them in csd-0 and csd-1. It returns null when one of them is missing.
 */
fun codecConfig(data: ByteArray, length: Int = data.size): Pair<ByteArray, ByteArray>? {
    val starts = AnnexB.nalStarts(data, length)
    var sps: ByteArray? = null
    var pps: ByteArray? = null
    for ((i, start) in starts.withIndex()) {
        if (start >= length) continue
        // The unit ends at the start code of the next unit, without the zero bytes before it.
        var end = if (i + 1 < starts.size) starts[i + 1] - 3 else length
        while (end > start && data[end - 1] == 0.toByte()) end--
        val unit = byteArrayOf(0, 0, 0, 1) + data.copyOfRange(start, end)
        when (data[start].toInt() and 0x1f) {
            AnnexB.NAL_SPS -> if (sps == null) sps = unit
            AnnexB.NAL_PPS -> if (pps == null) pps = unit
        }
    }
    return if (sps != null && pps != null) sps to pps else null
}
