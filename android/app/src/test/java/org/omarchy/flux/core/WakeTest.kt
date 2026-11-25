package org.omarchy.flux.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import org.omarchy.flux.protocol.Packet

class WakeTest {
    private fun packet(targets: String) = Packet.parse("""{"id":1,"type":"flux.wake","body":{"targets":$targets}}""")!!

    @Test
    fun parseKeepsValidTargets() {
        val p = packet(
            """[{"mac":"AA:BB:CC:DD:EE:01","broadcast":"192.168.1.255"},
               {"mac":"aa:bb:cc:dd:ee:02","broadcast":"not an address","wireless":true},
               {"mac":"aa:bb:cc:dd:ee"},{"mac":"aa:bb:cc:dd:ee:01"},{"broadcast":"10.0.0.255"},7]""",
        )
        assertEquals(
            listOf(
                WakeTarget("aa:bb:cc:dd:ee:01", "192.168.1.255"),
                WakeTarget("aa:bb:cc:dd:ee:02", "", wireless = true),
            ),
            Wake.parse(p),
        )
        assertEquals(emptyList<WakeTarget>(), Wake.parse(Packet.parse("""{"id":1,"type":"flux.wake","body":{}}""")!!))
    }

    @Test
    fun magicPacketRepeatsTheMac() {
        val m = Wake.magic("01:23:45:67:89:ab")
        assertEquals(102, m.size)
        assertArrayEquals(ByteArray(6) { 0xFF.toByte() }, m.copyOfRange(0, 6))
        val mac = byteArrayOf(0x01, 0x23, 0x45, 0x67, 0x89.toByte(), 0xab.toByte())
        for (i in 0 until 16) assertArrayEquals(mac, m.copyOfRange(6 + i * 6, 12 + i * 6))
    }

    @Test
    fun destinationsAreDistinctIpv4() {
        val targets = listOf(WakeTarget("aa:bb:cc:dd:ee:01", "192.168.1.255"), WakeTarget("aa:bb:cc:dd:ee:02"))
        assertEquals(
            listOf("192.168.1.255", "10.0.0.255", "255.255.255.255", "192.168.1.20"),
            Wake.destinations(targets, listOf("10.0.0.255", "192.168.1.255"), "192.168.1.20"),
        )
        assertEquals(listOf("255.255.255.255"), Wake.destinations(emptyList(), emptyList(), "fe80::1"))
    }
}
