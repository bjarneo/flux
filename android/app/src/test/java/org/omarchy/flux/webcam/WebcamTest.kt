package org.omarchy.flux.webcam

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.OUTGOING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.io.ByteArrayOutputStream

class WebcamTest {
    private val sps = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1f)
    private val pps = byteArrayOf(0, 0, 0, 1, 0x68, 0xce.toByte(), 0x3c, 0x80.toByte())
    private val idr = byteArrayOf(0, 0, 0, 1, 0x65, 0x11, 0x22)
    private val pFrame = byteArrayOf(0, 0, 0, 1, 0x41, 0x33, 0x44)

    @Test
    fun capabilityIsInBothLists() {
        assertTrue(Types.FLUX_WEBCAM in INCOMING)
        assertTrue(Types.FLUX_WEBCAM in OUTGOING)
    }

    @Test
    fun startBodyHasEveryField() {
        val p = WebcamPackets.start(1742, 1920, 1080)
        assertEquals(Types.FLUX_WEBCAM, p.type)
        assertEquals("start", p.string("state"))
        assertEquals(1742, p.int("port"))
        assertEquals(1920, p.int("width"))
        assertEquals(1080, p.int("height"))
        assertEquals(30, p.int("fps"))
        assertEquals("h264", p.string("codec"))
        val back = Packet.parse(p.serialize())!!
        assertEquals(1742, back.int("port"))
    }

    @Test
    fun stopBody() {
        assertEquals("stop", WebcamPackets.stop().string("state"))
    }

    @Test
    fun parsesReplies() {
        val live = WebcamReply.parse(Packet(Types.FLUX_WEBCAM, bodyOf("state" to "live", "device" to "/dev/video42", "label" to "Flux Camera")))
        assertEquals(WebcamReply.Live("/dev/video42", "Flux Camera"), live)
        val failed = WebcamReply.parse(Packet(Types.FLUX_WEBCAM, bodyOf("state" to "error", "message" to "v4l2loopback is missing")))
        assertEquals(WebcamReply.Failed("v4l2loopback is missing"), failed)
        assertEquals(WebcamReply.Stop, WebcamReply.parse(Packet(Types.FLUX_WEBCAM, bodyOf("state" to "stop"))))
        assertNull(WebcamReply.parse(Packet(Types.FLUX_WEBCAM, bodyOf("state" to "start"))))
        assertNull(WebcamReply.parse(Packet(Types.PING)))
    }

    @Test
    fun liveWithoutLabelGetsTheDefaultName() {
        val live = WebcamReply.parse(Packet(Types.FLUX_WEBCAM, bodyOf("state" to "live", "device" to "/dev/video42")))
        assertEquals(WebcamReply.Live("/dev/video42", "Flux Camera"), live)
    }

    private fun mask(vararg types: Int) = types.fold(0) { m, t -> m or (1 shl t) }

    @Test
    fun findsNalTypes() {
        assertEquals(mask(7, 8, 5), AnnexB.leadingTypes(sps + pps + idr))
        // A 3-byte start code works too.
        assertEquals(mask(1), AnnexB.leadingTypes(byteArrayOf(0, 0, 1, 0x41, 0x01)))
    }

    @Test
    fun nalScanStopsAtTheFirstSlice() {
        assertEquals(mask(1), AnnexB.leadingTypes(pFrame + sps + idr))
        // Only the first bytes count.
        assertEquals(mask(7), AnnexB.leadingTypes(sps + pps, sps.size))
    }

    @Test
    fun addsMissingStartCode() {
        assertArrayEquals(idr, AnnexB.withStartCode(byteArrayOf(0x65, 0x11, 0x22)))
        assertArrayEquals(idr, AnnexB.withStartCode(idr))
    }

    /** Returns the bytes that the framer writes for 1 frame, or null when it writes none. */
    private fun AnnexBFramer.onFrame(data: ByteArray, keyFrame: Boolean): ByteArray? {
        val out = ByteArrayOutputStream()
        write(out, data, data.size, keyFrame)
        return out.toByteArray().takeIf { it.isNotEmpty() }
    }

    @Test
    fun framerPutsConfigBeforeEachIdr() {
        val f = AnnexBFramer()
        f.onConfig(sps + pps)
        assertArrayEquals(sps + pps + idr, f.onFrame(idr, keyFrame = true))
        assertArrayEquals(pFrame, f.onFrame(pFrame, keyFrame = false))
        assertArrayEquals(sps + pps + idr, f.onFrame(idr, keyFrame = true))
    }

    @Test
    fun framerDropsFramesBeforeTheFirstIdr() {
        val f = AnnexBFramer()
        f.onConfig(sps + pps)
        assertNull(f.onFrame(pFrame, keyFrame = false))
        assertArrayEquals(sps + pps + idr, f.onFrame(idr, keyFrame = true))
    }

    @Test
    fun framerDoesNotRepeatConfigThatTheFrameHas() {
        val f = AnnexBFramer()
        f.onConfig(sps + pps)
        assertArrayEquals(sps + pps + idr, f.onFrame(sps + pps + idr, keyFrame = true))
    }

    @Test
    fun framerFindsIdrWithoutTheKeyFlag() {
        val f = AnnexBFramer()
        f.onConfig(sps + pps)
        assertArrayEquals(sps + pps + idr, f.onFrame(idr, keyFrame = false))
    }

    @Test
    fun framerWritesOnlyTheFrameLength() {
        val f = AnnexBFramer()
        f.onConfig(sps + pps)
        // The encoder uses 1 array for all frames. Old bytes follow a short frame.
        val buffer = idr + ByteArray(16) { 0x7f }
        val out = ByteArrayOutputStream()
        f.write(out, buffer, idr.size, keyFrame = true)
        pFrame.copyInto(buffer)
        f.write(out, buffer, pFrame.size, keyFrame = false)
        assertArrayEquals(sps + pps + idr + pFrame, out.toByteArray())
    }

    @Test
    fun framerAddsMissingStartCode() {
        val f = AnnexBFramer()
        f.onConfig(sps + pps)
        val out = ByteArrayOutputStream()
        f.write(out, byteArrayOf(0x65, 0x11, 0x22, 0x7f), 3, keyFrame = true)
        assertArrayEquals(sps + pps + idr, out.toByteArray())
    }
}
