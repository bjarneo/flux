package org.omarchy.flux.core

import android.content.Intent
import android.util.AtomicFile
import org.omarchy.flux.net.Tunnel
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

/** Receives acknowledged file chunks. Private partial files survive an app restart. */
object ResumableTransfer {
    private val lock = Any()

    /** The Inbox transfer of each file, by its folder key. A retry of the computer keeps the item. The lock guards it. */
    private val inbox = HashMap<String, Long>()

    internal fun valid(id: String, name: String, size: Long, hash: String): Boolean =
        Regex("[a-f0-9]{12}").matches(id) && Regex("[a-f0-9]{64}").matches(hash) &&
            size in 0..(1L shl 40) && name.isNotBlank() && name != "." && name != ".." &&
            name.none { it == '/' || it == '\\' || it.code < 32 }

    fun receive(core: FluxCore, d: Device, p: Packet) {
        val id = p.string("id") ?: return
        val action = p.string("action") ?: return
        if (action != "offer" && action != "chunk") return
        val name = p.string("name") ?: return
        val size = p.long("size") ?: 0L
        val hash = p.string("hash") ?: return
        if (!valid(id, name, size, hash)) return
        val tls = FluxCore.tls ?: return
        val cert = d.certificate ?: return
        core.io.execute {
            synchronized(lock) {
                var item: Long? = null
                runCatching {
                    if (action == "offer") {
                        val before = System.currentTimeMillis() - 7L * 24 * 60 * 60 * 1000
                        File(core.app.filesDir, "incoming").listFiles()?.filter { it.isDirectory && it.lastModified() < before }?.forEach { it.deleteRecursively() }
                    }
                    val key = digest((d.id + ":" + id).toByteArray())
                    val dir = File(core.app.filesDir, "incoming/$key").apply { check(mkdirs() || isDirectory) }
                    dir.setLastModified(System.currentTimeMillis())
                    val state = AtomicFile(File(dir, "state.json"))
                    var meta = if (state.baseFile.exists()) JSONObject(String(state.readFully()))
                        else JSONObject().put("name", name).put("size", size).put("hash", hash).also { save(state, it) }
                    check(meta.getString("name") == name && meta.getLong("size") == size && meta.getString("hash") == hash) { "Transfer metadata changed" }
                    if (meta.optBoolean("done")) {
                        reply(d, id, "done", size)
                        return@synchronized
                    }
                    val transfer = inbox[key]?.takeIf(InboxFeed::transferResumed)
                        ?: InboxFeed.transferStarted(d.id, d.identity.deviceName, name, incoming = true).also { inbox[key] = it }
                    item = transfer
                    val part = File(dir, "data")
                    var offset = part.length()
                    check(offset <= size) { "Partial file exceeds the transfer size" }
                    if (action == "chunk") {
                        check(p.long("offset") == offset && p.payloadSize in 1..minOf(1L shl 20, size - offset)) { "Invalid transfer chunk" }
                        FileOutputStream(part, true).use { out ->
                            val token = p.payloadTunnel ?: error("The transfer needs a tunnel")
                            Tunnel.receive(tls, cert, token, p.payloadSize, out, announce = { d.send(it) })
                            out.fd.sync()
                        }
                        offset = part.length()
                    }
                    if (offset == size) {
                        if (!part.exists()) part.createNewFile()
                        val sum = MessageDigest.getInstance("SHA-256")
                        part.inputStream().use { input ->
                            val bytes = ByteArray(65536)
                            while (true) { val n = input.read(bytes); if (n < 0) break; sum.update(bytes, 0, n) }
                        }
                        if (hex(sum.digest()) != hash) { part.delete(); error("The file checksum does not match") }
                        val mime = Android.mimeType(name)
                        val download = Android.createDownload(core.app, name, mime)
                        try {
                            part.inputStream().use { input -> input.copyTo(download.stream) }
                            Android.finishDownload(core.app, download, true)
                        } catch (e: Exception) {
                            Android.finishDownload(core.app, download, false)
                            throw e
                        }
                        meta = meta.put("done", true)
                        save(state, meta)
                        part.delete()
                        InboxFeed.transferEnded(transfer, true)
                        inbox.remove(key)
                        val open = Intent(Intent.ACTION_VIEW).setDataAndType(download.uri, mime ?: "*/*").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        Android.showEvent(core.app, "Received $name", "From ${d.identity.deviceName}, saved in Downloads", open)
                        core.toast("Saved $name in Downloads")
                        reply(d, id, "done", size)
                    } else reply(d, id, "offset", offset)
                }.onFailure {
                    item?.let { t -> InboxFeed.transferEnded(t, false) }
                    d.send(Packet(Types.FLUX_TRANSFER, bodyOf("id" to id, "action" to "error", "error" to (it.message ?: "The transfer failed"))))
                }
            }
        }
    }

    private fun reply(d: Device, id: String, action: String, offset: Long) {
        d.send(Packet(Types.FLUX_TRANSFER, bodyOf("id" to id, "action" to action, "offset" to offset)))
    }
    private fun digest(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))
    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
    private fun save(file: AtomicFile, obj: JSONObject) {
        val stream = file.startWrite()
        try { stream.write(obj.toString().toByteArray()); file.finishWrite(stream) }
        catch (e: Exception) { file.failWrite(stream); throw e }
    }
}
