package org.omarchy.flux.desktop

import android.media.MediaCodecList
import android.media.MediaFormat

/**
 * The largest stream that the H.264 decoder of the phone can show. A
 * decoder of H.264 level 4.2 shows 1920 × 1080, but not 1920 × 1200. The
 * computer keeps the aspect of its monitor, so the phone gets the size of
 * the stream in "live". When the decoder cannot show that size, the phone
 * asks for a smaller stream.
 */
internal object DecoderLimit {
    /** The smallest longest side that fluxd streams. */
    const val MIN_SIZE = 640

    /** The step between 2 sizes that the phone tries, in pixels. */
    private const val STEP = 16

    /**
     * The frame sizes in 16 × 16 blocks to try after a decoder showed no
     * frame: 1920 × 1080 and 1280 × 720. H.264 level 4 and level 3.1 allow
     * these sizes.
     */
    private val FALLBACK_BLOCKS = intArrayOf(8160, 3600)

    /** The size of the stream [w] × [h] scaled to the longest side [limit], as fluxd scales it. */
    fun scaled(w: Int, h: Int, limit: Int): Pair<Int, Int> {
        val scale = minOf(1.0, limit.toDouble() / w, limit.toDouble() / h)
        fun even(v: Int) = maxOf(2, (v * scale).toInt() / 2 * 2)
        return even(w) to even(h)
    }

    /** The number of 16 × 16 blocks in a frame of [w] × [h]. */
    fun blocks(w: Int, h: Int): Int = ((w + 15) / 16) * ((h + 15) / 16)

    /**
     * The largest longest side below the stream [w] × [h] for which [fits]
     * accepts the scaled stream, or null when no size from [MIN_SIZE] fits.
     * fluxd scales the monitor, not the stream, so its rounding can differ.
     * The check therefore adds 2 pixels in each direction.
     */
    fun largest(w: Int, h: Int, fits: (Int, Int) -> Boolean): Int? {
        var limit = maxOf(w, h) - STEP
        while (limit >= MIN_SIZE) {
            val (sw, sh) = scaled(w, h, limit)
            if (fits(sw + 2, sh + 2)) return limit
            limit -= STEP
        }
        return null
    }

    /**
     * The longest side to ask for when the decoder of the phone cannot show
     * the stream [w] × [h], or null when it can show it. [supports] is the
     * check of the decoder, see [avc].
     */
    fun smaller(w: Int, h: Int, supports: (Int, Int) -> Boolean): Int? =
        if (w <= 0 || h <= 0 || supports(w, h)) null else largest(w, h, supports)

    /**
     * The longest side to ask for after a decoder showed no frame of the
     * stream [w] × [h], or null when no smaller fallback size is left.
     */
    fun afterStall(w: Int, h: Int): Int? {
        val max = FALLBACK_BLOCKS.firstOrNull { it < blocks(w, h) } ?: return null
        return largest(w, h) { a, b -> blocks(a, b) <= max }
    }

    /**
     * The size check of the decoder that MediaCodec.createDecoderByType
     * picks for H.264: the first decoder in the list. Null when the phone
     * gives no capabilities. Some decoders give a smaller height than width
     * and still show a portrait monitor, so the check accepts both
     * orientations. The block count of a level is the same for both.
     */
    val avc: ((Int, Int) -> Boolean)? by lazy {
        runCatching {
            val type = MediaFormat.MIMETYPE_VIDEO_AVC
            val info = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .firstOrNull { !it.isEncoder && it.supportedTypes.any { t -> t.equals(type, ignoreCase = true) } }
            val caps = info?.getCapabilitiesForType(type)?.videoCapabilities
            caps?.let { c -> { w: Int, h: Int -> c.isSizeSupported(w, h) || c.isSizeSupported(h, w) } }
        }.getOrNull()
    }
}
