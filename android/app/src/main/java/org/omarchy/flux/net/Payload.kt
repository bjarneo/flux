package org.omarchy.flux.net

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.security.cert.X509Certificate
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLSocket
import kotlin.random.Random

/** The TCP port range for payload servers. */
val PAYLOAD_PORTS = 1739..1764

/** The longest TLS handshake on a payload port. */
private const val PAYLOAD_HANDSHAKE_MS = 10_000

/** A payload listener got connections, but none from the paired computer. */
class WrongPeerException : IOException("the connection did not come from the paired computer")

/**
 * Payload transfer from this phone. The phone listens on a port and is the
 * TLS server. The computer connects and is the TLS client. A payload from
 * the computer comes through a [Tunnel].
 */
object Payload {
    private val timer = Executors.newSingleThreadScheduledExecutor { Thread(it, "flux-payload-timer").apply { isDaemon = true } }

    /**
     * Opens a listener on a free port in the payload range. The search
     * starts at a random port, so that the next port is harder to guess.
     */
    fun openServer(): ServerSocket {
        val size = PAYLOAD_PORTS.last - PAYLOAD_PORTS.first + 1
        val start = Random.nextInt(size)
        for (i in 0 until size) {
            val port = PAYLOAD_PORTS.first + (start + i) % size
            try {
                return ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress(port))
                    soTimeout = 60_000
                }
            } catch (_: Exception) {
            }
        }
        error("no free payload port in $PAYLOAD_PORTS")
    }

    /**
     * Waits for the receiver on [server] and writes [size] bytes from
     * [input]. The receiver must present [expected] and connect from
     * [peer], the address of its link. The wait lasts as long as the
     * timeout of [server].
     */
    fun send(
        tls: Tls,
        server: ServerSocket,
        input: InputStream,
        size: Long,
        expected: X509Certificate,
        progress: (Long) -> Unit = {},
        peer: InetAddress? = Link.addressOf(expected),
    ) {
        server.use { srv ->
            acceptPinned(srv, tls, expected, peer, srv.soTimeout.takeIf { it > 0 } ?: 60_000).use { ssl ->
                copy(input, ssl.outputStream, size, progress)
                ssl.outputStream.flush()
            }
        }
    }

    /**
     * Accepts connections on [server] until one comes from [peer] and
     * presents [expected], or until [timeoutMs] passes. A connection from
     * another address closes before the TLS handshake, and a connection with
     * another certificate closes after it. So a stranger on the network
     * cannot take the place of the computer. With a null [peer], any
     * address can connect. It throws [SocketTimeoutException] when nobody
     * connected, and [WrongPeerException] when only other peers connected.
     */
    fun acceptPinned(server: ServerSocket, tls: Tls, expected: X509Certificate, peer: InetAddress?, timeoutMs: Int): SSLSocket {
        val der = expected.encoded
        val end = System.nanoTime() + timeoutMs * 1_000_000L
        var refused = 0
        while (true) {
            val left = ((end - System.nanoTime()) / 1_000_000).toInt()
            if (left <= 0) throw if (refused > 0) WrongPeerException() else SocketTimeoutException("nobody connected")
            server.soTimeout = left
            val raw = try {
                server.accept()
            } catch (_: SocketTimeoutException) {
                continue
            }
            if (peer != null && !samePeer(raw.inetAddress, peer)) {
                refused++
                runCatching { raw.close() }
                continue
            }
            keepAlive(raw)
            // A peer that stalls the handshake loses its connection at the deadline.
            val stop = timer.schedule({ runCatching { raw.close() } }, minOf(left, PAYLOAD_HANDSHAKE_MS).toLong(), TimeUnit.MILLISECONDS)
            val ssl = try {
                tls.wrap(raw, server = true)
            } catch (_: Exception) {
                refused++
                runCatching { raw.close() }
                continue
            } finally {
                stop.cancel(false)
            }
            val cert = Tls.peerCertificate(ssl)
            if (cert == null || !cert.encoded.contentEquals(der)) {
                refused++
                runCatching { ssl.close() }
                continue
            }
            return ssl
        }
    }

    internal fun copy(input: InputStream, output: OutputStream, size: Long, progress: (Long) -> Unit) {
        val buf = ByteArray(64 * 1024)
        var done = 0L
        var lastReport = 0L
        while (size < 0 || done < size) {
            val want = if (size < 0) buf.size else minOf(buf.size.toLong(), size - done).toInt()
            val n = input.read(buf, 0, want)
            if (n < 0) break
            output.write(buf, 0, n)
            done += n
            if (done - lastReport > 256 * 1024) {
                lastReport = done
                progress(done)
            }
        }
        progress(done)
        if (size >= 0 && done < size) error("payload ended at $done of $size bytes")
    }
}
