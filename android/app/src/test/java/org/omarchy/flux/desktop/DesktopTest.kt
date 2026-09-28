package org.omarchy.flux.desktop

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.OUTGOING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.IOException

class DesktopTest {
    @Test
    fun capabilityIsInBothLists() {
        assertTrue(Types.FLUX_DESKTOP in INCOMING)
        assertTrue(Types.FLUX_DESKTOP in OUTGOING)
    }

    @Test
    fun startBody() {
        val p = DesktopPackets.start(1742)
        assertEquals(Types.FLUX_DESKTOP, p.type)
        assertEquals("start", p.string("state"))
        assertEquals(1742, p.int("port"))
        assertEquals(DesktopPackets.MAX_SIZE, p.int("maxSize"))
        assertFalse(p.has("monitor"))
        assertEquals("DP-1", DesktopPackets.start(1742, "DP-1").string("monitor"))
        assertEquals("stop", DesktopPackets.stop().string("state"))
    }

    @Test
    fun parsesReplies() {
        val live = Packet(
            Types.FLUX_DESKTOP,
            bodyOf("state" to "live", "monitor" to "eDP-1", "monitors" to listOf("eDP-1", "DP-1"), "width" to 1920, "height" to 1200),
        )
        assertEquals(DesktopReply.Live("eDP-1", listOf("eDP-1", "DP-1"), 1920, 1200), DesktopReply.parse(live))
        assertEquals(DesktopReply.Failed("off"), DesktopReply.parse(Packet(Types.FLUX_DESKTOP, bodyOf("state" to "error", "message" to "off"))))
        assertEquals(DesktopReply.Stop, DesktopReply.parse(Packet(Types.FLUX_DESKTOP, bodyOf("state" to "stop"))))
        assertNull(DesktopReply.parse(Packet(Types.FLUX_DESKTOP, bodyOf("state" to "start"))))
        assertNull(DesktopReply.parse(Packet(Types.FLUX_SCREEN, bodyOf("state" to "stop"))))
    }

    private fun frames(vararg frames: Pair<Int, ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        val data = DataOutputStream(out)
        for ((flags, bytes) in frames) {
            data.writeInt(bytes.size)
            data.writeByte(flags)
            data.write(bytes)
        }
        return out.toByteArray()
    }

    @Test
    fun readsFrames() {
        val sps = byteArrayOf(0, 0, 0, 1, 0x67, 0x64, 0x00, 0x32)
        val pps = byteArrayOf(0, 0, 0, 1, 0x68, 0xee.toByte(), 0x3c)
        val stream = frames(
            Frame.FORMAT to byteArrayOf(0x07, 0x80.toByte(), 0x04, 0xb0.toByte()),
            Frame.CONFIG to sps + pps,
            Frame.KEY to byteArrayOf(0, 0, 0, 1, 0x65, 1, 2),
            0 to byteArrayOf(0, 0, 0, 1, 0x41, 3),
        )
        val r = FrameReader(ByteArrayInputStream(stream))
        val format = r.next()!!
        assertTrue(format.isFormat)
        assertEquals(1920 to 1200, format.size())
        val config = r.next()!!
        assertTrue(config.isConfig)
        val (csd0, csd1) = codecConfig(config.data)!!
        assertArrayEquals(sps, csd0)
        assertArrayEquals(pps, csd1)
        val key = r.next()!!
        assertTrue(key.isKey && !key.isConfig)
        val inter = r.next()!!
        assertFalse(inter.isKey)
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x41, 3), inter.data)
        assertNull(r.next())
    }

    @Test(expected = IOException::class)
    fun refusesAHugeFrame() {
        FrameReader(ByteArrayInputStream(frames(0 to ByteArray(64))), maxFrame = 32).next()
    }

    @Test
    fun configNeedsBothUnits() {
        assertNull(codecConfig(byteArrayOf(0, 0, 0, 1, 0x67, 1, 2)))
        assertNull(codecConfig(ByteArray(0)))
    }

    @Test
    fun fitsTheVideo() {
        // A 16:10 video in a wide view: bars on the left and the right.
        val v = DesktopViewport(2000f, 1000f, 1920, 1200)
        assertEquals(1600f, v.fitWidth, 0.01f)
        assertEquals(1000f, v.fitHeight, 0.01f)
        assertEquals(200f, v.fitLeft, 0.01f)
        assertEquals(0f, v.fitTop, 0.01f)
        assertEquals(0f to 0f, v.toVideo(200f, 0f))
        assertEquals(0.5f to 0.5f, v.toVideo(1000f, 500f))
        assertNull(v.toVideo(100f, 500f))
        assertEquals(0f to 0.5f, v.toVideo(100f, 500f, clamp = true))
    }

    @Test
    fun zoomKeepsThePointUnderTheFingers() {
        val v = DesktopViewport(1000f, 625f, 1920, 1200)
        val before = v.toVideo(300f, 200f)!!
        val z = v.zoom(2f, 300f, 200f)
        assertEquals(2f, z.scale, 0.001f)
        val after = z.toVideo(300f, 200f)!!
        assertEquals(before.first, after.first, 0.001f)
        assertEquals(before.second, after.second, 0.001f)
        // 1 video pixel shows larger at scale 2.
        assertEquals(v.pixel * 2, z.pixel, 0.001f)
    }

    @Test
    fun zoomAndPanStayInLimits() {
        val v = DesktopViewport(1000f, 625f, 1920, 1200)
        assertEquals(1f, v.zoom(0.2f, 500f, 300f).scale, 0.001f)
        assertEquals(DesktopViewport.MAX_SCALE, v.zoom(50f, 500f, 300f).scale, 0.001f)
        // The zoomed video covers the view: a large pan stops at the edge.
        val z = v.zoom(2f, 0f, 0f).pan(5000f, 5000f)
        assertEquals(0f to 0f, z.toVideo(0f, 0f))
        val far = z.pan(-50_000f, -50_000f)
        val corner = far.toVideo(999.9f, 624.9f)!!
        assertEquals(1f, corner.first, 0.001f)
        assertEquals(1f, corner.second, 0.001f)
        // At scale 1, a pan does nothing.
        assertEquals(v, v.pan(40f, 40f))
    }

    @Test
    fun resizeStartsAtScaleOne() {
        val v = DesktopViewport(1000f, 625f, 1920, 1200).zoom(3f, 10f, 10f)
        assertTrue(v.resized(1000f, 625f, 1920, 1200) === v)
        assertEquals(1f, v.resized(625f, 1000f, 1920, 1200).scale, 0.001f)
    }
}
