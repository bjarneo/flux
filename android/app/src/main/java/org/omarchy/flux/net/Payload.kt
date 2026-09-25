package org.omarchy.flux.net

import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.cert.X509Certificate

/** The TCP port range for payload servers. */
val PAYLOAD_PORTS = 1739..1764

/**
 * Payload transfer. The sender listens on a port and is the TLS server. The
 * receiver connects and is the TLS client.
 */
object Payload {
    /** Opens a listener on the first free port in the payload range. */
    fun openServer(): ServerSocket {
        for (port in PAYLOAD_PORTS) {
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
     * [input]. The receiver must present [expected].
     */
    fun send(
        tls: Tls,
        server: ServerSocket,
        input: InputStream,
        size: Long,
        expected: X509Certificate,
        progress: (Long) -> Unit = {},
    ) {
        server.use { srv ->
            val socket = srv.accept()
            val ssl = tls.wrap(socket, server = true)
            ssl.use {
                val cert = Tls.peerCertificate(ssl)
                if (cert == null || !cert.encoded.contentEquals(expected.encoded)) error("payload peer is not the paired device")
                copy(input, ssl.outputStream, size, progress)
                ssl.outputStream.flush()
            }
        }
    }

    /** Connects to the sender and writes the payload into [output]. */
    fun receive(
        tls: Tls,
        address: InetAddress,
        port: Int,
        size: Long,
        output: OutputStream,
        progress: (Long) -> Unit = {},
    ) {
        val socket = Socket()
        socket.connect(InetSocketAddress(address, port), 10_000)
        val ssl = tls.wrap(socket, server = false)
        ssl.use { copy(it.inputStream, output, size, progress) }
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
