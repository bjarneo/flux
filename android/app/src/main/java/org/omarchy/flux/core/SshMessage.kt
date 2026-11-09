package org.omarchy.flux.core

import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.interfaces.ECPublicKey
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

/** What a sign request asks the SSH key to sign. The phone reads it from the data itself. */
sealed interface SshData {
    /** An SSH login request as [user]. */
    data class Login(val user: String) : SshData

    /** The signed data of an SSH signature, as ssh-keygen -Y sign makes it, for example in the namespace git. */
    data class Signature(val namespace: String) : SshData
}

/** A sign request from a computer for the SSH key of this phone. docs/ssh.md is the design. */
class SshRequest(
    val computerId: String,
    val computerName: String,
    val id: String,
    /** The bytes that the phone signs. */
    val data: ByteArray,
    /** What [data] is. */
    val what: SshData,
    /** The command line of the program on the computer, as fluxd reports it. The program chooses it, so it is only a hint. */
    val program: String,
    val timeoutSeconds: Int,
)

/**
 * The SSH key messages: the key in the SSH format, its fingerprint, the
 * data that the key signs, and the packets. This code has no Android
 * dependency, so the JVM tests check it with the vectors of the Go tests in
 * internal/sshagent.
 */
object SshMessage {
    /** The largest data that the phone signs, in bytes. fluxd uses the same limit. */
    const val MAX_DATA = 8 * 1024

    /** The longest program text that the phone shows, in bytes. */
    const val MAX_PROGRAM = 256

    /** The longest wait of a request in seconds. fluxd waits 30 seconds. */
    const val MAX_TIMEOUT = 60

    private const val KEY_TYPE = "ecdsa-sha2-nistp256"
    private const val CURVE = "nistp256"
    private const val HOST_BOUND = "publickey-hostbound-v00@openssh.com"
    private const val MAX_TEXT = 256

    /** The order of the curve P-256. */
    private val P256_ORDER = BigInteger("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)

    /**
     * Returns the key in the SSH wire format, from the key in DER as Android
     * gives it. It returns null for a key that is not an EC P-256 key.
     */
    fun keyBlob(spki: ByteArray): ByteArray? {
        val key = runCatching {
            KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(spki)) as ECPublicKey
        }.getOrNull() ?: return null
        if (key.params.order != P256_ORDER) return null
        val point = byteArrayOf(4) + fixed(key.w.affineX) + fixed(key.w.affineY)
        return ByteArrayOutputStream().apply {
            writeString(KEY_TYPE.toByteArray())
            writeString(CURVE.toByteArray())
            writeString(point)
        }.toByteArray()
    }

    /** The fingerprint of [blob], as ssh-add -l shows it: SHA256: and the base64 of the hash without padding. */
    fun fingerprint(blob: ByteArray): String =
        "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(blob))

    /** The line of the key for authorized_keys, with [comment] at the end. */
    fun authorizedKey(blob: ByteArray, comment: String): String =
        "$KEY_TYPE ${Base64.getEncoder().encodeToString(blob)} $comment".trim()

    /**
     * Reads [data] for the key [blob]. The phone signs only an SSH login
     * request with this key, and the signed data of an SSH signature. It
     * returns null for each other data, so that the key never signs a
     * message of another protocol. fluxd makes the same check.
     */
    fun parseData(data: ByteArray, blob: ByteArray): SshData? {
        if (data.size > MAX_DATA) return null
        val magic = "SSHSIG".toByteArray()
        return if (data.size >= magic.size && data.copyOf(magic.size).contentEquals(magic)) {
            parseSignature(Reader(data.copyOfRange(magic.size, data.size)))
        } else {
            parseLogin(Reader(data), blob)
        }
    }

    private fun parseSignature(r: Reader): SshData? {
        val namespace = r.text() ?: return null
        r.bytes(1024) ?: return null
        val hash = r.bytes(16)?.let { String(it, Charsets.US_ASCII) } ?: return null
        val digest = r.bytes(64) ?: return null
        val known = (hash == "sha256" && digest.size == 32) || (hash == "sha512" && digest.size == 64)
        if (!r.done() || namespace.isEmpty() || !known) return null
        return SshData.Signature(namespace)
    }

    private fun parseLogin(r: Reader, blob: ByteArray): SshData? {
        val session = r.bytes(64) ?: return null
        val msg = r.byte() ?: return null
        val user = r.text() ?: return null
        val service = r.bytes(64)?.let { String(it, Charsets.US_ASCII) } ?: return null
        val method = r.bytes(64)?.let { String(it, Charsets.US_ASCII) } ?: return null
        val signs = r.byte() ?: return null
        val alg = r.bytes(64)?.let { String(it, Charsets.US_ASCII) } ?: return null
        val key = r.bytes(1024) ?: return null
        if (method == HOST_BOUND) {
            val host = r.bytes(16 * 1024) ?: return null
            if (host.isEmpty()) return null
        } else if (method != "publickey") {
            return null
        }
        val ok = r.done() && session.isNotEmpty() && msg == 50 && signs == 1 && user.isNotEmpty() &&
            service == "ssh-connection" && alg == KEY_TYPE && key.contentEquals(blob)
        return if (ok) SshData.Login(user) else null
    }

    /** True for valid text without a control character or a bidi control. The screen shows such text as it is. */
    fun validText(s: String): Boolean {
        var i = 0
        while (i < s.length) {
            val c = s.codePointAt(i)
            if (Character.isSurrogate(s[i]) && Character.charCount(c) == 1) return false
            if (control(c)) return false
            i += Character.charCount(c)
        }
        return true
    }

