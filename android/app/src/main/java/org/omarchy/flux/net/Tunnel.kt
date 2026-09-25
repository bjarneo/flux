package org.omarchy.flux.net

import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.TunnelPackets
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.cert.X509Certificate
import javax.net.ssl.SSLSocket

/** How long a tunnel listener waits for the computer. */
const val TUNNEL_TIMEOUT_MS = 30_000

/**
 * The phone side of a Flux tunnel. The phone listens on a payload port, and
 * the computer connects as the TLS client.
 */
object Tunnel {
    /**
     * Opens a listener for [token], sends flux.tunnel with its port through
     * [announce], and waits for 1 connection. The peer must present
     * [expected]. The function returns the TLS socket after the handshake.
     */
    fun accept(
        tls: Tls,
        expected: X509Certificate,
        token: String,
        announce: (Packet) -> Unit,
        timeoutMs: Int = TUNNEL_TIMEOUT_MS,
    ): SSLSocket {
        val server = try {
            Payload.openServer()
        } catch (e: Exception) {
            announce(TunnelPackets.failed(token, e.message ?: "no free port"))
            throw e
        }
        server.use { srv ->
            srv.soTimeout = timeoutMs
            announce(TunnelPackets.ready(token, srv.localPort))
            val socket = srv.accept()
            val ssl = try {
                tls.wrap(socket, server = true)
            } catch (e: Exception) {
                runCatching { socket.close() }
                throw e
            }
            val cert = Tls.peerCertificate(ssl)
            if (cert == null || !cert.encoded.contentEquals(expected.encoded)) {
                runCatching { ssl.close() }
                error("tunnel peer is not the paired device")
            }
            return ssl
        }
    }

    /** Receives a payload of [size] bytes through a tunnel into [output]. */
    fun receive(
        tls: Tls,
        expected: X509Certificate,
        token: String,
        size: Long,
        output: OutputStream,
        announce: (Packet) -> Unit,
        progress: (Long) -> Unit = {},
    ) {
        accept(tls, expected, token, announce).use { Payload.copy(it.inputStream, output, size, progress) }
    }
}

/**
 * Bridges a connected socket to a new listener on 127.0.0.1, so that a
 * library that opens its own TCP connection can use the socket. The bridge
 * accepts 1 connection and closes when either side closes.
 */
class LoopbackBridge(private val remote: Socket) : AutoCloseable {
    // Android returns ::1 for getLoopbackAddress, so name the IPv4 address.
    private val server = ServerSocket().apply {
        bind(InetSocketAddress(LOOPBACK, 0), 1)
        soTimeout = 10_000
    }
    val host: String get() = LOOPBACK.hostAddress!!
    val port: Int get() = server.localPort
    @Volatile private var local: Socket? = null

    init {
        Thread({
            try {
                val s = server.accept()
                local = s
                runCatching { server.close() }
                s.tcpNoDelay = true
                val up = Thread({ pipe(s.getInputStream(), remote.getOutputStream()) }, "flux-bridge-up").apply { isDaemon = true }
                up.start()
                pipe(remote.getInputStream(), s.getOutputStream())
                up.join()
            } catch (_: Exception) {
            } finally {
                close()
            }
        }, "flux-bridge").apply { isDaemon = true }.start()
    }

    private fun pipe(input: InputStream, output: OutputStream) {
        val buf = ByteArray(32 * 1024)
        try {
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                output.write(buf, 0, n)
                output.flush()
            }
        } catch (_: Exception) {
        } finally {
            // One direction ended. Close both sides so that the other pipe ends too.
            close()
        }
    }

    companion object {
        private val LOOPBACK: InetAddress = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
    }

    override fun close() {
        runCatching { server.close() }
        runCatching { local?.close() }
        runCatching { remote.close() }
    }
}
