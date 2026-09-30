package org.omarchy.flux.core

import android.app.DownloadManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import org.omarchy.flux.net.Payload
import org.omarchy.flux.net.Tunnel
import org.omarchy.flux.protocol.TunnelPackets
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf

private const val TAG = "FluxShare"

/** The MIME type of an Android app. */
private const val APK_MIME = "application/vnd.android.package-archive"

/** The largest received app that Flux checks as an update, in bytes. */
private const val MAX_UPDATE_BYTES = 200L shl 20

/** The start of the file name of a Flux update: flux-android-VERSION.apk. */
private const val UPDATE_PREFIX = "flux-android-"

/** How old a temporary file in the cache must be before Flux deletes it at start, in milliseconds. */
private const val STALE_CACHE_MS = 24 * 60 * 60_000L

/**
 * The web links that Flux opens. Only an http or https URL with a host is a
 * link. Any other value, such as a file: URL, another scheme, or a path, is
 * text. fluxd and the other Flux apps use the same rule.
 */
object WebUrl {
    private val shape = Regex("^([A-Za-z][A-Za-z0-9+.-]*)://([^\\s/?#]*)([/?#]\\S*)?$")

    /** Returns the trimmed [text] when it is a web link, or null. */
    fun of(text: String?): String? {
        val t = text?.trim() ?: return null
        val m = shape.matchEntire(t) ?: return null
        val scheme = m.groupValues[1].lowercase()
        if (scheme != "http" && scheme != "https") return null
        // The host follows the user information and comes before the port.
        val authority = m.groupValues[2].substringAfterLast('@')
        val host = if (authority.startsWith("[")) authority.substringAfter('[').substringBefore(']') else authority.substringBefore(':')
        return t.takeIf { host.isNotEmpty() }
    }
}

/**
 * Decides whether Flux offers the Android installer for a received app.
 * This code has no Android dependency, so the JVM tests check it.
 */
object ApkCheck {
    /** True when a file with [name] and [mime] is an Android app. */
    fun isApk(name: String, mime: String?): Boolean = mime == APK_MIME || name.lowercase().endsWith(".apk")

    /**
     * Returns the version in the name of a Flux update, flux-android-VERSION.apk,
     * or null for another name. An empty file and a file above
     * [MAX_UPDATE_BYTES] give null too. Only a file with a version gets the
     * full check of [isUpdate].
     */
    fun updateVersion(name: String, size: Long): String? {
        if (!name.startsWith(UPDATE_PREFIX) || size !in 1..MAX_UPDATE_BYTES) return null
        return name.removePrefix(UPDATE_PREFIX).removeSuffix(".apk")
    }

    /**
     * Reports whether an app archive is a newer build of the installed app:
     * the same package, a higher version code, and only signers of the
     * installed app. [installedSigner] asks the package manager about 1
     * signing certificate of the archive.
     */
    fun isUpdate(
        archivePackage: String?,
        archiveVersion: Long,
        archiveSigners: List<ByteArray>,
        packageName: String,
        installedVersion: Long,
        installedSigner: (ByteArray) -> Boolean,
    ): Boolean = archivePackage == packageName && archiveVersion > installedVersion &&
        archiveSigners.isNotEmpty() && archiveSigners.all(installedSigner)
}

