package org.omarchy.flux.core

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import org.omarchy.flux.net.Payload
import org.omarchy.flux.net.Tunnel
import org.omarchy.flux.protocol.TunnelPackets
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.net.InetAddress

private const val TAG = "FluxShare"

/** File, text, and link sharing: kdeconnect.share.request. */
object Share {
    /** Handles a share packet. The core lock is held, so the transfer runs on the IO pool. */
    fun receive(core: FluxCore, d: Device, p: Packet) {
        val from = d.identity.deviceName
        p.string("text")?.let { text ->
            Plugins.lastRemoteClip = text
            android.os.Handler(android.os.Looper.getMainLooper()).post { Android.setClipboard(core.app, text) }
            core.toast("Text from $from is on the clipboard")
            return
        }
        p.string("url")?.let { url ->
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            Android.showEvent(core.app, "Link from $from", url, intent)
            core.toast("Link from $from")
            return
        }
        if (!p.hasPayload) return
        val name = sanitize(p.string("filename") ?: "file-${System.currentTimeMillis()}")
        val address = d.link?.address ?: return
        val cert = d.certificate ?: return
        val tls = currentTls() ?: return
        core.toast("Receiving $name")
        core.io.execute { download(core, d, from, address, cert, p, name, tls) }
    }

    private fun download(
        core: FluxCore,
        d: Device,
        from: String,
        address: InetAddress,
        cert: java.security.cert.X509Certificate,
        p: Packet,
        name: String,
        tls: org.omarchy.flux.net.Tls,
    ) {
        val mime = Android.mimeType(name)
        val token = p.payloadTunnel
        val dl = runCatching { Android.createDownload(core.app, name, mime) }.getOrElse {
            core.toast("Cannot save $name: ${it.message}")
            if (token != null) d.send(TunnelPackets.failed(token, "cannot save the file"))
            return
        }
        val ok = runCatching {
            if (token != null) {
                // The computer blocks incoming connections: listen and let it connect.
                Tunnel.receive(tls, cert, token, p.payloadSize, dl.stream, announce = { d.send(it) })
            } else {
                Payload.receive(tls, address, p.payloadPort, p.payloadSize, dl.stream)
            }
        }
            .onFailure { Log.w(TAG, "receive $name failed", it) }
            .isSuccess
        Android.finishDownload(core.app, dl, ok)
        if (!ok) {
            core.toast("Receiving $name failed")
            return
        }
        val open = Intent(Intent.ACTION_VIEW).setDataAndType(dl.uri, mime ?: "*/*").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        Android.showEvent(core.app, "Received $name", "From $from, saved in Downloads", open)
        core.toast("Saved $name in Downloads")
    }

    /** Sends files to a device, one at a time. */
    fun sendFiles(core: FluxCore, id: String, uris: List<Uri>, onDone: (() -> Unit)? = null) {
        val d = core.device(id)
        val cert = d?.certificate
        val tls = currentTls()
        if (d == null || uris.isEmpty() || cert == null || tls == null) {
            onDone?.invoke()
            return
        }
        core.io.execute {
            try {
                val resolver = core.app.contentResolver
                val files = uris.map { uri ->
                    var name = uri.lastPathSegment ?: "file"
                    var size = -1L
                    resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                        if (c.moveToFirst()) {
                            c.getString(0)?.let { name = it }
                            if (!c.isNull(1)) size = c.getLong(1)
                        }
                    }
                    Triple(uri, name, size)
                }
                val total = files.sumOf { maxOf(it.third, 0L) }
                d.send(Packet(Types.SHARE_UPDATE, bodyOf("numberOfFiles" to files.size, "totalPayloadSize" to total)))
                var sent = 0
                for ((uri, name, size) in files) {
                    val ok = runCatching {
                        // The protocol needs the exact size before the transfer.
                        // A source without a size goes through a cache file.
                        var length = size
                        var temp: java.io.File? = null
                        if (length < 0) {
                            val t = java.io.File.createTempFile("flux-send", null, core.app.cacheDir)
                            resolver.openInputStream(uri)!!.use { src -> t.outputStream().use { src.copyTo(it) } }
                            length = t.length()
                            temp = t
                        }
                        val source = temp?.inputStream() ?: resolver.openInputStream(uri)!!
                        source.use { input ->
                            val server = Payload.openServer()
                            val body = bodyOf(
                                "filename" to name,
                                "open" to false,
                                "numberOfFiles" to files.size,
                                "totalPayloadSize" to total,
                            )
                            d.send(Packet(Types.SHARE, body, payloadSize = length, payloadPort = server.localPort))
                            Payload.send(tls, server, input, length, cert)
                        }
                        temp?.delete()
                    }.onFailure { Log.w(TAG, "send $name failed", it) }.isSuccess
                    if (ok) sent++ else core.toast("Sending $name failed")
                }
                if (sent > 0) core.toast(if (sent == 1) "Sent ${files[0].second}" else "Sent $sent files to ${d.identity.deviceName}")
            } finally {
                onDone?.invoke()
            }
        }
    }

    /**
     * Sends text from Scan text. The `scan` flag tells fluxd that the text
     * comes from the camera. It returns false when the device has no link.
     */
    fun sendScan(core: FluxCore, id: String, text: String): Boolean {
        val d = core.device(id) ?: return false
        return d.send(Packet(Types.SHARE, bodyOf("text" to text, "scan" to true)))
    }

    /** Sends text or a link from the share sheet. */
    fun sendText(core: FluxCore, id: String, text: String) {
        val d = core.device(id) ?: return
        val trimmed = text.trim()
        val isUrl = Regex("^[a-zA-Z][a-zA-Z0-9+.-]*://\\S+$").matches(trimmed)
        d.send(Packet(Types.SHARE, if (isUrl) bodyOf("url" to trimmed) else bodyOf("text" to text)))
        core.toast(if (isUrl) "Link sent to ${d.identity.deviceName}" else "Text sent to ${d.identity.deviceName}")
    }

    private fun currentTls(): org.omarchy.flux.net.Tls? = FluxCore.tls

    private fun sanitize(name: String): String =
        name.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[\\u0000-\\u001f]"), "").ifBlank { "file" }
}
