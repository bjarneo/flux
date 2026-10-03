package org.omarchy.flux.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Flux ports of the phone, and the link ports that it accepts from a computer. */
class PortsTest {
    @Test
    fun ports() {
        assertEquals(12100, UDP_PORT)
        assertEquals(12100..12108, TCP_PORTS)
        assertEquals(12070..12099, PAYLOAD_PORTS)
    }

    @Test
    fun linkPortOfAComputer() {
        // The phone connects to a computer only when its UDP identity has a port in TCP_PORTS.
        for (port in listOf(12100, 12104, 12108)) assertTrue("port $port", port in TCP_PORTS)
        // The ports of an earlier fluxd, the payload range, and the ports next to the range get no connect.
        for (port in listOf(0, 1716, 1764, 12070, 12099, 12109, 65535)) assertFalse("port $port", port in TCP_PORTS)
    }

    @Test
    fun payloadListenersDoNotTakeALinkPort() {
        assertTrue(PAYLOAD_PORTS.none { it in TCP_PORTS })
        assertFalse(UDP_PORT in PAYLOAD_PORTS)
    }
}
