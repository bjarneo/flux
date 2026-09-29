package org.omarchy.flux.core

import android.content.Intent
import android.util.Log
import net.schmizz.sshj.DefaultConfig
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.sftp.FileMode
import net.schmizz.sshj.sftp.SFTPClient
import net.schmizz.sshj.transport.verification.PromiscuousVerifier
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.omarchy.flux.net.LoopbackBridge
import org.omarchy.flux.net.Tunnel
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.SftpOffer
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.security.Security

private const val TAG = "FluxBrowse"

/**
 * Browse PC. The phone asks the computer for an SFTP session with
 * flux.sftp.request. The computer answers with flux.sftp and a tunnel
 * token, the user, and a one-time password.
 */
object Browse {
    private var ssh: SSHClient? = null
    private var sftp: SFTPClient? = null
    private var bridge: LoopbackBridge? = null

    /**
     * Changes with each [start] and [close]. A connect that ends after a
     * change closes its own session, because nobody browses it.
     */
    @Volatile private var generation = 0

    fun start(core: FluxCore, id: String) {
        val d = core.device(id) ?: return
        close()
        core.setBrowse(BrowseState(deviceId = id, loading = true))
        d.send(Packet(Types.SFTP_REQUEST, bodyOf("startBrowsing" to true)))
        core.scheduler.schedule({
            val s = core.browseState()
            if (s != null && s.deviceId == id && s.loading && s.entries.isEmpty() && s.error == null) {
                core.setBrowse(s.copy(loading = false, error = "${d.identity.deviceName} did not answer. Browse PC needs fluxd."))
            }
        }, 10, java.util.concurrent.TimeUnit.SECONDS)
    }

    /** Handles flux.sftp. The core lock is held. */
    fun onCredentials(core: FluxCore, d: Device, p: Packet) {
        val state = core.browseState()
        if (state == null || state.deviceId != d.id) return
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
        val gen = generation
        core.io.execute {
            // The session until the browser keeps it. The finally block ends
            // a session that the browser did not keep, also on the computer.
            var client: SSHClient? = null
            var b: LoopbackBridge? = null
            try {
                ensureBouncyCastle()
                val c = SSHClient(DefaultConfig()).also { client = it }
                c.addHostKeyVerifier(PromiscuousVerifier())
                c.connectTimeout = 8_000
                // The computer connects to this phone, and the TLS stream
                // carries the SSH session. sshj opens its own socket, so a
                // loopback bridge feeds it.
                if (cert == null || tls == null) error("the link is not ready")
                val tunnel = Tunnel.accept(tls, cert, offer.tunnel, announce = { d.send(it) })
                val loop = LoopbackBridge(tunnel).also { b = it }
                if (generation != gen) return@execute
                c.connect(loop.host, loop.port)
                if (generation != gen) return@execute
                c.authPassword(offer.user, offer.password)
                if (generation != gen) return@execute
                val s = c.newSFTPClient()
                if (!keep(gen, c, s, b)) return@execute
                client = null
                b = null
                core.setBrowse(state.copy(loading = false, roots = offer.roots))
                list(core, offer.roots.first().second)
            } catch (e: Exception) {
                if (generation == gen) {
                    Log.w(TAG, "SFTP connect failed", e)
                    core.setBrowse(state.copy(loading = false, error = "Cannot open files on ${d.identity.deviceName}: ${e.message}"))
                }
            } finally {
                client?.let { runCatching { it.disconnect() } }
                b?.close()
            }
        }
    }

    /** Keeps a new session, unless a close or a new start came after [gen]. */
    @Synchronized
    private fun keep(gen: Int, client: SSHClient, s: SFTPClient, b: LoopbackBridge?): Boolean {
        if (generation != gen) return false
        ssh = client
        sftp = s
        bridge = b
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

    fun download(core: FluxCore, entry: BrowseEntry) {
        val client = sftp ?: return
        core.toast("Downloading ${entry.name}")
        core.io.execute {
            val mime = Android.mimeType(entry.name)
            val dl = runCatching { Android.createDownload(core.app, entry.name, mime) }.getOrElse {
                core.toast("Cannot save ${entry.name}")
                return@execute
            }
            val ok = runCatching {
                client.open(entry.path).use { remote ->
                    remote.RemoteFileInputStream().use { it.copyTo(dl.stream, 64 * 1024) }
                }
            }.onFailure { Log.w(TAG, "download failed", it) }.isSuccess
            Android.finishDownload(core.app, dl, ok)
            if (ok) {
                val open = Intent(Intent.ACTION_VIEW).setDataAndType(dl.uri, mime ?: "*/*").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                Android.showEvent(core.app, "Downloaded ${entry.name}", "Saved in Downloads", open)
                core.toast("Saved ${entry.name} in Downloads")
            } else {
                core.toast("Downloading ${entry.name} failed")
            }
        }
    }

    /** Ends the SSH session. A tunnel carries 1 session, so the next start asks for a new one. */
    @Synchronized
    fun close() {
        generation++
        val s = sftp
        val c = ssh
        val b = bridge
        sftp = null
        ssh = null
        bridge = null
        FluxCore.io.execute {
            runCatching { s?.close() }
            runCatching { c?.disconnect() }
            b?.close()
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
