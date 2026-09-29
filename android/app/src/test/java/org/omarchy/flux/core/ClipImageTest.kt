package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.Identity
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf

class ClipImageTest {
    private val id = "0123456789abcdef0123456789abcdef"

    @Test
    fun picksTheFirstSyncedType() {
        assertEquals("image/png", ClipImage.pickType(listOf("text/uri-list", "image/png", "image/jpeg")))
        assertEquals("image/jpeg", ClipImage.pickType(listOf(null, "image/jpeg")))
        assertNull(ClipImage.pickType(listOf("image/heic", "text/plain")))
        assertNull(ClipImage.pickType(emptyList()))
    }

    @Test
    fun extensionFollowsTheType() {
        assertEquals("png", ClipImage.extension("image/png"))
        assertEquals("jpg", ClipImage.extension("image/jpeg"))
        assertEquals("gif", ClipImage.extension("image/gif"))
        assertEquals("webp", ClipImage.extension("image/webp"))
    }

    @Test
    fun incomingFollowsTheSyncSwitch() {
        val on = Identity.self(id, "Pixel 8", 1716, clipboardImages = true)
        val off = Identity.self(id, "Pixel 8", 1716, clipboardImages = false)
        assertTrue(Types.FLUX_CLIPBOARD_IMAGE in on.incoming)
        assertFalse(Types.FLUX_CLIPBOARD_IMAGE in off.incoming)
        // The phone can always send an image with Send clipboard.
        assertTrue(Types.FLUX_CLIPBOARD_IMAGE in on.outgoing)
        assertTrue(Types.FLUX_CLIPBOARD_IMAGE in off.outgoing)
    }

    @Test
    fun packetCarriesTheTypeAndThePayload() {
        val p = Packet(Types.FLUX_CLIPBOARD_IMAGE, bodyOf("mime" to "image/png"), payloadSize = 2048, payloadPort = 1739)
        val line = p.serialize().trim()
        val back = Packet.parse(line)!!
        assertEquals(Types.FLUX_CLIPBOARD_IMAGE, back.type)
        assertEquals("image/png", back.string("mime"))
        assertEquals(2048L, back.payloadSize)
        assertTrue(line.contains(""""payloadTransferInfo":{"port":1739}"""))
    }
}
