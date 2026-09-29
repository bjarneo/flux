package org.omarchy.flux.net

import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.TunnelPackets
import java.io.OutputStream
import java.net.InetAddress
import java.net.Socket
import java.security.cert.X509Certificate
import javax.net.SocketFactory
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
     * [announce], and waits for the computer. The computer must connect
     * from [peer], the address of its link, and present [expected]. Other
     * connections close, and the wait goes on until [timeoutMs]. The
     * function returns the TLS socket after the handshake.
     */
    fun accept(
        tls: Tls,
        expected: X509Certificate,
        token: String,
        announce: (Packet) -> Unit,
        timeoutMs: Int = TUNNEL_TIMEOUT_MS,
        peer: InetAddress? = Link.addressOf(expected),
    ): SSLSocket {
        val server = try {
            Payload.openServer()
        } catch (e: Exception) {
            announce(TunnelPackets.failed(token, e.message ?: "no free port"))
            throw e
        }
        server.use { srv ->
            announce(TunnelPackets.ready(token, srv.localPort))
            return Payload.acceptPinned(srv, tls, expected, peer, timeoutMs)
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
 * Gives a library that opens its own connection a socket that is already
 * connected, for example a Flux tunnel. The library skips its own connect,
 * so no other app on the phone can take the connection.
 */
class ConnectedSocketFactory(private val socket: Socket) : SocketFactory() {
    override fun createSocket(): Socket = socket
    override fun createSocket(host: String?, port: Int): Socket = socket
    override fun createSocket(host: String?, port: Int, localHost: InetAddress?, localPort: Int): Socket = socket
    override fun createSocket(host: InetAddress?, port: Int): Socket = socket
    override fun createSocket(address: InetAddress?, port: Int, localAddress: InetAddress?, localPort: Int): Socket = socket
}
