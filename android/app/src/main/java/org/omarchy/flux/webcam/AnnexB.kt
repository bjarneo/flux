package org.omarchy.flux.webcam

/** Helpers for H.264 in Annex-B form: NAL units that start with 00 00 01 or 00 00 00 01. */
object AnnexB {
    const val NAL_IDR = 5
    const val NAL_SPS = 7
    const val NAL_PPS = 8

    private val START = byteArrayOf(0, 0, 0, 1)

    /** Returns the offsets of the first byte after each start code in [b]. */
    fun nalStarts(b: ByteArray): List<Int> {
        val out = mutableListOf<Int>()
        var i = 0
        while (i + 2 < b.size) {
            if (b[i] == 0.toByte() && b[i + 1] == 0.toByte() && b[i + 2] == 1.toByte()) {
                out += i + 3
                i += 3
            } else {
                i++
            }
        }
        return out
    }

    /** Returns the NAL unit types in [b], in order. */
    fun nalTypes(b: ByteArray): List<Int> = nalStarts(b).filter { it < b.size }.map { b[it].toInt() and 0x1F }

    fun hasStartCode(b: ByteArray): Boolean =
        (b.size >= 3 && b[0] == 0.toByte() && b[1] == 0.toByte() && b[2] == 1.toByte()) ||
            (b.size >= 4 && b[0] == 0.toByte() && b[1] == 0.toByte() && b[2] == 0.toByte() && b[3] == 1.toByte())

    /** Returns [b] with a 4-byte start code in front, when it has none. */
    fun withStartCode(b: ByteArray): ByteArray = if (hasStartCode(b)) b else START + b
}

/**
 * Turns encoder output into a stream that a decoder can join at any IDR
 * frame. The encoder sends SPS and PPS once, as codec config. The framer
 * keeps them and writes them in front of each IDR frame that lacks them.
 */
class AnnexBFramer {
    private var config: ByteArray? = null
    private var started = false

    /** True after the codec config arrived. */
    val hasConfig: Boolean get() = config != null

    /** Stores codec config. It returns no bytes, because the config goes out with the next IDR frame. */
    fun onConfig(data: ByteArray) {
        config = AnnexB.withStartCode(data)
    }

    /**
     * Returns the bytes to write for 1 encoded frame. It returns null for a
     * frame that a decoder cannot use yet: a frame before the first IDR frame.
     */
    fun onFrame(data: ByteArray, keyFrame: Boolean): ByteArray? {
        val frame = AnnexB.withStartCode(data)
        val types = AnnexB.nalTypes(frame)
        val isIdr = keyFrame || AnnexB.NAL_IDR in types
        if (!isIdr && !started) return null
        if (isIdr) started = true
        if (!isIdr) return frame
        if (AnnexB.NAL_SPS in types && AnnexB.NAL_PPS in types) return frame
        val c = config ?: return frame
        return c + frame
    }
}
