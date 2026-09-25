package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf

class BridgesTest {
    private fun events(vararg states: LineState): List<CallEvent> {
        val t = CallTracker()
        return states.flatMap { t.onState(it) }
    }

    @Test
    fun answeredCall() {
        assertEquals(
            listOf(CallEvent("ringing"), CallEvent("talking"), CallEvent("talking", cancel = true)),
            events(LineState.Ringing, LineState.OffHook, LineState.Idle),
        )
    }

    @Test
    fun missedCall() {
        assertEquals(
            listOf(CallEvent("ringing"), CallEvent("missedCall"), CallEvent("ringing", cancel = true)),
            events(LineState.Ringing, LineState.Idle),
        )
    }

    @Test
    fun outgoingCallAndRepeatedStates() {
        assertEquals(
            listOf(CallEvent("talking"), CallEvent("talking", cancel = true)),
            events(LineState.Idle, LineState.OffHook, LineState.OffHook, LineState.Idle, LineState.Idle),
        )
    }

    @Test
    fun telephonyBody() {
        val p = Packet.parse(CallPackets.packet(CallEvent("ringing"), " +47 123 ", "Mom").serialize())!!
        assertEquals(Types.TELEPHONY, p.type)
        assertEquals("ringing", p.string("event"))
        assertEquals("+47 123", p.string("phoneNumber"))
        assertEquals("Mom", p.string("contactName"))
        assertFalse(p.has("isCancel"))

        // Without the contacts permission, the packet has only the number.
        val numberOnly = CallPackets.body(CallEvent("talking", cancel = true), "+47 123", null)
        assertEquals(setOf("event", "phoneNumber", "isCancel"), numberOnly.keys)

        // With no number either, the name is "Unknown caller".
        val unknown = Packet(Types.TELEPHONY, CallPackets.body(CallEvent("ringing"), null, null))
        assertEquals(CallPackets.UNKNOWN, unknown.string("contactName"))
        assertFalse(unknown.has("phoneNumber"))
    }

    private fun notification(vararg fields: Pair<String, Any?>) = Packet(Types.NOTIFICATION, bodyOf(*fields))

    @Test
    fun notificationFromFluxd() {
        val n = ComputerNotification.from(
            notification("id" to "flux-1", "appName" to "omarchy-xps", "title" to "Build done", "text" to "make · 42s", "time" to "1790000000000", "isClearable" to true),
            deviceId = "pc1", computer = "omarchy-xps", now = 5,
        )!!
        assertEquals("omarchy-xps", n.subText)
        assertEquals("Build done", n.title)
        assertEquals("make · 42s", n.text)
        assertEquals(1790000000000L, n.time)
        assertTrue(n.clearable)
        assertFalse(n.cancel)
        assertEquals("pc1:flux-1".hashCode(), n.notificationId)
    }

    @Test
    fun notificationFromAnotherApp() {
        // Another app name shows next to the computer name. A packet with
        // only a ticker uses it as the title.
        val n = ComputerNotification.from(notification("id" to "7", "appName" to "Firefox", "ticker" to "Download done"), "pc1", "omarchy-xps", now = 5)!!
        assertEquals("Firefox · omarchy-xps", n.subText)
        assertEquals("Download done", n.title)
        assertEquals(5L, n.time)
    }

    @Test
    fun notificationCancelAndEmpty() {
        val cancel = ComputerNotification.from(notification("id" to "flux-1", "isCancel" to true), "pc1", "omarchy-xps", 0)!!
        assertTrue(cancel.cancel)
        assertEquals("pc1:flux-1".hashCode(), cancel.notificationId)
        assertNull(ComputerNotification.from(notification("id" to "x"), "pc1", "omarchy-xps", 0))
        assertNull(ComputerNotification.from(notification("title" to "no id"), "pc1", "omarchy-xps", 0))
    }
}
