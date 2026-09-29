package org.omarchy.flux.core

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.FileProvider
import org.omarchy.flux.net.Payload
import org.omarchy.flux.net.Tls
import org.omarchy.flux.net.Tunnel
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.TunnelPackets
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.cert.X509Certificate

private const val TAG = "FluxClipImage"

/**
 * Images on the clipboard: flux.clipboard.image. The payload is a PNG,
 * JPEG, GIF, or WebP image, and the body names its MIME type. A received
 * image lives in the cache folder, and the clipboard holds its address.
 */
object ClipImage {
    /** The largest image that Flux syncs. fluxd uses the same limit. */
    const val MAX_BYTES = 16L shl 20

    /** The image types that Flux syncs. */
    val TYPES = listOf("image/png", "image/jpeg", "image/gif", "image/webp")

    /** The cache folder of received images. res/xml/clipboard_paths.xml shares it. */
    private const val DIR = "clipboard"

    /** The last image that a computer put on the clipboard. Flux does not send it back. */
    @Volatile var lastRemote: Uri? = null

    private val main by lazy { Handler(Looper.getMainLooper()) }

    /** Returns the first type in [types] that Flux syncs, or null. */
    fun pickType(types: List<String?>): String? = types.firstOrNull { it in TYPES }

    /** Returns the file name extension for an image type. */
    fun extension(mime: String): String = when (mime) {
        "image/jpeg" -> "jpg"
        "image/gif" -> "gif"
        "image/webp" -> "webp"
        else -> "png"
    }

    /**
     * Handles an image from a computer. The core lock is held, so the
     * transfer runs on the IO pool.
     */
    fun receive(core: FluxCore, d: Device, p: Packet) {
        val token = p.payloadTunnel ?: return
        val size = p.payloadSize
        if (!core.settings.syncClipboard || size <= 0 || size > MAX_BYTES) {
            d.send(TunnelPackets.failed(token, "the phone does not accept this clipboard image"))
            return
        }
        val mime = p.string("mime")?.takeIf { it in TYPES } ?: "image/png"
        val cert = d.certificate ?: return
        val tls = FluxCore.tls ?: return
        core.io.execute { download(core, d, p, token, cert, tls, mime) }
    }

    private fun download(core: FluxCore, d: Device, p: Packet, token: String, cert: X509Certificate, tls: Tls, mime: String) {
        val dir = File(core.app.cacheDir, DIR).apply { mkdirs() }
        val file = File(dir, "clip-${System.currentTimeMillis()}.${extension(mime)}")
        val ok = runCatching {
            file.outputStream().use { out -> Tunnel.receive(tls, cert, token, p.payloadSize, out, announce = { d.send(it) }) }
        }.onFailure { Log.w(TAG, "receive from ${d.identity.deviceName} failed", it) }.isSuccess
        if (!ok) {
            file.delete()
            return
        }
        // The clipboard holds 1 image, so the older files can go.
        dir.listFiles()?.filter { it != file }?.forEach { it.delete() }
        val uri = FileProvider.getUriForFile(core.app, authority(core.app), file)
        lastRemote = uri
        main.post { Android.setClipboardImage(core.app, uri) }
    }

    private fun authority(context: Context) = "${context.packageName}.clipboard"

    /**
     * Sends the image at [uri] to each device in [devices]. [onDone] runs
     * on an IO thread with the number of devices that got the image, or -1
     * when the image is larger than [MAX_BYTES].
     */
    fun send(core: FluxCore, devices: List<Device>, uri: Uri, mime: String, onDone: (Int) -> Unit = {}) {
        core.io.execute {
            val read = runCatching { read(core.app, uri) }
            val data = read.getOrElse {
                Log.w(TAG, "read $uri failed", it)
                onDone(if (it is TooLarge) -1 else 0)
                return@execute
            }
            var sent = 0
            for (d in devices) {
                runCatching { sendTo(d, data, mime) }
                    .onSuccess { sent++ }
                    .onFailure { Log.w(TAG, "send to ${d.identity.deviceName} failed", it) }
            }
            onDone(sent)
        }
    }

    private class TooLarge : Exception("the image is larger than ${MAX_BYTES shr 20} MiB")

    /** Reads an image. It throws [TooLarge] for an image larger than [MAX_BYTES]. */
    private fun read(context: Context, uri: Uri): ByteArray {
        val input = context.contentResolver.openInputStream(uri) ?: error("cannot open $uri")
        input.use {
            val out = ByteArrayOutputStream()
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = it.read(buf)
                if (n < 0) break
                if (out.size() + n > MAX_BYTES) throw TooLarge()
                out.write(buf, 0, n)
            }
            return out.toByteArray()
        }
    }

    private fun sendTo(d: Device, data: ByteArray, mime: String) {
        val cert = d.certificate ?: error("not paired")
        val tls = FluxCore.tls ?: error("no TLS")
        val server = Payload.openServer()
        val p = Packet(Types.FLUX_CLIPBOARD_IMAGE, bodyOf("mime" to mime), payloadSize = data.size.toLong(), payloadPort = server.localPort)
        if (!d.send(p)) {
            server.close()
            error("Not connected")
        }
        Payload.send(tls, server, data.inputStream(), data.size.toLong(), cert)
    }
}
