package org.omarchy.flux.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.OUTGOING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf

class StreamRequestTest {
    private fun request(vararg fields: Pair<String, Any?>) = Packet(Types.FLUX_STREAM_REQUEST, bodyOf(*fields))

    @Test
    fun thePhoneListsTheRequestOnlyAsIncoming() {
        assertEquals("flux.stream.request", Types.FLUX_STREAM_REQUEST)
        assertTrue(Types.FLUX_STREAM_REQUEST in INCOMING)
        assertFalse("the phone never asks a computer", Types.FLUX_STREAM_REQUEST in OUTGOING)
    }

    @Test
    fun parsesTheTwoKinds() {
        assertEquals(StreamKind.Webcam, StreamRequestPacket.parse(request("kind" to "webcam")))
        assertEquals(StreamKind.Mic, StreamRequestPacket.parse(request("kind" to "mic")))
        // The packet survives the wire.
        assertEquals(StreamKind.Mic, StreamRequestPacket.parse(Packet.parse(request("kind" to "mic").serialize())!!))
    }

    @Test
    fun ignoresExtraFields() {
        assertEquals(StreamKind.Webcam, StreamRequestPacket.parse(request("kind" to "webcam", "start" to true, "width" to 1920)))
    }

    @Test
    fun ignoresOtherKindsAndOtherPackets() {
        assertNull(StreamRequestPacket.parse(request("kind" to "screen")))
        assertNull(StreamRequestPacket.parse(request("kind" to "Webcam")))
        assertNull(StreamRequestPacket.parse(request("kind" to "")))
        assertNull(StreamRequestPacket.parse(request()))
        assertNull("the kind must be a string", StreamRequestPacket.parse(request("kind" to 1)))
        assertNull(StreamRequestPacket.parse(Packet(Types.FLUX_STREAM_REQUEST, bodyOf("kind" to listOf("webcam")))))
        assertNull(StreamRequestPacket.parse(Packet(Types.FLUX_STREAM_REQUEST, JsonObject(mapOf("kind" to JsonPrimitive(true))))))
        assertNull(StreamRequestPacket.parse(Packet(Types.FLUX_WEBCAM, bodyOf("kind" to "webcam"))))
    }

    @Test
    fun theTextFollowsTheContract() {
        assertEquals("omarchy-xps asks for the webcam", StreamKind.Webcam.title("omarchy-xps"))
        assertEquals("omarchy-xps asks for the mic", StreamKind.Mic.title("omarchy-xps"))
        assertEquals("Start webcam", StreamKind.Webcam.startLabel())
        assertEquals("Start the mic", StreamKind.Mic.startLabel())
        assertEquals("Tap to start the webcam.", StreamKind.Webcam.tapText())
        assertEquals("Tap to start the mic.", StreamKind.Mic.tapText())
        assertEquals(StreamKind.Webcam, StreamKind.fromKey("webcam"))
        assertNull(StreamKind.fromKey(null))
    }

    @Test
    fun theLimitDropsARepeatInThreeSeconds() {
        val limit = StreamRequestLimit()
        assertTrue(limit.admit("pc", StreamKind.Webcam, 10_000))
        assertFalse(limit.admit("pc", StreamKind.Webcam, 10_001))
        assertFalse(limit.admit("pc", StreamKind.Webcam, 12_999))
        assertFalse("the time counts from the last request, also one that did not show", limit.admit("pc", StreamKind.Webcam, 15_998))
        assertTrue("3 seconds after the last one", limit.admit("pc", StreamKind.Webcam, 18_998))
        assertFalse(limit.admit("pc", StreamKind.Webcam, 21_997))
    }