    /** Control characters and the marks, embeddings, overrides, and isolates that change the direction of text. Go has the same list in proto.IsControl. */
    private fun control(c: Int): Boolean =
        c < 0x20 || c in 0x7f..0x9f || c == 0x061c || c == 0x200e || c == 0x200f || c in 0x202a..0x202e || c in 0x2066..0x2069

    /**
     * Makes text from the computer safe for the screen: each control
     * character and bidi control becomes a space, the spaces collapse, and
     * the text has at most [max] bytes. A cut text ends with "…".
     */
    fun clean(s: String, max: Int = MAX_PROGRAM): String {
        val sb = StringBuilder()
        var i = 0
        while (i < s.length) {
            val c = s.codePointAt(i)
            val bad = control(c) || (Character.isSurrogate(s[i]) && Character.charCount(c) == 1)
            sb.appendCodePoint(if (bad) ' '.code else c)
            i += Character.charCount(c)
        }
        var text = sb.toString().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
        if (text.toByteArray(Charsets.UTF_8).size <= max) return text
        while (text.toByteArray(Charsets.UTF_8).size > max - 3) text = text.dropLast(1)
        if (text.isNotEmpty() && Character.isHighSurrogate(text.last())) text = text.dropLast(1)
        return "$text…"
    }

    /** The result of [parse]: a request to show, or the error that goes back to the computer. */
    sealed interface Parsed {
        data class Ok(val request: SshRequest) : Parsed

        data class Refused(val id: String, val message: String) : Parsed

        /** A packet without a valid ID. The phone cannot answer it. */
        data object Invalid : Parsed
    }

    /**
     * Reads a sign request for the key [ownSpki] of this phone, or null when
     * the phone has no key. The request names the key that the computer
     * listed, and the phone refuses it when its key differs.
     */
    fun parse(p: Packet, computerId: String, computerName: String, ownSpki: ByteArray?): Parsed {
        val id = p.string("id")?.takeIf { it.isNotEmpty() && it.length <= 64 && validText(it) } ?: return Parsed.Invalid
        val data = p.string("data")?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
        if (data == null || data.isEmpty() || data.size > MAX_DATA) return Parsed.Refused(id, "The request is not valid")
        if (ownSpki == null) return Parsed.Refused(id, "SSH key is off on this phone")
        val asked = p.string("key")?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
        if (asked == null || !asked.contentEquals(ownSpki)) {
            return Parsed.Refused(id, "This phone has another SSH key now. Run flux-cli ssh to see it")
        }
        val blob = keyBlob(ownSpki) ?: return Parsed.Refused(id, "The SSH key of this phone is not an EC P-256 key")
        val what = parseData(data, blob)
            ?: return Parsed.Refused(id, "The data is not an SSH login and not an SSH signature, so the phone does not sign it")
        val timeout = (p.int("timeout") ?: 30).coerceIn(1, MAX_TIMEOUT)
        val program = clean(p.string("program") ?: "")
        return Parsed.Ok(SshRequest(computerId, computerName, id, data, what, program, timeout))
    }

    /** What the request does, for example "Log in as git" or "Sign a Git commit or tag". */
    fun action(what: SshData): String = when (what) {
        is SshData.Login -> "Log in as ${what.user}"
        is SshData.Signature -> when (what.namespace) {
            "git" -> "Sign a Git commit or tag"
            "file" -> "Sign a file"
            else -> "Sign in the namespace ${what.namespace}"
        }
    }

    /** The question on the phone, for example "Log in as git with the SSH key of this phone?". */
    fun question(r: SshRequest): String = "${action(r.what)} with the SSH key of this phone?"

    /** The key of this phone, or no key when [spki] is null. */
    fun keyPacket(spki: ByteArray?): Packet = Packet(
        Types.FLUX_SSH,
        if (spki == null) bodyOf("kind" to "key") else bodyOf("kind" to "key", "publicKey" to Base64.getEncoder().encodeToString(spki)),
    )

    fun signed(id: String, der: ByteArray): Packet =
        Packet(Types.FLUX_SSH, bodyOf("kind" to "signed", "id" to id, "signature" to Base64.getEncoder().encodeToString(der)))

    fun denied(id: String): Packet = Packet(Types.FLUX_SSH, bodyOf("kind" to "signed", "id" to id, "denied" to true))

    fun failed(id: String, message: String): Packet =
        Packet(Types.FLUX_SSH, bodyOf("kind" to "signed", "id" to id, "error" to clean(message, 200)))

    private fun fixed(v: BigInteger): ByteArray {
        val b = v.toByteArray()
        return when {
            b.size == 32 -> b
            b.size > 32 -> b.copyOfRange(b.size - 32, b.size)
            else -> ByteArray(32 - b.size) + b
        }
    }

    private fun ByteArrayOutputStream.writeString(b: ByteArray) {
        write(ByteBuffer.allocate(4).putInt(b.size).array())
        write(b)
    }

    /** Reads the SSH wire format. Each read returns null at the end of the data or for a length that does not fit. */
    private class Reader(private val b: ByteArray) {
        private var at = 0

        fun done() = at == b.size

        fun byte(): Int? = if (at < b.size) b[at++].toInt() and 0xff else null

        fun bytes(max: Int): ByteArray? {
            if (b.size - at < 4) return null
            val n = ByteBuffer.wrap(b, at, 4).int.toLong() and 0xffffffffL
            if (n > max || n > b.size - at - 4) return null
            val out = b.copyOfRange(at + 4, at + 4 + n.toInt())
            at += 4 + n.toInt()
            return out
        }

        /** A string of at most 256 bytes of valid UTF-8 without a control character. */
        fun text(): String? {
            val raw = bytes(MAX_TEXT) ?: return null
            val s = try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(raw)).toString()
            } catch (e: CharacterCodingException) {
                return null
            }
            return s.takeIf(::validText)
        }
    }
}
