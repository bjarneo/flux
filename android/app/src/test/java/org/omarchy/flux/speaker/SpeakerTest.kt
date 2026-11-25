package org.omarchy.flux.speaker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.OUTGOING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf

class SpeakerTest {
    @Test
    fun capabilityIsInBothLists() {
        assertTrue(Types.FLUX_SPEAKER in INCOMING)
        assertTrue(Types.FLUX_SPEAKER in OUTGOING)
    }

    @Test
    fun packetsHaveTheirFields() {
        val p = SpeakerPackets.start(12071, mute = true)
        assertEquals(Types.FLUX_SPEAKER, p.type)
        assertEquals("start", p.string("state"))
        assertEquals(12071, p.int("port"))
        assertEquals(true, p.bool("mute"))
        assertEquals(12071, Packet.parse(p.serialize())!!.int("port"))
        assertEquals(false, SpeakerPackets.start(12071, mute = false).bool("mute"))
        assertEquals("stop", SpeakerPackets.stop().string("state"))
        val mute = SpeakerPackets.mute(false)
        assertEquals("mute", mute.string("state"))
        assertEquals(false, mute.bool("mute"))
        // 20 ms of stereo, 48 kHz, 16-bit audio, as fluxd sends it.
        assertEquals(3840, SpeakerPackets.FRAME_BYTES)
    }

    @Test
    fun parsesReplies() {
        fun reply(vararg fields: Pair<String, Any?>) = SpeakerReply.parse(Packet(Types.FLUX_SPEAKER, bodyOf(*fields)))
        assertEquals(SpeakerReply.Live, reply("state" to "live", "rate" to 48000, "channels" to 2))
        assertEquals(SpeakerReply.Muted("Laptop Speakers", null), reply("state" to "muted", "output" to "Laptop Speakers"))
        assertEquals(SpeakerReply.Muted("", null), reply("state" to "muted", "output" to ""))
        assertEquals(SpeakerReply.Muted("", "no pactl"), reply("state" to "muted", "message" to "no pactl"))
        assertEquals(SpeakerReply.Failed("no pw-record"), reply("state" to "error", "message" to "no pw-record"))
        assertEquals(SpeakerReply.Failed("The computer could not play its audio on this phone"), reply("state" to "error"))
        assertEquals(SpeakerReply.Stop, reply("state" to "stop"))
        assertNull(reply("state" to "start"))
        assertNull(SpeakerReply.parse(Packet(Types.FLUX_MIC, bodyOf("state" to "live"))))
    }

    @Test
    fun theQueueIsShort() {
        assertEquals(4800, speakerFrames(SPEAKER_QUEUE_MS))
        assertEquals(1920, speakerFrames(SPEAKER_START_MS))
        assertTrue(SPEAKER_START_MS < SPEAKER_QUEUE_MS)
        assertTrue(SPEAKER_QUEUE_MS < SPEAKER_CAPACITY_MS)
    }
}
