package org.omarchy.flux.core

import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.security.MessageDigest
import java.util.Base64

/**
 * A request from a computer: approve a login with a fingerprint, or make
 * the key for approvals. docs/approve.md is the security design.
 */
data class ApproveRequest(
    val computerId: String,
    val computerName: String,
    val id: String,
    val kind: Kind,
    val host: String,
    val user: String,
    val service: String,
    val tty: String,
    val rhost: String,
    /** The Unix time in seconds when the computer made the request. */
    val time: Long,
    /** 32 random bytes as 64 lowercase hex digits. */
    val nonce: String,
    val timeoutSeconds: Int,
) {
    enum class Kind { Approve, Enroll }
}

/**
 * The signed messages and the packets of approvals. This code has no
 * Android dependency, so the JVM tests check that it builds the same bytes
 * as the Go helper.
 */
object ApproveMessage {
    private const val MAX_FIELD = 256

    /** How far the time of a request can be from the phone clock. */
    const val MAX_SKEW_SECONDS = 600L

    /** Valid UTF-8, at most 256 bytes, and no control character. */
    fun validField(v: String): Boolean {
        val bytes = v.toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_FIELD || String(bytes, Charsets.UTF_8) != v) return false
        var i = 0
        while (i < v.length) {
            val c = v.codePointAt(i)
            if (c < 0x20 || c == 0x7f || c in 0x80..0x9f) return false
            i += Character.charCount(c)
        }
        return true
    }

    fun validNonce(n: String): Boolean = n.length == 64 && n.all { it in '0'..'9' || it in 'a'..'f' }

    /** The exact bytes that the phone signs to approve [r]. */
    fun approval(r: ApproveRequest): ByteArray = buildString {
        append("flux-approve-v1\n")
        append("host=").append(r.host).append('\n')
        append("user=").append(r.user).append('\n')
        append("service=").append(r.service).append('\n')
        append("tty=").append(r.tty).append('\n')
        append("rhost=").append(r.rhost).append('\n')
        append("time=").append(r.time).append('\n')
        append("nonce=").append(r.nonce).append('\n')
    }.toByteArray(Charsets.UTF_8)

    /** The exact bytes that the new key signs to prove that the phone holds it. */
    fun enrollment(r: ApproveRequest, spki: ByteArray): ByteArray = buildString {
        append("flux-approve-enroll-v1\n")
        append("host=").append(r.host).append('\n')
        append("user=").append(r.user).append('\n')
        append("key=").append(hex(sha256(spki))).append('\n')
        append("time=").append(r.time).append('\n')
        append("nonce=").append(r.nonce).append('\n')
    }.toByteArray(Charsets.UTF_8)

    /**
     * The key code that the phone and the terminal show: the first 8 bytes
     * of the SHA-256 of the key in DER, as 4 groups of 4 hex digits.
     */
    fun fingerprint(spki: ByteArray): String =
        hex(sha256(spki).copyOf(8)).uppercase().chunked(4).joinToString(" ")

    /** Reads a request or an enrollment. It returns null for a packet that breaks a rule. */
    fun parse(p: Packet, computerId: String, computerName: String): ApproveRequest? {
        val kind = when (p.string("kind")) {
            "request" -> ApproveRequest.Kind.Approve
            "enroll" -> ApproveRequest.Kind.Enroll
            else -> return null
        }
        val id = p.string("id")?.takeIf { it.isNotEmpty() && it.length <= 64 && validField(it) } ?: return null
        val r = ApproveRequest(
            computerId = computerId,
            computerName = computerName,
            id = id,
            kind = kind,
            host = p.string("host") ?: return null,
            user = p.string("user") ?: return null,
            service = if (kind == ApproveRequest.Kind.Approve) p.string("service") ?: return null else "",
            tty = p.string("tty") ?: "",
            rhost = p.string("rhost") ?: "",
            time = p.long("time") ?: return null,
            nonce = p.string("nonce") ?: return null,
            timeoutSeconds = (p.int("timeout") ?: 20).coerceIn(5, 120),
        )
        val fields = listOf(r.host, r.user, r.service, r.tty, r.rhost)
        if (!fields.all(::validField) || r.host.isEmpty() || r.user.isEmpty() || !validNonce(r.nonce)) return null
        if (kind == ApproveRequest.Kind.Approve && r.service.isEmpty()) return null
        return r
    }

    /** Reports whether the time of [r] is within 10 minutes of the phone clock. */
    fun fresh(r: ApproveRequest, nowSeconds: Long): Boolean = kotlin.math.abs(nowSeconds - r.time) <= MAX_SKEW_SECONDS

    /** The question on the phone, for example "Approve sudo for user alice on host omarchy-xps?". */
    fun question(r: ApproveRequest): String = when (r.kind) {
        ApproveRequest.Kind.Approve -> "Approve ${r.service} for user ${r.user} on host ${r.host}?"
        ApproveRequest.Kind.Enroll -> "Use this phone to approve sudo for user ${r.user} on host ${r.host}?"
    }

    fun approved(id: String, signature: ByteArray): Packet =
        Packet(Types.FLUX_APPROVE, bodyOf("kind" to "response", "id" to id, "signature" to b64(signature)))

    fun denied(id: String): Packet = Packet(Types.FLUX_APPROVE, bodyOf("kind" to "response", "id" to id, "denied" to true))

    fun failed(id: String, message: String): Packet =
        Packet(Types.FLUX_APPROVE, bodyOf("kind" to "response", "id" to id, "error" to message.take(200)))

    fun enrolled(id: String, spki: ByteArray, signature: ByteArray): Packet =
        Packet(Types.FLUX_APPROVE, bodyOf("kind" to "enrolled", "id" to id, "publicKey" to b64(spki), "signature" to b64(signature)))

    private fun b64(b: ByteArray): String = Base64.getEncoder().encodeToString(b)

    private fun sha256(b: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(b)

    private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }
}