/** File, text, and link sharing: flux.share.request. */
object Share {
    /** Handles a share packet. The core lock is held, so the transfer runs on the IO pool. */
    fun receive(core: FluxCore, d: Device, p: Packet) {
        val from = d.identity.deviceName
        p.string("text")?.let { text ->
            if (Plugins.putRemoteText(core, from, text)) core.toast("Text from $from is on the clipboard")
            return
        }
        p.string("url")?.let { url ->
            // Only a web link opens. Any other value, such as a file: URL, is text, see WebUrl.
            val link = WebUrl.of(url) ?: return receive(core, d, Packet(Types.SHARE, bodyOf("text" to url)))
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(link))
            Android.showEvent(core.app, "Link from $from", link, intent)
            core.toast("Link from $from")
            return
        }
        if (!p.hasPayload) return
        val token = p.payloadTunnel ?: return
        val name = sanitize(p.string("filename") ?: "file-${System.currentTimeMillis()}")
        val cert = d.certificate ?: return
        val tls = currentTls() ?: return
        core.toast("Receiving $name")
        core.io.execute { download(core, d, from, token, cert, p, name, tls) }
    }

    private fun download(
        core: FluxCore,
        d: Device,
        from: String,
        token: String,
        cert: java.security.cert.X509Certificate,
        p: Packet,
        name: String,
        tls: org.omarchy.flux.net.Tls,
    ) {
        val mime = Android.mimeType(name)
        val dl = runCatching { Android.createDownload(core.app, name, mime) }.getOrElse {
            core.toast("Cannot save $name: ${it.message}")
            d.send(TunnelPackets.failed(token, "cannot save the file"))
            return
        }
        // The computer blocks incoming connections. This phone listens, and the computer connects.
        val ok = runCatching { Tunnel.receive(tls, cert, token, p.payloadSize, dl.stream, announce = { d.send(it) }) }
            .onFailure { Log.w(TAG, "receive $name failed", it) }
            .isSuccess
        Android.finishDownload(core.app, dl, ok)
        if (!ok) {
            core.toast("Receiving $name failed")
            return
        }
        val open = viewIntent(dl.uri, mime)
        // The computer sends a Flux update as flux-android-VERSION.apk. Its
        // notification opens the Android installer only for a newer Flux with
        // the signing key of this app. Any other app only shows in Downloads,
        // so that a computer cannot offer an app to install.
        if (ApkCheck.isApk(name, mime)) {
            val version = updateVersion(core.app, name, p.payloadSize, dl.uri)
            if (version != null) {
                Android.showEvent(core.app, "Flux $version from $from", "Tap to install the update", open)
                core.toast("Flux $version is in Downloads. Open its notification to install it")
                return
            }
            Android.showEvent(core.app, "Received $name", "From $from, saved in Downloads. Flux does not install it.", Intent(DownloadManager.ACTION_VIEW_DOWNLOADS))
            core.toast("Saved $name in Downloads")
            return
        }
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
                val sent = ArrayList<String>()
                for ((uri, name, size) in files) {
                    val ok = runCatching {
                        // The protocol needs the exact size before the transfer.
                        // A source without a size goes through a cache file.
                        var length = size
                        var temp: java.io.File? = null
                        try {
                            if (length < 0) {
                                val t = java.io.File.createTempFile("flux-send", null, core.app.cacheDir)
                                temp = t
                                resolver.openInputStream(uri)!!.use { src -> t.outputStream().use { src.copyTo(it) } }
                                length = t.length()
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
                        } finally {
                            temp?.delete()
                        }
                    }.onFailure { Log.w(TAG, "send $name failed", it) }.isSuccess
                    if (ok) sent += name else core.toast("Sending $name failed")
                }
                if (sent.isNotEmpty()) core.toast(if (sent.size == 1) "Sent ${sent[0]}" else "Sent ${sent.size} files to ${d.identity.deviceName}")
            } finally {
                onDone?.invoke()
            }
        }
    }

    /**
     * Sends 1 file from the camera, such as a photo or a scanned PDF. The body
     * gets [extra] fields, for example "photo" or "scan". [onResult] runs on
     * an IO thread after the transfer ends.
     */
    fun sendCapture(core: FluxCore, id: String, uri: Uri, name: String, extra: Map<String, Any?>, onResult: (Result<Unit>) -> Unit) {
        val d = core.device(id)
        val cert = d?.certificate
        val tls = currentTls()
        if (d == null || cert == null || tls == null || !d.online) {
            onResult(Result.failure(IllegalStateException("Not connected")))
            return
        }
        core.io.execute {
            val result = runCatching {
                val resolver = core.app.contentResolver
                var length = -1L
                if (uri.scheme == "file") {
                    length = java.io.File(uri.path!!).length()
                } else {
                    resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
                        if (c.moveToFirst() && !c.isNull(0)) length = c.getLong(0)
                    }
                }
                // The protocol needs the exact size before the transfer.
                var temp: java.io.File? = null
                try {
                    if (length < 0) {
                        val t = java.io.File.createTempFile("flux-send", null, core.app.cacheDir)
                        temp = t
                        resolver.openInputStream(uri)!!.use { src -> t.outputStream().use { src.copyTo(it) } }
                        length = t.length()
                    }
                    (temp?.inputStream() ?: resolver.openInputStream(uri)!!).use { input ->
                        val server = Payload.openServer()
                        val fields = listOf<Pair<String, Any?>>("filename" to name, "open" to false) + extra.toList()
                        if (!d.send(Packet(Types.SHARE, bodyOf(*fields.toTypedArray()), payloadSize = length, payloadPort = server.localPort))) {
                            server.close()
                            error("Not connected")
                        }
                        Payload.send(tls, server, input, length, cert)
                    }
                } finally {
                    temp?.delete()
                }
            }.onFailure { Log.w(TAG, "send $name failed", it) }
            onResult(result)
        }
    }

    /** Sends a share packet with the body fields. It returns false when the device has no link. */
    fun sendFields(core: FluxCore, id: String, fields: List<Pair<String, Any?>>): Boolean {
        val d = core.device(id) ?: return false
        return d.send(Packet(Types.SHARE, bodyOf(*fields.toTypedArray())))
    }

    /**
     * Sends text from Scan text. The `scan` flag tells fluxd that the text
     * comes from the camera. It returns false when the device has no link.
     */
    fun sendScan(core: FluxCore, id: String, text: String): Boolean {
        val d = core.device(id) ?: return false
        return d.send(Packet(Types.SHARE, bodyOf("text" to text, "scan" to true)))
    }

    /** Sends text or a link from the share sheet. Only a web link goes as a link, see [WebUrl]. */
    fun sendText(core: FluxCore, id: String, text: String) {
        val d = core.device(id) ?: return
        val url = WebUrl.of(text)
        d.send(Packet(Types.SHARE, if (url != null) bodyOf("url" to url) else bodyOf("text" to text)))
        core.toast(if (url != null) "Link sent to ${d.identity.deviceName}" else "Text sent to ${d.identity.deviceName}")
    }

    /**
     * Reports whether Flux reads a file that another app shares, from the
     * parts of its address. Flux reads only content addresses of other
     * apps: a file address opens a path with the rights of Flux, and an
     * address of Flux reaches its own files. Contacts and messages need a
     * read grant from the app that shares them ([granted]), because Flux can
     * read them with its own permissions.
     */
    fun acceptShared(scheme: String?, authority: String?, packageName: String, granted: Boolean): Boolean {
        if (!scheme.equals("content", ignoreCase = true)) return false
        // A content address of another user starts with the user ID and @.
        val provider = authority?.substringAfterLast('@')?.lowercase() ?: return false
        if (provider.isEmpty() || provider == packageName || provider.startsWith("$packageName.")) return false
        return granted || provider !in PROTECTED_PROVIDERS
    }

    /** The providers that hold contacts, calls, and messages. */
    private val PROTECTED_PROVIDERS = setOf("com.android.contacts", "contacts", "call_log", "sms", "mms", "mms-sms", "com.android.voicemail")

    /**
     * Deletes the temporary files that a transfer or a failed photo left in
     * [cacheDir], when they are older than 1 day. The app calls it when it starts.
     */
    fun cleanCache(cacheDir: java.io.File, now: Long = System.currentTimeMillis()) {
        fun stale(f: java.io.File) = f.isFile && now - f.lastModified() > STALE_CACHE_MS
        cacheDir.listFiles()?.filter { (it.name.startsWith("flux-send") || it.name.startsWith("received-update")) && stale(it) }
            ?.forEach { it.delete() }
        for (dir in listOf("photos", "signatures")) {
            java.io.File(cacheDir, dir).listFiles()?.filter(::stale)?.forEach { it.delete() }
        }
    }

    private fun currentTls(): org.omarchy.flux.net.Tls? = FluxCore.tls

    /**
     * Returns the intent that opens a saved file at [uri] of the type [mime].
     * A file of an unknown type opens Downloads, because a view of any type
     * matches every app, the Android installer too.
     */
    internal fun viewIntent(uri: Uri, mime: String?): Intent = if (mime == null) {
        Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)
    } else {
        Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    /**
     * Returns the version of a Flux update at [uri], or null for any other
     * app. The name and the size must fit [ApkCheck.updateVersion], and the
     * app must be a newer Flux with the signing key of this app. Browse PC
     * uses the same rule. It reads the file, so it runs on an IO thread.
     */
    internal fun updateVersion(context: android.content.Context, name: String, size: Long, uri: Uri): String? =
        ApkCheck.updateVersion(name, size)?.takeIf { isFluxUpdate(context, uri) }

    /** Reports whether the APK at [uri] is a newer build of this app, signed with its key. */
    private fun isFluxUpdate(context: android.content.Context, uri: Uri): Boolean {
        val copy = java.io.File.createTempFile("received-update", ".apk", context.cacheDir)
        return try {
            context.contentResolver.openInputStream(uri)?.use { input -> copy.outputStream().use { input.copyTo(it) } } ?: return false
            val pm = context.packageManager
            // Android 10 reads the certificates of an archive only with GET_SIGNATURES.
            @Suppress("DEPRECATION")
            val flags = PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_SIGNATURES
            val archive = pm.getPackageArchiveInfo(copy.path, flags) ?: return false
            @Suppress("DEPRECATION")
            val signers = (archive.signingInfo?.apkContentsSigners ?: archive.signatures)?.map { it.toByteArray() }.orEmpty()
            ApkCheck.isUpdate(
                archive.packageName, archive.longVersionCode, signers,
                context.packageName, pm.getPackageInfo(context.packageName, 0).longVersionCode,
            ) { cert -> pm.hasSigningCertificate(context.packageName, cert, PackageManager.CERT_INPUT_RAW_X509) }
        } catch (e: Exception) {
            Log.w(TAG, "read the received app", e)
            false
        } finally {
            copy.delete()
        }
    }

    /**
     * Returns a safe file name: the last path part, without control
     * characters and without format characters such as the bidi marks, which
     * can make a name show in another order.
     */
    internal fun sanitize(name: String): String =
        name.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[\\p{Cc}\\p{Cf}]"), "").trim().ifBlank { "file" }
}
