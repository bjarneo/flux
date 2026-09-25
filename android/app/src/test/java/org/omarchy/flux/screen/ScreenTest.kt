package org.omarchy.flux.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.OUTGOING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf

class ScreenTest {
    @Test
    fun capabilityIsInBothLists() {
        assertTrue(Types.FLUX_SCREEN in INCOMING)
        assertTrue(Types.FLUX_SCREEN in OUTGOING)
    }

    @Test
    fun startBodyHasTheSize() {
        val p = ScreenPackets.start(1750, 496, 1072)
        assertEquals(Types.FLUX_SCREEN, p.type)
        assertEquals("start", p.string("state"))
        assertEquals(1750, p.int("port"))
        assertEquals(496, p.int("width"))
        assertEquals(1072, p.int("height"))
        assertEquals("h264", p.string("codec"))
    }

    @Test
    fun parsesReplies() {
        assertEquals(ScreenReply.Live("mpv"), ScreenReply.parse(Packet(Types.FLUX_SCREEN, bodyOf("state" to "live", "player" to "mpv"))))
        assertEquals(ScreenReply.Failed("no mpv"), ScreenReply.parse(Packet(Types.FLUX_SCREEN, bodyOf("state" to "error", "message" to "no mpv"))))
        assertEquals(ScreenReply.Stop, ScreenReply.parse(Packet(Types.FLUX_SCREEN, bodyOf("state" to "stop"))))
        assertNull(ScreenReply.parse(Packet(Types.FLUX_SCREEN, bodyOf("state" to "start"))))
        assertNull(ScreenReply.parse(Packet(Types.FLUX_MIC, bodyOf("state" to "stop"))))
    }

    @Test
    fun fitKeepsTheShapeUnder1080() {
        // A portrait phone: the long side is at most 1080 px, both sides a multiple of 16.
        val (w, h) = MirrorSize.fit(1080, 2340)
        assertTrue(h <= 1080)
        assertEquals(0, w % 16)
        assertEquals(0, h % 16)
        assertEquals(496 to 1072, w to h)
        // The same screen in landscape swaps the sides.
        assertEquals(1072 to 496, MirrorSize.fit(2340, 1080))
        // 720 × 1280 scales by 1080 / 1280, then aligns down to 16 px.
        assertEquals(592 to 1072, MirrorSize.fit(720, 1280))
        // A screen under 1080 px keeps its size.
        assertEquals(480 to 800, MirrorSize.fit(480, 800))
    }

    @Test
    fun bitrateHasAFloor() {
        assertEquals(2_000_000, MirrorSize.bitrate(160, 160))
        assertEquals(496 * 1072 * 8, MirrorSize.bitrate(496, 1072))
    }
}
