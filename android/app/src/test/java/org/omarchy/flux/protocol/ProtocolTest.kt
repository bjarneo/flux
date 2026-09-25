package org.omarchy.flux.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {
    @Test
    fun packetRoundTrip() {
        val p = Packet(Types.SHARE, bodyOf("filename" to "a b.jpg", "open" to false, "numberOfFiles" to 2), id = 42, payloadSize = 1234, payloadPort = 1740)
        val line = p.serialize()
        assertTrue(line.endsWith("\n"))
        val q = Packet.parse(line)!!
        assertEquals(42L, q.id)
        assertEquals(Types.SHARE, q.type)
        assertEquals("a b.jpg", q.string("filename"))
        assertEquals(false, q.bool("open"))
        assertEquals(2, q.int("numberOfFiles"))
        assertEquals(1234L, q.payloadSize)
        assertEquals(1740, q.payloadPort)
    }

    @Test
    fun packetWithoutPortHasNoPayload() {
        val line = Packet(Types.PING, id = 1, payloadSize = 10).serialize()
        assertFalse(line.contains("payloadSize"))
        assertFalse(Packet.parse(line)!!.hasPayload)
    }

    @Test
    fun parseAcceptsStringId() {
        val p = Packet.parse("""{"id":"1790000000123","type":"kdeconnect.ping","body":{}}""")!!
        assertEquals(1790000000123L, p.id)
    }

    @Test
    fun parseRejectsGarbage() {
        assertNull(Packet.parse("not json"))
        assertNull(Packet.parse("""{"id":1,"body":{}}"""))
    }

    @Test
    fun identityPortOnlyInBroadcast() {
        val id = Identity.self("0123456789abcdef0123456789abcdef", "Pixel", 1717)
        assertEquals(1717, Packet.parse(id.toPacket(withPort = true).serialize())!!.int("tcpPort"))
        assertNull(Packet.parse(id.toPacket().serialize())!!.int("tcpPort"))
        val target = Identity("fedcba9876543210fedcba9876543210", "pc", "laptop", 8, emptyList(), emptyList())
        val tcp = Packet.parse(id.toPacket(target = target).serialize())!!
        assertEquals("fedcba9876543210fedcba9876543210", tcp.string("targetDeviceId"))
        assertEquals(8, tcp.int("targetProtocolVersion"))
        assertTrue(tcp.serialize().length < MAX_IDENTITY_LINE)
    }

    @Test
    fun identityParse() {
        val id = Identity.self("0123456789abcdef0123456789abcdef", "Pixel", 1717)
        val back = Identity.from(Packet.parse(id.toPacket(withPort = true).serialize())!!)!!
        assertEquals(id.deviceId, back.deviceId)
        assertEquals("phone", back.deviceType)
        assertEquals(8, back.protocolVersion)
        assertEquals(INCOMING, back.incoming)
        assertNull(Identity.from(Packet(Types.IDENTITY, bodyOf("deviceId" to "short"))))
    }

    @Test
    fun cleanNames() {
        assertEquals("Bobs phone", cleanName("Bob's phone!"))
        assertEquals("abc", cleanName("  a(b)c.  "))
        assertEquals(32, cleanName("x".repeat(40)).length)
        assertEquals("Android", cleanName("\"\"\""))
    }

    @Test
    fun deviceIds() {
        assertTrue(validDeviceId("0123456789abcdef0123456789abcdef"))
        assertTrue(validDeviceId("_0123456789abcdef_0123456789abcdef_"))
        assertFalse(validDeviceId("0123"))
        assertFalse(validDeviceId("0123456789abcdef0123456789abcde!"))
    }

    @Test
    fun unsignedByteOrder() {
        assertTrue(compareBytes(byteArrayOf(0x80.toByte()), byteArrayOf(0x7f)) > 0)
        assertTrue(compareBytes(byteArrayOf(1, 2), byteArrayOf(1, 2, 0)) < 0)
        assertEquals(0, compareBytes(byteArrayOf(5), byteArrayOf(5)))
    }

    @Test
    fun verificationKeyVector() {
        // Expected values come from Python: sha256(larger + smaller + "1790000000").
        val a = byteArrayOf(0x30, 0x82.toByte(), 0x01, 0x22, 0x80.toByte())
        val b = byteArrayOf(0x30, 0x82.toByte(), 0x01, 0x22, 0x7f)
        assertEquals("5EE6825F", verificationKey(a, b, 1790000000))
        assertEquals("5EE6825F", verificationKey(b, a, 1790000000))
        assertEquals("5BB22DB1", verificationKey(a, b, 0))
    }

    @Test
    fun generatedCertificate() {
        val id = "0123456789abcdef0123456789abcdef"
        val c = LocalCertificate.generate(id)
        assertEquals(id, c.deviceId)
        val dn = c.certificate.subjectX500Principal.name
        assertTrue(dn.contains("O=KDE"))
        assertTrue(dn.contains("OU=KDE Connect"))
        val spki = subjectPublicKeyInfo(c.certificate)
        assertTrue(spki.contentEquals(c.certificate.publicKey.encoded))
        val other = LocalCertificate.generate("fedcba9876543210fedcba9876543210")
        val k1 = verificationKey(c.certificate, other.certificate, 1790000000)
        val k2 = verificationKey(other.certificate, c.certificate, 1790000000)
        assertEquals(k1, k2)
        assertEquals(8, k1.length)
        assertNotNull(k1.toLongOrNull(16))
    }
}
