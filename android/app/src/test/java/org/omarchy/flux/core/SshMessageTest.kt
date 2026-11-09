package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.nio.ByteBuffer
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.Base64

/**
 * The vectors are the same as in the Go test internal/sshagent/agent_test.go,
 * so that the phone and fluxd agree on the key, its fingerprint, and the
 * data that the key signs.
 */
class SshMessageTest {
    private val spki = Base64.getDecoder().decode(
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE0fvX8Z0xxlym8ZekiVKUzbH41pZi6APeveBFIYS7nJEP6tNHnpTjN+lYesUoqn1u3T0xL0Tdj6zXh/IKW//0Fw==",
    )
    private val line = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBNH71/GdMcZcpvGXpIlSlM2x+NaWYugD3r3gRSGEu5yRD+rTR56U4zfpWHrFKKp9bt09MS9E3Y+s14fyClv/9Bc= Flux on Pixel 8"
    private val login = hex(
        "00000020070707070707070707070707070707070707070707070707070707070707070732000000036769740000000e7373682d636f6e6e656374696f6e000000237075626c69636b65792d686f7374626f756e642d763030406f70656e7373682e636f6d010000001365636473612d736861322d6e69737470323536000000680000001365636473612d736861322d6e69737470323536000000086e697374703235360000004104d1fbd7f19d31c65ca6f197a4895294cdb1f8d69662e803debde0452184bb9c910fead3479e94e337e9587ac528aa7d6edd3d312f44dd8facd787f20a5bfff41700000008686f7374206b6579",
    )
    private val signature = hex(
        "5353485349470000000367697400000000000000067368613235360000002062c66a7a5dd70c3146618063c344e531e6d4b59e379808443ce962b3abd63c5a",
    )
    private val blob = SshMessage.keyBlob(spki)!!

    @Test
    fun keyLineAndFingerprint() {
        assertEquals(line, SshMessage.authorizedKey(blob, "Flux on Pixel 8"))
        assertEquals("SHA256:uk2DU7O00GnwbbL4vBzKRyuHlZ/ZfhHpgGM7thsHUig", SshMessage.fingerprint(blob))
    }

    @Test
    fun otherCurveIsNoKey() {
        val g = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp384r1")) }
        assertNull(SshMessage.keyBlob(g.generateKeyPair().public.encoded))
        assertNull(SshMessage.keyBlob("not a key".toByteArray()))
    }

    @Test
    fun sharedData() {
        assertEquals(SshData.Login("git"), SshMessage.parseData(login, blob))
        assertEquals(SshData.Signature("git"), SshMessage.parseData(signature, blob))
    }

