package org.omarchy.flux.net

import android.util.Log
import org.omarchy.flux.protocol.Identity
import org.omarchy.flux.protocol.Packet
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.security.cert.X509Certificate
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLSocket

private const val TAG = "FluxLink"

/** The largest packet line that Flux reads from a paired device. */
const val MAX_LINE = 16 * 1024 * 1024

/**
 * The largest packet line that Flux reads from a device that is not paired.
 * Only identity and pair packets come before pairing, and they are small.
 */
const val MAX_UNPAIRED_LINE = 64 * 1024

/** How long the link of a device that is not paired can stay silent before the link asks whether to close. */
const val UNPAIRED_IDLE_MS = 120_000

/**
 * The most packets that wait for the writer. When a peer stops reading for
 * so long that the queue fills, the link closes.
 */
private const val MAX_QUEUED_PACKETS = 2048

/** An open TLS link to one device. */
class Link(
    private val socket: SSLSocket,
    val identity: Identity,
    val peerCertificate: X509Certificate,
) {
    val address: InetAddress get() = socket.inetAddress
    private val writer = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, LinkedBlockingQueue(MAX_QUEUED_PACKETS)) {
        Thread(it, "flux-write-${identity.deviceName}").apply { isDaemon = true }
    }
    private val closed = AtomicBoolean(false)
    private var onClose: (() -> Unit)? = null

    /**
     * True while the device of the link is paired. Before pairing, the link
     * reads lines of at most [MAX_UNPAIRED_LINE], and it has a read timeout
     * of [UNPAIRED_IDLE_MS]. The core sets it from the pair state.
     */
    @Volatile var paired = false
        set(value) {
            field = value
            runCatching { socket.soTimeout = if (value) 0 else UNPAIRED_IDLE_MS }
        }

    /**
     * Starts the read loop. [onPacket] runs on the reader thread. When an
     * unpaired link is silent for [UNPAIRED_IDLE_MS], the link closes if
     * [idleClose] returns true, for example when no pairing is open.
     */
    fun start(onPacket: (Packet) -> Unit, onClose: () -> Unit, idleClose: () -> Boolean = { true }) {
        this.onClose = onClose
        open += this
        Thread({
            try {
                val reader = LineReader(socket.inputStream.buffered(65536))
                while (!closed.get()) {
                    val line = try {
                        reader.next { if (paired) MAX_LINE else MAX_UNPAIRED_LINE }
                    } catch (e: SocketTimeoutException) {
                        // Only an unpaired link has a read timeout.
                        if (!paired && idleClose()) {
                            Log.i(TAG, "${identity.deviceName} did not pair. The link closes.")
                            break
                        }
                        continue
                    } ?: break
                    if (line.isBlank()) continue
                    val p = Packet.parse(line) ?: continue
                    runCatching { onPacket(p) }.onFailure { Log.w(TAG, "packet ${p.type} failed", it) }
                }
            } catch (e: Throwable) {
                // Any error ends only this link, also an OutOfMemoryError
                // from a large line, so that the reader thread does not stop the app.
                if (!closed.get()) Log.i(TAG, "link to ${identity.deviceName} ended: $e")
            } finally {
                close()
            }
        }, "flux-read-${identity.deviceName}").apply { isDaemon = true }.start()
    }

    /** Sends a packet. The write happens on the writer thread. */
    fun send(p: Packet) {
        if (closed.get()) return
        try {
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
        } catch (_: RejectedExecutionException) {
            // The link closed during the send, or the peer does not read and the queue is full.
            if (!closed.get()) {
                Log.i(TAG, "${identity.deviceName} does not read. The link closes.")
                close()
            }
        }
    }

    val isOpen: Boolean get() = !closed.get()

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        open -= this
        runCatching { socket.close() }
        writer.shutdown()
        onClose?.invoke()
    }

    companion object {
        /** The links that [start] opened and that did not close. */
        private val open = CopyOnWriteArraySet<Link>()

        /**
         * Returns the address of an open link that presents [cert], or null.
         * A payload listener takes connections only from this address.
         */
        fun addressOf(cert: X509Certificate): InetAddress? {
            val der = cert.encoded
            return open.firstOrNull { it.isOpen && it.peerCertificate.encoded.contentEquals(der) }?.address
        }
    }
}

/**
 * Reads lines from a stream, 1 byte at a time. On a raw socket before TLS,
 * this does not consume the bytes of the TLS handshake. A read timeout
 * keeps the bytes of the line so far, so the next call continues the line.
 */
class LineReader(private val input: InputStream) {
    private val buf = ByteArrayOutputStream(256)

    /**
     * Returns the next line, or null at the end of the stream. [limit] gives
     * the longest line. The reader asks it again when a line passes the
     * last value, because the limit can grow while the line comes.
     */
    fun next(limit: () -> Int): String? {
        var max = limit()
        while (true) {
            val b = input.read()
            if (b < 0) return if (buf.size() == 0) null else take()
            if (b == '\n'.code) return take()
            buf.write(b)
            if (buf.size() > max) {
                max = limit()
                if (buf.size() > max) {
                    buf.reset()
                    throw IOException("packet too large")
                }
            }
        }
    }

    private fun take(): String {
        val line = buf.toString(Charsets.UTF_8.name())
        buf.reset()
        return line
    }
}

/** Reads one line of at most [max] bytes. See [LineReader]. */
fun readLine(input: InputStream, max: Int = MAX_LINE): String? = LineReader(input).next { max }
