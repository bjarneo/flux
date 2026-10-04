package org.omarchy.flux.core

import android.app.DownloadManager
import android.content.Intent
import android.util.Log
import net.schmizz.sshj.DefaultConfig
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.sftp.FileMode
import net.schmizz.sshj.sftp.SFTPClient
import net.schmizz.sshj.transport.verification.PromiscuousVerifier
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.omarchy.flux.net.ConnectedSocketFactory
import org.omarchy.flux.net.Tunnel
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.SftpFound
import org.omarchy.flux.protocol.SftpOffer
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.security.Security
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

private const val TAG = "FluxBrowse"

/**
 * Browse PC. The phone asks the computer for an SFTP session with
 * flux.sftp.request. The computer answers with flux.sftp and a tunnel
 * token, the user, and a one-time password.
 */
object Browse {
    private var ssh: SSHClient? = null
    private var sftp: SFTPClient? = null

    /**
     * Changes with each [start] and [close]. A connect that ends after a
     * change closes its own session, because nobody browses it.
     */
    @Volatile private var generation = 0

    /** The folder that the next session opens in place of the first root, or null. */
    @Volatile private var resumePath: String? = null

    /** The ID of the last search. An answer to an older search does not show. */
    private val searchIds = AtomicLong()

    /**
     * Starts a session. It opens [path] when the computer shares it, else
     * the first root. `fluxd` ends a session when the link drops, so the
     * screen starts a new session at the same [path] after a reconnect.
     */
    fun start(core: FluxCore, id: String, path: String? = null) {
        val d = core.device(id) ?: return
        close()
        resumePath = path
        // The search field stays while a new session of the same computer opens.
        val canSearch = core.browseState()?.takeIf { it.deviceId == id }?.canSearch ?: false
        core.setBrowse(BrowseState(deviceId = id, loading = true, canSearch = canSearch))
        d.send(Packet(Types.SFTP_REQUEST, bodyOf("startBrowsing" to true)))
        core.scheduler.schedule({
            val s = core.browseState()
            if (s != null && s.deviceId == id && s.loading && s.entries.isEmpty() && s.error == null) {
                core.setBrowse(s.copy(loading = false, error = "${d.identity.deviceName} did not answer. Get files needs fluxd."))
            }
        }, 10, TimeUnit.SECONDS)
    }

    /** Handles flux.sftp. The core lock is held. */
    fun onCredentials(core: FluxCore, d: Device, p: Packet) {
        val state = core.browseState()
        if (state == null || state.deviceId != d.id) return
        if (SftpFound.isAnswer(p)) {
            SftpFound.parse(p)?.let { onFound(core, it) }
            return
        }
        p.string("errorMessage")?.let {
            core.setBrowse(state.copy(loading = false, error = it))
            return
        }
        val offer = SftpOffer.parse(p) ?: run {
            core.setBrowse(state.copy(loading = false, error = "${d.identity.deviceName} sent no way to connect"))
            return
        }
        val cert = d.certificate
        val tls = FluxCore.tls
        val host = d.link?.address?.hostAddress ?: d.identity.deviceName
        val gen = generation
        core.io.execute {
            // The session until the browser keeps it. The finally block ends
            // a session that the browser did not keep, also on the computer.
            var client: SSHClient? = null
            var tunnel: java.net.Socket? = null
            try {
                ensureBouncyCastle()
                val c = SSHClient(DefaultConfig()).also { client = it }
                // The pinned TLS tunnel checks the computer, so the SSH host key needs no check.
                c.addHostKeyVerifier(PromiscuousVerifier())
                c.connectTimeout = 8_000
                // The computer connects to this phone, and the TLS stream
                // carries the SSH session. sshj takes the connected tunnel
                // as its socket, so no other app can take the session.
                if (cert == null || tls == null) error("the link is not ready")
                val t = Tunnel.accept(tls, cert, offer.tunnel, announce = { d.send(it) }).also { tunnel = it }
                if (generation != gen) return@execute
                c.socketFactory = ConnectedSocketFactory(t)
                c.connect(host, 22)
                if (generation != gen) return@execute
                c.authPassword(offer.user, offer.password)
                if (generation != gen) return@execute
                val s = c.newSFTPClient()
                if (!keep(gen, c, s)) return@execute
                client = null
                tunnel = null
                val first = offer.roots.first().second
                val open = resumePath?.takeIf { p -> offer.roots.any { (_, root) -> p == root || p.startsWith(root.trimEnd('/') + "/") } } ?: first
                resumePath = null
                core.setBrowse(state.copy(loading = false, roots = offer.roots, canSearch = offer.search))
                list(core, open)
            } catch (e: Exception) {
                if (generation == gen) {
                    Log.w(TAG, "SFTP connect failed", e)
                    core.setBrowse(state.copy(loading = false, error = "Cannot open files on ${d.identity.deviceName}: ${e.message}"))
                }
            } finally {
                client?.let { runCatching { it.disconnect() } }
                tunnel?.let { runCatching { it.close() } }
            }
        }
    }

    /** Keeps a new session, unless a close or a new start came after [gen]. */
    @Synchronized
    private fun keep(gen: Int, client: SSHClient, s: SFTPClient): Boolean {
        if (generation != gen) return false
        ssh = client
        sftp = s
        return true
    }

