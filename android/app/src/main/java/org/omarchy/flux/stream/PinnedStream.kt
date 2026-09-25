package org.omarchy.flux.stream

import org.omarchy.flux.core.Device
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.net.Payload
import org.omarchy.flux.net.Tls
import org.omarchy.flux.protocol.Packet
import java.net.ServerSocket
import java.net.SocketTimeoutException
import javax.net.ssl.SSLSocket

/**
 * The phone side of a stream to the computer, as for the webcam. The phone
 * listens, tells the computer the port, and accepts 1 TLS connection from
 * the paired computer. The computer connects out, so the stream passes a
 * firewall that blocks incoming traffic on the computer.
 */
object PinnedStream {
    /**
     * Opens a listener, sends the packet that [announce] makes with the port,
     * and waits up to [timeoutMs] for [d]. [onServer] gets the listener, so
     * that a stop can close it. The connection must use the certificate of
     * the paired computer. The errors have messages that the UI can show.
     */
    fun accept(core: FluxCore, d: Device, timeoutMs: Int, onServer: (ServerSocket) -> Unit, announce: (port: Int) -> Packet): SSLSocket {
        val name = d.identity.deviceName
        val cert = d.certificate ?: error("$name is not connected")
        val tls = core.tls ?: error("The network is not ready")
        val srv = Payload.openServer()
        srv.soTimeout = timeoutMs
        onServer(srv)
        try {
            if (!d.send(announce(srv.localPort))) error("Not connected to $name")
            val raw = try {
                srv.accept()
            } catch (e: SocketTimeoutException) {
                error("$name did not connect. Update Flux on the computer.")
            }
            raw.tcpNoDelay = true
            val ssl = tls.wrap(raw, server = true)
            val peer = Tls.peerCertificate(ssl)
            if (peer == null || !peer.encoded.contentEquals(cert.encoded)) {
                runCatching { ssl.close() }
                error("The connection did not come from $name")
            }
            return ssl
        } finally {
            runCatching { srv.close() }
        }
    }
}
