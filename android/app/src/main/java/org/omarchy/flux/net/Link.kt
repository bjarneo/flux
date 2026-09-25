package org.omarchy.flux.net

import android.util.Log
import org.omarchy.flux.protocol.Identity
import org.omarchy.flux.protocol.Packet
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.security.cert.X509Certificate
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLSocket

private const val TAG = "FluxLink"

/** The largest packet line that Flux reads. */
const val MAX_LINE = 16 * 1024 * 1024

/** An open TLS link to one device. */
class Link(
    private val socket: SSLSocket,
    val identity: Identity,
    val peerCertificate: X509Certificate,
) {
    val address: InetAddress get() = socket.inetAddress
    private val writer = Executors.newSingleThreadExecutor { Thread(it, "flux-write-${identity.deviceName}") }
    private val closed = AtomicBoolean(false)
    private var onClose: (() -> Unit)? = null

    /** Starts the read loop. [onPacket] runs on the reader thread. */
    fun start(onPacket: (Packet) -> Unit, onClose: () -> Unit) {
        this.onClose = onClose
        Thread({
            try {
                val input = socket.inputStream.buffered(65536)
                while (!closed.get()) {
                    val line = readLine(input) ?: break
                    if (line.isBlank()) continue
                    val p = Packet.parse(line) ?: continue
                    runCatching { onPacket(p) }.onFailure { Log.w(TAG, "packet ${p.type} failed", it) }
                }
            } catch (e: Exception) {
                if (!closed.get()) Log.i(TAG, "link to ${identity.deviceName} ended: ${e.message}")
            } finally {
                close()
            }
        }, "flux-read-${identity.deviceName}").apply { isDaemon = true }.start()
    }

    /** Sends a packet. The write happens on the writer thread. */
    fun send(p: Packet) {
        if (closed.get()) return
        writer.execute {
            try {
                val out: OutputStream = socket.outputStream
                out.write(p.serialize().toByteArray())
                out.flush()
            } catch (e: Exception) {
                Log.i(TAG, "write to ${identity.deviceName} failed: ${e.message}")
                close()
            }
        }
    }

    val isOpen: Boolean get() = !closed.get()

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { socket.close() }
        writer.shutdown()
        onClose?.invoke()
    }
}

/**
 * Reads one line from the stream, 1 byte at a time. On a raw socket before
 * TLS, this does not consume the bytes of the TLS handshake.
 */
fun readLine(input: InputStream, max: Int = MAX_LINE): String? {
    val buf = java.io.ByteArrayOutputStream(256)
    while (true) {
        val b = input.read()
        if (b < 0) return if (buf.size() == 0) null else buf.toString(Charsets.UTF_8.name())
        if (b == '\n'.code) return buf.toString(Charsets.UTF_8.name())
        buf.write(b)
        if (buf.size() > max) throw java.io.IOException("packet too large")
    }
}