    fun list(core: FluxCore, path: String) {
        val client = sftp ?: return
        val state = core.browseState() ?: return
        core.setBrowse(state.copy(loading = true, path = path))
        core.io.execute {
            try {
                val entries = client.ls(path)
                    .filter { !it.name.startsWith(".") }
                    .map { BrowseEntry(it.name, it.path, it.attributes.type == FileMode.Type.DIRECTORY, it.attributes.size) }
                    .sortedWith(compareBy<BrowseEntry>({ !it.dir }, { it.name.lowercase() }))
                core.setBrowse(core.browseState()?.copy(loading = false, path = path, entries = entries, error = null))
            } catch (e: Exception) {
                core.setBrowse(core.browseState()?.copy(loading = false, error = "Cannot open $path: ${e.message}"))
            }
        }
    }

    /**
     * Asks the computer for the files and folders whose names hold each
     * word of [query], in [path] and its subfolders. An empty [path]
     * searches each shared folder. An empty [query] ends the search.
     */
    fun search(core: FluxCore, query: String, path: String) {
        val state = core.browseState() ?: return
        val q = query.trim()
        if (q.isEmpty()) {
            if (state.search != null) core.setBrowse(state.copy(search = null))
            return
        }
        val d = core.device(state.deviceId) ?: return
        val id = searchIds.incrementAndGet()
        core.setBrowse(state.copy(search = BrowseSearch(id, q, path)))
        d.send(SftpFound.request(id, q, path))
        core.scheduler.schedule({
            val now = core.browseState()
            val s = now?.search
            if (s != null && s.id == id && s.loading) {
                core.setBrowse(now.copy(search = s.copy(loading = false, error = "${d.identity.deviceName} did not answer the search.")))
            }
        }, 20, TimeUnit.SECONDS)
    }

    /** Shows the answer to the last search. The core lock is held. */
    private fun onFound(core: FluxCore, found: SftpFound) {
        val state = core.browseState() ?: return
        val s = state.search?.takeIf { it.id == found.id } ?: return
        val results = found.results.map { BrowseEntry(it.path.trimEnd('/').substringAfterLast('/'), it.path, it.dir, if (it.dir) 0 else it.size) }
        core.setBrowse(state.copy(search = s.copy(loading = false, results = results, more = found.more, partial = found.partial, error = found.error)))
    }

    /** Reports whether [name] holds each word of [query], in any case. The demo searches with it. */
    fun matches(name: String, query: String): Boolean {
        val lower = name.lowercase()
        val words = query.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        return words.isNotEmpty() && words.all { it in lower }
    }

    /**
     * Saves [entry] in Downloads, with the safe name of a received file. The
     * rule for apps is the same as in [Share]: the notification opens the
     * Android installer only for a newer Flux with the signing key of this
     * app. Any other app only shows in Downloads.
     */
    fun download(core: FluxCore, entry: BrowseEntry) {
        val client = sftp ?: return
        val name = Share.sanitize(entry.name)
        core.toast("Downloading $name")
        core.io.execute {
            val mime = Android.mimeType(name)
            val dl = runCatching { Android.createDownload(core.app, name, mime) }.getOrElse {
                core.toast("Cannot save $name")
                return@execute
            }
            val size = runCatching {
                client.open(entry.path).use { remote ->
                    remote.RemoteFileInputStream().use { it.copyTo(dl.stream, 64 * 1024) }
                }
            }.onFailure { Log.w(TAG, "download failed", it) }.getOrNull()
            Android.finishDownload(core.app, dl, size != null)
            if (size == null) {
                core.toast("Downloading $name failed")
                return@execute
            }
            val open = Share.viewIntent(dl.uri, mime)
            if (ApkCheck.isApk(name, mime)) {
                val version = Share.updateVersion(core.app, name, size, dl.uri)
                if (version != null) {
                    Android.showEvent(core.app, "Downloaded Flux $version", "Tap to install the update", open)
                    core.toast("Flux $version is in Downloads. Open its notification to install it")
                    return@execute
                }
                Android.showEvent(core.app, "Downloaded $name", "Saved in Downloads. Flux does not install it.", Intent(DownloadManager.ACTION_VIEW_DOWNLOADS))
                core.toast("Saved $name in Downloads")
                return@execute
            }
            Android.showEvent(core.app, "Downloaded $name", "Saved in Downloads", open)
            core.toast("Saved $name in Downloads")
        }
    }

    /** Ends the SSH session. A tunnel carries 1 session, so the next start asks for a new one. */
    @Synchronized
    fun close() {
        generation++
        val s = sftp
        val c = ssh
        sftp = null
        ssh = null
        FluxCore.io.execute {
            runCatching { s?.close() }
            // The disconnect closes the socket, which is the tunnel.
            runCatching { c?.disconnect() }
        }
    }

    /**
     * Android ships a reduced BouncyCastle under the name BC. sshj needs the
     * full provider, so the app replaces it once.
     */
    @Synchronized
    private fun ensureBouncyCastle() {
        val existing = Security.getProvider(BouncyCastleProvider.PROVIDER_NAME)
        if (existing != null && existing !is BouncyCastleProvider) Security.removeProvider(BouncyCastleProvider.PROVIDER_NAME)
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) !is BouncyCastleProvider) Security.addProvider(BouncyCastleProvider())
    }
}