    @Test
    fun refusedData() {
        val other = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }
        val otherBlob = SshMessage.keyBlob(other.generateKeyPair().public.encoded)!!
        assertNull("another key", SshMessage.parseData(login, otherBlob))
        assertNull("extra bytes", SshMessage.parseData(login + byteArrayOf(0), blob))
        assertNull("a cut login", SshMessage.parseData(login.copyOf(login.size - 1), blob))
        assertNull("extra bytes", SshMessage.parseData(signature + byteArrayOf(0), blob))
        assertNull("text", SshMessage.parseData("hello".toByteArray(), blob))
        assertNull("nothing", SshMessage.parseData(ByteArray(0), blob))
        assertNull("too much", SshMessage.parseData(signature + ByteArray(SshMessage.MAX_DATA), blob))
        assertNull("a control character", SshMessage.parseData(sshsig("git\u001b[2J"), blob))
        assertNull("a bidi control", SshMessage.parseData(sshsig("git‮"), blob))
        assertNull("no namespace", SshMessage.parseData(sshsig(""), blob))
        assertEquals(SshData.Signature("file"), SshMessage.parseData(sshsig("file"), blob))
    }

    @Test
    fun cleanText() {
        assertEquals("ssh git@github.com", SshMessage.clean("ssh  git@github.com"))
        assertEquals("evil a b [2J c", SshMessage.clean("evil a\nb\u001b[2J‮c"))
        val long = SshMessage.clean("é".repeat(300))
        assertTrue(long.endsWith("…"))
        assertTrue(long.toByteArray().size <= SshMessage.MAX_PROGRAM)
        assertTrue(SshMessage.validText("Pixel 8 · Office"))
        assertFalse(SshMessage.validText("a⁦b"))
        assertFalse(SshMessage.validText("\uD800"))
    }

    private fun request(fields: Map<String, Any?>): Packet {
        val base = mutableMapOf<String, Any?>(
            "kind" to "sign", "id" to "req1", "key" to Base64.getEncoder().encodeToString(spki),
            "data" to Base64.getEncoder().encodeToString(signature), "program" to "ssh-keygen -Y sign -n git", "timeout" to 30,
        )
        base.putAll(fields)
        return Packet(Types.FLUX_SSH, bodyOf(*base.filterValues { it != null }.toList().toTypedArray()))
    }

    @Test
    fun parseRequest() {
        val ok = SshMessage.parse(request(emptyMap()), "pc1", "omarchy-xps", spki) as SshMessage.Parsed.Ok
        assertEquals("req1", ok.request.id)
        assertEquals(SshData.Signature("git"), ok.request.what)
        assertEquals("ssh-keygen -Y sign -n git", ok.request.program)
        assertEquals(30, ok.request.timeoutSeconds)
        assertEquals("Sign a Git commit or tag with the SSH key of this phone?", SshMessage.question(ok.request))

        val hostile = SshMessage.parse(request(mapOf("program" to "ssh\nApprove‮", "timeout" to 9999)), "pc1", "pc", spki) as SshMessage.Parsed.Ok
        assertEquals("ssh Approve", hostile.request.program)
        assertEquals(SshMessage.MAX_TIMEOUT, hostile.request.timeoutSeconds)

        assertEquals(SshMessage.Parsed.Invalid, SshMessage.parse(request(mapOf("id" to null)), "pc1", "pc", spki))
        val off = SshMessage.parse(request(emptyMap()), "pc1", "pc", null) as SshMessage.Parsed.Refused
        assertEquals("SSH key is off on this phone", off.message)
        val other = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        assertTrue(SshMessage.parse(request(emptyMap()), "pc1", "pc", other.public.encoded) is SshMessage.Parsed.Refused)
        val text = Base64.getEncoder().encodeToString("a message of another protocol".toByteArray())
        assertTrue(SshMessage.parse(request(mapOf("data" to text)), "pc1", "pc", spki) is SshMessage.Parsed.Refused)
        assertTrue(SshMessage.parse(request(mapOf("data" to "not base64!")), "pc1", "pc", spki) is SshMessage.Parsed.Refused)
    }

    @Test
    fun actions() {
        assertEquals("Log in as git", SshMessage.action(SshData.Login("git")))
        assertEquals("Sign a file", SshMessage.action(SshData.Signature("file")))
        assertEquals("Sign in the namespace backup", SshMessage.action(SshData.Signature("backup")))
    }

    /** A key that the JVM makes signs as the Keystore does: SHA256withECDSA in DER. The Go test checks the same form. */
    @Test
    fun signatureForm() {
        val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val der = Signature.getInstance("SHA256withECDSA").run {
            initSign(pair.private)
            update(signature)
            sign()
        }
        assertEquals(0x30, der[0].toInt() and 0xff)
        val p = SshMessage.signed("req1", der)
        assertEquals(Base64.getEncoder().encodeToString(der), p.string("signature"))
        assertEquals("signed", p.string("kind"))
        assertEquals(true, SshMessage.denied("req1").bool("denied"))
        assertEquals("a b", SshMessage.failed("req1", "a\nb").string("error"))
        assertEquals(null, SshMessage.keyPacket(null).string("publicKey"))
        assertEquals(Base64.getEncoder().encodeToString(spki), SshMessage.keyPacket(spki).string("publicKey"))
    }

    private fun sshsig(namespace: String): ByteArray {
        fun str(b: ByteArray) = ByteBuffer.allocate(4).putInt(b.size).array() + b
        return "SSHSIG".toByteArray() + str(namespace.toByteArray()) + str(ByteArray(0)) + str("sha256".toByteArray()) + str(ByteArray(32))
    }

    private fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
