package org.omarchy.flux.webcam

import java.io.OutputStream

/** Helpers for H.264 in Annex-B form: NAL units that start with 00 00 01 or 00 00 00 01. */
object AnnexB {
    const val NAL_IDR = 5
    const val NAL_SPS = 7
    const val NAL_PPS = 8

    private val START = byteArrayOf(0, 0, 0, 1)

    /** Returns the offsets of the first byte after each start code in the first [length] bytes of [b]. */
    fun nalStarts(b: ByteArray, length: Int = b.size): List<Int> {
        val out = mutableListOf<Int>()
        var i = 0
        while (i + 2 < length) {
            if (b[i] == 0.toByte() && b[i + 1] == 0.toByte() && b[i + 2] == 1.toByte()) {
                out += i + 3
                i += 3
            } else {
                i++
            }
        }
        return out
    }

    /**
     * Returns the NAL unit types in the first [length] bytes of [b] as a
     * mask, with bit n set for type n. The scan stops at the first slice,
     * types 1 to 5. The SPS and the PPS of a frame come before its first
     * slice, and all slices of a picture have the same type. So the scan
     * does not read the slice data.
     */
    fun leadingTypes(b: ByteArray, length: Int = b.size): Int {
        var mask = 0
        var i = 0
        while (i + 2 < length) {
            if (b[i] == 0.toByte() && b[i + 1] == 0.toByte() && b[i + 2] == 1.toByte()) {
                i += 3
                if (i >= length) break
                val type = b[i].toInt() and 0x1F
                mask = mask or (1 shl type)
                if (type in 1..NAL_IDR) break
            } else {
                i++
            }
        }
        return mask
    }

    fun hasStartCode(b: ByteArray, length: Int = b.size): Boolean =
        (length >= 3 && b[0] == 0.toByte() && b[1] == 0.toByte() && b[2] == 1.toByte()) ||
            (length >= 4 && b[0] == 0.toByte() && b[1] == 0.toByte() && b[2] == 0.toByte() && b[3] == 1.toByte())

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

    /**
     * Stores codec config. It writes no bytes, because the config goes out
     * with the next IDR frame. The framer keeps [data], so the caller must
     * not change it after the call.
     */
    fun onConfig(data: ByteArray) {
        config = AnnexB.withStartCode(data)
    }

    /**
     * Writes 1 encoded frame, the first [length] bytes of [data], to [out].
     * It writes nothing for a frame that a decoder cannot use yet: a frame
     * before the first IDR frame. The framer keeps no reference to [data],
     * so the caller can use the array again for the next frame.
     */
    fun write(out: OutputStream, data: ByteArray, length: Int, keyFrame: Boolean) {
        if (!AnnexB.hasStartCode(data, length)) {
            val frame = AnnexB.withStartCode(data.copyOf(length))
            return write(out, frame, frame.size, keyFrame)
        }
        val types = AnnexB.leadingTypes(data, length)
        val isIdr = keyFrame || types.has(AnnexB.NAL_IDR)
        if (!isIdr && !started) return
        if (isIdr) {
            started = true
            val c = config
            if (c != null && !(types.has(AnnexB.NAL_SPS) && types.has(AnnexB.NAL_PPS))) out.write(c)
        }
        out.write(data, 0, length)
    }

    private fun Int.has(type: Int): Boolean = this and (1 shl type) != 0
}
