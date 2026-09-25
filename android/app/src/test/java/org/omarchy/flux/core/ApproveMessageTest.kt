package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.util.Base64

/**
 * The vectors are the same as in the Go test internal/approve/message_test.go,
 * so that the phone signs the bytes that the helper checks.
 */
class ApproveMessageTest {
    private val nonce = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    private val request = ApproveRequest(
        computerId = "pc1", computerName = "omarchy-xps", id = "req1", kind = ApproveRequest.Kind.Approve,
        host = "omarchy-xps", user = "alice", service = "sudo", tty = "/dev/pts/3", rhost = "",
        time = 1790000000, nonce = nonce, timeoutSeconds = 20,
    )

    @Test
    fun approvalBytes() {
        val want = "flux-approve-v1\nhost=omarchy-xps\nuser=alice\nservice=sudo\ntty=/dev/pts/3\nrhost=\ntime=1790000000\nnonce=$nonce\n"
        assertEquals(want, String(ApproveMessage.approval(request), Charsets.UTF_8))
    }

    @Test
    fun enrollmentBytes() {
        val e = request.copy(kind = ApproveRequest.Kind.Enroll, service = "", tty = "")
        val want = "flux-approve-enroll-v1\nhost=omarchy-xps\nuser=alice\n" +
            "key=62af8704764faf8ea82fc61ce9c4c3908b6cb97d463a634e9e587d7c885db0ef\n" +
            "time=1790000000\nnonce=$nonce\n"
        assertEquals(want, String(ApproveMessage.enrollment(e, "test-key".toByteArray()), Charsets.UTF_8))
    }

    @Test
    fun fingerprint() {
        assertEquals("62AF 8704 764F AF8E", ApproveMessage.fingerprint("test-key".toByteArray()))
    }

    @Test
    fun fieldRules() {
        assertTrue(ApproveMessage.validField("/dev/pts/3"))
        assertTrue(ApproveMessage.validField(""))
        assertTrue(ApproveMessage.validField("Pixel 8 · Office"))
        assertFalse(ApproveMessage.validField("alice\nservice=sshd"))
        assertFalse(ApproveMessage.validField("tab\there"))
        assertFalse(ApproveMessage.validField("c1\u0085"))
        assertFalse(ApproveMessage.validField("x".repeat(257)))
        assertFalse(ApproveMessage.validField("\uD800"))
        assertTrue(ApproveMessage.validNonce(nonce))
        assertFalse(ApproveMessage.validNonce(nonce.uppercase()))
        assertFalse(ApproveMessage.validNonce(nonce.dropLast(2)))
    }

    private fun packet(vararg extra: Pair<String, Any?>): Packet {
        val fields = mutableMapOf<String, Any?>(
            "kind" to "request", "id" to "req1", "host" to "omarchy-xps", "user" to "alice", "service" to "sudo",
            "tty" to "/dev/pts/3", "rhost" to "", "time" to 1790000000L, "nonce" to nonce, "timeout" to 20,
        )
        for ((k, v) in extra) fields[k] = v
        return Packet(Types.FLUX_APPROVE, bodyOf(*fields.toList().toTypedArray()))
    }

    @Test
    fun parseRequest() {
        val r = ApproveMessage.parse(packet(), "pc1", "omarchy-xps")
        assertEquals(request, r)
        assertEquals("Approve sudo for user alice on host omarchy-xps?", ApproveMessage.question(r!!))
    }

    @Test
    fun parseRefusesBadRequests() {
        assertNull(ApproveMessage.parse(packet("user" to "alice\nservice=sshd"), "pc1", "pc"))
        assertNull(ApproveMessage.parse(packet("nonce" to "abcd"), "pc1", "pc"))
        assertNull(ApproveMessage.parse(packet("host" to ""), "pc1", "pc"))
        assertNull(ApproveMessage.parse(packet("service" to ""), "pc1", "pc"))
        assertNull(ApproveMessage.parse(packet("kind" to "other"), "pc1", "pc"))
        assertNull(ApproveMessage.parse(packet("id" to ""), "pc1", "pc"))
    }

    @Test
    fun parseEnrollment() {
        val r = ApproveMessage.parse(packet("kind" to "enroll", "service" to null), "pc1", "omarchy-xps")
        assertNotNull(r)
        assertEquals(ApproveRequest.Kind.Enroll, r!!.kind)
        assertEquals("Use this phone to approve sudo for user alice on host omarchy-xps?", ApproveMessage.question(r))
    }

    @Test
    fun freshness() {
        assertTrue(ApproveMessage.fresh(request, request.time + 30))
        assertTrue(ApproveMessage.fresh(request, request.time - 30))
        assertFalse(ApproveMessage.fresh(request, request.time + 601))
        assertFalse(ApproveMessage.fresh(request, request.time - 601))
    }

    @Test
    fun answerPackets() {
        val sig = byteArrayOf(1, 2, 3)
        val a = ApproveMessage.approved("req1", sig)
        assertEquals(Types.FLUX_APPROVE, a.type)
        assertEquals("response", a.string("kind"))
        assertEquals("req1", a.string("id"))
        assertEquals(Base64.getEncoder().encodeToString(sig), a.string("signature"))
        assertNull(a.bool("denied"))

        val d = ApproveMessage.denied("req1")
        assertEquals("response", d.string("kind"))
        assertEquals(true, d.bool("denied"))
        assertNull(d.string("signature"))

        val e = ApproveMessage.enrolled("req1", "key".toByteArray(), sig)
        assertEquals("enrolled", e.string("kind"))
        assertEquals(Base64.getEncoder().encodeToString("key".toByteArray()), e.string("publicKey"))

        val f = ApproveMessage.failed("req1", "x".repeat(500))
        assertEquals(200, f.string("error")!!.length)

        // A packet survives the wire format.
        val back = Packet.parse(a.serialize())!!
        assertEquals(a.string("signature"), back.string("signature"))
    }
}
