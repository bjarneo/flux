package org.omarchy.flux.mic

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

class MicTest {
    @Test
    fun capabilityIsInBothLists() {
        assertTrue(Types.FLUX_MIC in INCOMING)
        assertTrue(Types.FLUX_MIC in OUTGOING)
    }

    @Test
    fun startBodyHasTheFormat() {
        val p = MicPackets.start(1745)
        assertEquals(Types.FLUX_MIC, p.type)
        assertEquals("start", p.string("state"))
        assertEquals(1745, p.int("port"))
        assertEquals(48000, p.int("rate"))
        assertEquals(1, p.int("channels"))
        assertEquals("s16le", p.string("format"))
        assertEquals(1745, Packet.parse(p.serialize())!!.int("port"))
    }

    @Test
    fun parsesReplies() {
        assertEquals(MicReply.Live("Flux Microphone"), MicReply.parse(Packet(Types.FLUX_MIC, bodyOf("state" to "live", "source" to "Flux Microphone"))))
        assertEquals(MicReply.Live("Flux Microphone"), MicReply.parse(Packet(Types.FLUX_MIC, bodyOf("state" to "live"))))
        assertEquals(MicReply.Failed("no pw-cat"), MicReply.parse(Packet(Types.FLUX_MIC, bodyOf("state" to "error", "message" to "no pw-cat"))))
        assertEquals(MicReply.Stop, MicReply.parse(Packet(Types.FLUX_MIC, bodyOf("state" to "stop"))))
        assertNull(MicReply.parse(Packet(Types.FLUX_MIC, bodyOf("state" to "start"))))
        assertNull(MicReply.parse(Packet(Types.FLUX_WEBCAM, bodyOf("state" to "live"))))
    }

    @Test
    fun writesLittleEndianSamples() {
        val samples = shortArrayOf(0x0102, -1, Short.MIN_VALUE, Short.MAX_VALUE)
        val out = ByteArray(8)
        Pcm.toLittleEndian(samples, 4, out)
        assertArrayEquals(
            byteArrayOf(0x02, 0x01, 0xff.toByte(), 0xff.toByte(), 0x00, 0x80.toByte(), 0xff.toByte(), 0x7f),
            out,
        )
    }

    @Test
    fun peakGoesFromSilenceToFullScale() {
        assertEquals(0f, Pcm.peak(ShortArray(10), 10), 0f)
        assertEquals(0.5f, Pcm.peak(shortArrayOf(100, -16384, 20), 3), 0.001f)
        assertEquals(1f, Pcm.peak(shortArrayOf(Short.MIN_VALUE), 1), 0f)
        // Only the first n samples count.
        assertEquals(0f, Pcm.peak(shortArrayOf(0, Short.MAX_VALUE), 1), 0f)
    }
}
