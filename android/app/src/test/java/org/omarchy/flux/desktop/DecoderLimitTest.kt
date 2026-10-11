package org.omarchy.flux.desktop

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DecoderLimitTest {
    // A decoder of H.264 level 4.2 holds at most 8704 blocks of 16 × 16 in a frame.
    private val level42 = { w: Int, h: Int -> DecoderLimit.blocks(w, h) <= 8704 }

    @Test
    fun scalesAsFluxdScales() {
        // The same cases as TestStreamSize in internal/core/remotedesktop_test.go.
        assertEquals(1920 to 1200, DecoderLimit.scaled(2880, 1800, 1920))
        assertEquals(1920 to 1080, DecoderLimit.scaled(3840, 2160, 1920))
        assertEquals(1366 to 768, DecoderLimit.scaled(1366, 768, 1920))
        assertEquals(1920 to 802, DecoderLimit.scaled(3440, 1440, 1920))
    }

    @Test
    fun asksForASmallerStreamOnlyWhenTheDecoderCannotShowIt() {
        assertNull(DecoderLimit.smaller(1920, 1080, level42))
        assertNull("no size before the computer tells it", DecoderLimit.smaller(0, 0, level42))
        // 1920 × 1200 has 9000 blocks.
        val size = DecoderLimit.smaller(1920, 1200, level42)!!
        val (w, h) = DecoderLimit.scaled(1920, 1200, size)
        assertTrue(level42(w + 2, h + 2))
        // The next larger step does not fit, so the stream stays as large as it can.
        val (bw, bh) = DecoderLimit.scaled(1920, 1200, size + 16)
        assertTrue(!level42(bw + 2, bh + 2))
        assertEquals(1856, size)
    }

    @Test
    fun noSizeFitsADecoderThatShowsNothing() {
        assertNull(DecoderLimit.smaller(1920, 1200) { _, _ -> false })
    }

    @Test
    fun aStalledDecoderGetsTheFallbackSizes() {
        // First a frame of 1920 × 1080, then 1280 × 720, then nothing.
        val first = DecoderLimit.afterStall(1920, 1200)!!
        val (w, h) = DecoderLimit.scaled(1920, 1200, first)
        assertTrue(DecoderLimit.blocks(w + 2, h + 2) <= 8160)
        val second = DecoderLimit.afterStall(1920, 1080)!!
        val (w2, h2) = DecoderLimit.scaled(1920, 1080, second)
        assertTrue(DecoderLimit.blocks(w2 + 2, h2 + 2) <= 3600)
        assertNull(DecoderLimit.afterStall(1280, 720))
        assertNull(DecoderLimit.afterStall(640, 360))
    }
}