    @Test
    fun theLimitIsPerKindAndComputer() {
        val limit = StreamRequestLimit()
        assertTrue(limit.admit("pc", StreamKind.Webcam, 1_000))
        assertTrue("another kind", limit.admit("pc", StreamKind.Mic, 1_001))
        assertTrue("another computer", limit.admit("desk", StreamKind.Webcam, 1_002))
        assertFalse(limit.admit("pc", StreamKind.Mic, 1_500))
        limit.forget("pc")
        assertTrue("an unpair resets the limit", limit.admit("pc", StreamKind.Webcam, 1_600))
        assertFalse("the other computer keeps its limit", limit.admit("desk", StreamKind.Webcam, 1_700))
    }

    @Test
    fun aRunningStreamMakesTheRequestDoNothing() {
        val book = StreamRequestBook()
        assertEquals(StreamOutcome.Running, book.receive("pc", "omarchy", StreamKind.Webcam, running = true, now = 1_000))
        assertTrue(book.requests.isEmpty())
        assertEquals("a request while the stream runs counts for the limit", StreamOutcome.TooSoon, book.receive("pc", "omarchy", StreamKind.Webcam, running = false, now = 2_000))
    }

    @Test
    fun theBookKeepsEachOpenRequestTheNewestLast() {
        val book = StreamRequestBook()
        val webcam = StreamRequest("pc", "omarchy", StreamKind.Webcam, 1_000)
        val mic = StreamRequest("pc", "omarchy", StreamKind.Mic, 1_500)
        val desk = StreamRequest("desk", "desk", StreamKind.Webcam, 2_000)
        assertEquals(StreamOutcome.Opened(webcam), book.receive("pc", "omarchy", StreamKind.Webcam, running = false, now = 1_000))
        assertEquals(StreamOutcome.Opened(mic), book.receive("pc", "omarchy", StreamKind.Mic, running = false, now = 1_500))
        assertEquals(StreamOutcome.Opened(desk), book.receive("desk", "desk", StreamKind.Webcam, running = false, now = 2_000))
        assertEquals("a request of another kind or computer does not replace the open one", listOf(webcam, mic, desk), book.requests)
        assertEquals("the answer ends 1 request", mic, book.remove("pc", StreamKind.Mic))
        assertNull(book.remove("pc", StreamKind.Mic))
        assertEquals("the prompt then shows the next one", listOf(webcam, desk), book.requests)
    }

    @Test
    fun aNewRequestReplacesTheOpenOneOfTheSameKindAndComputer() {
        val book = StreamRequestBook()
        book.receive("pc", "omarchy", StreamKind.Webcam, running = false, now = 1_000)
        book.receive("desk", "desk", StreamKind.Webcam, running = false, now = 2_000)
        val again = StreamRequest("pc", "omarchy", StreamKind.Webcam, 5_000)
        assertEquals(StreamOutcome.Opened(again), book.receive("pc", "omarchy", StreamKind.Webcam, running = false, now = 5_000))
        assertEquals(listOf(StreamRequest("desk", "desk", StreamKind.Webcam, 2_000), again), book.requests)
    }

    @Test
    fun aRequestEndsAfterItsLifetime() {
        val book = StreamRequestBook(lifetimeMs = 60_000)
        book.receive("pc", "omarchy", StreamKind.Webcam, running = false, now = 1_000)
        book.receive("pc", "omarchy", StreamKind.Mic, running = false, now = 30_000)
        assertTrue(book.expire(60_999).isEmpty())
        assertEquals(listOf(StreamRequest("pc", "omarchy", StreamKind.Webcam, 1_000)), book.expire(61_000))
        val mic = book.requests.single()
        assertTrue(book.fresh(mic, 89_999))
        assertFalse(book.fresh(mic, 90_000))
    }

