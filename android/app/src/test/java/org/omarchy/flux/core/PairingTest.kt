package org.omarchy.flux.core

import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types

/** The certificate check of a new link, the trust rules of a link, and the herdr parse gate. */
class PairingTest {
    private val pinned = byteArrayOf(1, 2, 3)
    private val other = byteArrayOf(9, 9, 9)

    @Test
    fun trustedDeviceNeedsPinnedCertificate() {
        assertTrue(linkAllowed(pinned, trusted = true, pinned = pinned, pairing = null))
        assertFalse(linkAllowed(other, trusted = true, pinned = pinned, pairing = null))
    }

    @Test
    fun unreadablePinRefusesEveryLink() {
        assertFalse(linkAllowed(other, trusted = true, pinned = null, pairing = null))
    }

    @Test
    fun openPairingKeepsItsCertificate() {
        assertTrue(linkAllowed(pinned, trusted = false, pinned = null, pairing = pinned))
        assertFalse("a second link cannot take a pairing in progress", linkAllowed(other, trusted = false, pinned = null, pairing = pinned))
    }

    @Test
    fun unpairedDeviceCanBeReplaced() {
        // Without trust and without an open pairing, a device that is not
        // paired cannot keep the device ID from another one.
        assertTrue(linkAllowed(other, trusted = false, pinned = null, pairing = null))
    }

    @Test
    fun unpairedDeviceGetsPairFalseOncePerLink() {
        // A device that still trusts the phone gets pair false, so that it
        // drops its trust.
        assertTrue(refusesUnpaired(paired = false, pairing = false, refused = false))
        // The next packet on the same link gets no second answer. An unpair
        // on the phone marks its link in the same way.
        assertFalse(refusesUnpaired(paired = false, pairing = false, refused = true))
    }

    @Test
    fun pairedOrPairingDeviceGetsNoPairFalse() {
        assertFalse(refusesUnpaired(paired = true, pairing = false, refused = false))
        assertFalse("the answer does not end an open pairing", refusesUnpaired(paired = false, pairing = true, refused = false))
    }

    @Test
    fun newLinkEndsOpenPairing() {
        assertTrue(endsPairing(pairing = true, hasOldLink = true, sameLink = false))
    }

    @Test
    fun pairingStaysOnItsLink() {
        assertFalse(endsPairing(pairing = true, hasOldLink = true, sameLink = true))
        assertFalse("a first link ends nothing", endsPairing(pairing = true, hasOldLink = false, sameLink = false))
        assertFalse(endsPairing(pairing = false, hasOldLink = true, sameLink = false))
    }

    private fun output(text: String) = Packet(
        Types.FLUX_HERDR,
        kotlinx.serialization.json.JsonObject(
            mapOf("kind" to JsonPrimitive("output"), "pane" to JsonPrimitive("w1:p1"), "text" to JsonPrimitive(text)),
        ),
    )

    @Test
    fun herdrOutputOnlyFromPairedDevice() {
        assertNull(herdrOutputOf(paired = false, output("hello")))
        assertEquals("hello", herdrOutputOf(paired = true, output("hello"))!!.text)
        assertNull(herdrOutputOf(paired = true, Packet(Types.PING)))
    }
}
