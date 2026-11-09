package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.OUTGOING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types

class AudioOutputsTest {
    @Test
    fun outputsGoOneWay() {
        // The phone controls the outputs of the computer, not the other way.
        assertTrue(Types.FLUX_AUDIO in INCOMING)
        assertTrue(Types.FLUX_AUDIO_REQUEST in OUTGOING)
        assertFalse(Types.FLUX_AUDIO_REQUEST in INCOMING)
        assertFalse(Types.FLUX_AUDIO in OUTGOING)
    }

    @Test
    fun requestsHaveTheirFields() {
        assertEquals(true, AudioOutputPackets.request().bool("request"))
        val select = AudioOutputPackets.select("hdmi")
        assertEquals(Types.FLUX_AUDIO_REQUEST, select.type)
        assertEquals("hdmi", select.string("output"))
        assertEquals(true, select.bool("default"))
        assertEquals(100, AudioOutputPackets.volume("hdmi", 140).int("volume"))
        assertEquals(0, AudioOutputPackets.volume("hdmi", -3).int("volume"))
        assertEquals(true, AudioOutputPackets.mute("hdmi", true).bool("mute"))
        assertNull(AudioOutputPackets.mute("hdmi", true).int("volume"))
    }

    @Test
    fun parsesTheOutputs() {
        val p = Packet.parse(
            """{"id":1,"type":"flux.audio","body":{"outputs":[""" +
                """{"name":"speakers","description":"Laptop Speakers","volume":72,"muted":false,"default":true},""" +
                """{"name":"hdmi","description":"","volume":120,"muted":true},""" +
                """{"description":"No name"},"text",""" +
                """{"name":"loud","volume":5000}]}}""",
        )!!
        val outs = AudioOutputPackets.parse(p)!!
        assertEquals(
            listOf(
                AudioOutput("speakers", "Laptop Speakers", 72, muted = false, isDefault = true),
                AudioOutput("hdmi", "hdmi", 120, muted = true, isDefault = false),
                AudioOutput("loud", "loud", 1000, muted = false, isDefault = false),
            ),
            outs.list,
        )
        assertEquals("speakers", outs.current?.name)
        assertNull(outs.error)
    }

    @Test
    fun parsesAnError() {
        val p = Packet.parse("""{"id":1,"type":"flux.audio","body":{"outputs":[],"error":"no pactl"}}""")!!
        val outs = AudioOutputPackets.parse(p)!!
        assertTrue(outs.list.isEmpty())
        assertNull(outs.current)
        assertEquals("no pactl", outs.error)
        assertNull(AudioOutputPackets.parse(Packet.parse("""{"id":1,"type":"flux.mpris","body":{}}""")!!))
    }

    @Test
    fun keepsAtMost32Outputs() {
        val list = (1..40).joinToString(",") { """{"name":"o$it"}""" }
        val p = Packet.parse("""{"id":1,"type":"flux.audio","body":{"outputs":[$list]}}""")!!
        assertEquals(AudioOutputPackets.MAX_OUTPUTS, AudioOutputPackets.parse(p)!!.list.size)
    }
}