    @Test
    fun anUnpairEndsTheRequestsAndTheLimitOfTheComputer() {
        val book = StreamRequestBook()
        book.receive("pc", "omarchy", StreamKind.Webcam, running = false, now = 1_000)
        book.receive("desk", "desk", StreamKind.Mic, running = false, now = 1_000)
        assertEquals(listOf(StreamRequest("pc", "omarchy", StreamKind.Webcam, 1_000)), book.forget("pc"))
        assertEquals(listOf(StreamRequest("desk", "desk", StreamKind.Mic, 1_000)), book.requests)
        assertTrue(book.receive("pc", "omarchy", StreamKind.Webcam, running = false, now = 1_100) is StreamOutcome.Opened)
        assertEquals(StreamOutcome.TooSoon, book.receive("desk", "desk", StreamKind.Mic, running = false, now = 1_100))
    }

    @Test
    fun aNotificationKeyStartsOnce() {
        var n = 0
        val keys = StreamStartKeys(validMs = 120_000) { "key${n++}" }
        val key = keys.issue("pc", StreamKind.Webcam, 1_000)
        assertTrue(keys.redeem(key, "pc", StreamKind.Webcam, 2_000))
        assertFalse("a key works once", keys.redeem(key, "pc", StreamKind.Webcam, 2_001))
        assertFalse("an unknown key", keys.redeem("other", "pc", StreamKind.Webcam, 2_002))
    }

    @Test
    fun aNotificationKeyIsForItsComputerAndKind() {
        var n = 0
        val keys = StreamStartKeys(validMs = 120_000) { "key${n++}" }
        val webcam = keys.issue("pc", StreamKind.Webcam, 0)
        assertFalse(keys.redeem(webcam, "pc", StreamKind.Mic, 1))
        val mic = keys.issue("pc", StreamKind.Mic, 0)
        assertFalse(keys.redeem(mic, "desk", StreamKind.Mic, 1))
    }

    @Test
    fun aNotificationKeyExpiresAndANewRequestReplacesIt() {
        var n = 0
        val keys = StreamStartKeys(validMs = 120_000) { "key${n++}" }
        val old = keys.issue("pc", StreamKind.Webcam, 0)
        assertFalse(keys.redeem(old, "pc", StreamKind.Webcam, 120_000))
        val first = keys.issue("pc", StreamKind.Webcam, 200_000)
        val second = keys.issue("pc", StreamKind.Webcam, 201_000)
        assertNotEquals(first, second)
        assertFalse("the new notification replaces the old one", keys.redeem(first, "pc", StreamKind.Webcam, 202_000))
        assertTrue(keys.redeem(second, "pc", StreamKind.Webcam, 202_000))
        val gone = keys.issue("pc", StreamKind.Mic, 300_000)
        keys.forget("pc")
        assertFalse("an unpair removes the keys", keys.redeem(gone, "pc", StreamKind.Mic, 300_001))
    }

    @Test
    fun anAnswerInThePromptRemovesTheKeyOfTheNotification() {
        var n = 0
        val keys = StreamStartKeys(validMs = 120_000) { "key${n++}" }
        val webcam = keys.issue("pc", StreamKind.Webcam, 0)
        val mic = keys.issue("pc", StreamKind.Mic, 0)
        keys.drop("pc", StreamKind.Webcam)
        assertFalse(keys.redeem(webcam, "pc", StreamKind.Webcam, 1))
        assertTrue("the key of the other kind stays", keys.redeem(mic, "pc", StreamKind.Mic, 1))
    }

    @Test
    fun onlyThePageOfTheTapTakesTheStart() {
        val s = StreamStart("pc", StreamKind.Mic, 1_000)
        assertTrue(takesStart(s, "pc", StreamKind.Mic, 1_000))
        assertTrue(takesStart(s, "pc", StreamKind.Mic, 1_000 + StreamRequests.START_MS - 1))
        assertFalse("a start that is too old", takesStart(s, "pc", StreamKind.Mic, 1_000 + StreamRequests.START_MS))
        assertFalse(takesStart(s, "pc", StreamKind.Webcam, 1_001))
        assertFalse(takesStart(s, "desk", StreamKind.Mic, 1_001))
        assertFalse(takesStart(null, "pc", StreamKind.Mic, 1_001))
    }
}
