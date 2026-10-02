package org.omarchy.flux.core

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import kotlinx.serialization.json.JsonObject
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import org.omarchy.flux.protocol.bool
import org.omarchy.flux.protocol.json
import org.omarchy.flux.protocol.long
import org.omarchy.flux.protocol.str

/**
 * The packet handlers for the phone-side plugins. [handle] runs with the
 * core lock held, so a handler that blocks moves its work to [FluxCore.io].
 */
object Plugins {
    private val main = Handler(Looper.getMainLooper())

    /** The last text that a computer put on the clipboard. Flux does not send it back. */
    @Volatile var lastRemoteClip: String? = null

    /** The clip time of the last clip that Flux sent. A repeat of the same clip does not go out again. */
    @Volatile var lastSentStamp: Long = 0L

    /**
     * The time that Flux last wrote the clipboard, from
     * [SystemClock.elapsedRealtime]. The echo check uses it with [ECHO_MS].
     */
    @Volatile var selfWriteAt: Long = 0L

    /**
     * A text that the user sent with a manual path, for example the tile,
     * while no computer was connected yet. The first computer that connects
     * before [pendingUntil] gets it. Only a window with focus can read the
     * clipboard, so the text is read at once and kept here.
     */
    @Volatile private var pendingClip: String? = null
    @Volatile private var pendingUntil: Long = 0L
    @Volatile private var pendingNotify: ((String) -> Unit)? = null

    /**
     * The longest text from a computer that Flux puts on the clipboard, in
     * UTF-8 bytes. Android sends a clip through a binder call, and a much
     * larger clip stops the app.
     */
    const val MAX_CLIPBOARD_TEXT = 256 * 1024

    /**
     * The longest phone text that the clipboard listener, the tile, and the
     * notification action send to the computers, in UTF-8 bytes. `fluxd`
     * takes up to 1 MiB from a device.
     */
    const val MAX_AUTO_TEXT = 1 shl 20

    /**
     * How long a manual send waits for the first computer, for example
     * after the tile starts Flux from a stopped process.
     */
    const val PENDING_MS = 15_000L

    /**
     * A copy of the text from a computer counts as the echo of the Flux
     * write only this long after the write. A later copy of the same text
     * is a new copy of the user and goes out.
     */
    const val ECHO_MS = 3_000L

    fun onConnected(core: FluxCore, d: Device) {
        sendBattery(core, d)
        HerdrSync.onConnected(d)
        // New images that no computer took yet go out now.
        CaptureWatch.poke()
        sendPending(core, d)
        if (core.foreground && core.settings.syncClipboard) {
            main.post {
                val text = Android.clipboardText(core.app, automatic = true) ?: return@post
                d.send(Packet(Types.CLIPBOARD_CONNECT, bodyOf("content" to text, "timestamp" to core.settings.clipboardTimestamp)))
            }
        }
    }

    fun handle(core: FluxCore, d: Device, p: Packet) {
        when (p.type) {
            Types.PING -> {
                val msg = p.string("message") ?: "Ping"
                core.toast("$msg from ${d.identity.deviceName}")
            }
            Types.BATTERY -> {
                d.battery = p.int("currentCharge")?.takeIf { it >= 0 }
                d.charging = p.bool("isCharging") ?: false
            }
            Types.CLIPBOARD -> receiveClipboard(core, d, p.string("content"), null)
            Types.CLIPBOARD_CONNECT -> receiveClipboard(core, d, p.string("content"), p.long("timestamp") ?: 0L)
            Types.SHARE -> Share.receive(core, d, p)
            Types.SHARE_UPDATE -> Unit
            Types.NOTIFICATION -> {
                if (p.bool("isCancel") == true) {
                    p.string("id")?.let { Android.cancelFromComputer(core.app, d.id, it) }
                    return
                }
                val n = ComputerNotification.from(p, d.id, d.identity.deviceName, System.currentTimeMillis()) ?: return
                Android.showFromComputer(core.app, d.id, n)
            }
            Types.NOTIFICATION_REQUEST -> {
                if (p.bool("request") == true) NotificationSync.sendAll(d)
                p.string("cancel")?.let { NotificationSync.dismiss(d.id, it) }
            }
            Types.NOTIFICATION_REPLY -> {
                val id = p.string("requestReplyId") ?: return
                NotificationSync.reply(d.id, id, p.string("message") ?: "")
            }
            Types.NOTIFICATION_ACTION -> {
                val key = p.string("key") ?: return
                NotificationSync.action(d.id, key, p.string("action") ?: return)
            }
            Types.FIND_MY_PHONE -> Ringer.start(core.app, d.identity.deviceName)
            Types.RUN_COMMAND -> {
                d.commands = parseCommands(p)
                d.commandsLoaded = true
            }
            Types.MPRIS -> receiveMpris(d, p)
            Types.SFTP -> Browse.onCredentials(core, d, p)
            Types.FLUX_WEBCAM -> org.omarchy.flux.webcam.WebcamSession.onPacket(core, d, p)
            Types.FLUX_DND -> DndSync.onPacket(core, d, p)
            Types.FLUX_MIC -> org.omarchy.flux.mic.MicSession.onPacket(core, d, p)
            Types.FLUX_SCREEN -> org.omarchy.flux.screen.ScreenSession.onPacket(core, d, p)
            Types.FLUX_APPROVE -> Approvals.onPacket(core, d, p)
            Types.FLUX_HERDR -> HerdrSync.onPacket(core, d, p)
            Types.FLUX_CLIPBOARD_IMAGE -> ClipImage.receive(core, d, p)
            Types.FLUX_INPUT -> {
                d.remoteInput = p.bool("enabled")
                d.remoteDesktop = p.bool("desktop")
            }
            Types.FLUX_DESKTOP -> org.omarchy.flux.desktop.DesktopSession.onPacket(core, d, p)
            Types.FLUX_SHORTCUTS -> d.shortcuts = Shortcuts.merge(d.shortcuts, p)
            Types.FLUX_THEME -> ComputerThemes.onPacket(core, d, p)
            Types.SMS_REQUEST, Types.SMS_REQUEST_CONVERSATIONS, Types.SMS_REQUEST_CONVERSATION -> SmsSync.onPacket(core, d, p)
        }
    }

    // --------------------------------------------------------------- battery

    fun sendBattery(core: FluxCore, d: Device) {
        val (pct, charging) = Android.battery(core.app)
        val low = if (pct <= 15 && !charging) 1 else 0
        d.send(Packet(Types.BATTERY, bodyOf("currentCharge" to pct, "isCharging" to charging, "thresholdEvent" to low)))
    }

    // ------------------------------------------------------------- clipboard

    /**
     * Takes the clipboard of a computer. The phone keeps the time of the
     * clip, so that the same clip after a reconnect changes nothing, also
     * when the phone refused it.
     */
    private fun receiveClipboard(core: FluxCore, d: Device, text: String?, timestamp: Long?) {
        if (text.isNullOrEmpty() || !core.settings.syncClipboard) return
        if (timestamp != null && timestamp in 1..core.settings.clipboardTimestamp) return
        core.settings.clipboardTimestamp = if (timestamp != null && timestamp > 0) timestamp else System.currentTimeMillis()
        if (putRemoteText(core, d.identity.deviceName, text)) InboxFeed.clipReceived(d.id, d.identity.deviceName, text)
    }

    /**
     * Puts text from the computer [from] on the clipboard. It returns false
     * and shows a message when the text is longer than [MAX_CLIPBOARD_TEXT].
     */
    fun putRemoteText(core: FluxCore, from: String, text: String): Boolean {
        if (text.length > MAX_CLIPBOARD_TEXT || text.toByteArray(Charsets.UTF_8).size > MAX_CLIPBOARD_TEXT) {
            core.toast("The text from $from is too large for the clipboard")
            return false
        }
        lastRemoteClip = text
        // The clipboard listener also sees this write, so the echo check skips it.
        selfWriteAt = SystemClock.elapsedRealtime()
        main.post {
            if (!Android.setClipboard(core.app, text)) core.toast("Android did not take the text from $from")
        }
        return true
    }

    /** Sends the local clipboard. Call it from the main thread while the app has focus. */
    fun sendClipboard(core: FluxCore, id: String): Boolean {
        val d = core.device(id) ?: return false
        val name = d.identity.deviceName
        Android.clipboardImage(core.app)?.let { (uri, mime) ->
            if (Types.FLUX_CLIPBOARD_IMAGE !in d.identity.incoming) {
                core.toast("Update Flux on $name to send images")
                return false
            }
            core.settings.clipboardTimestamp = System.currentTimeMillis()
            ClipImage.send(core, listOf(d), uri, mime, manual = true) { sent ->
                if (sent > 0) InboxFeed.clipSent(listOf(d.id to name), null)
                core.toast(
                    when {
                        sent > 0 -> "Image sent to $name"
                        sent < 0 -> "The image is larger than ${ClipImage.MAX_BYTES shr 20} MB"
                        else -> "Sending the image to $name failed"
                    },
                )
            }
            return true
        }
        val text = Android.clipboardText(core.app)
        if (text.isNullOrEmpty()) {
            core.toast("The clipboard is empty")
            return false
        }
        core.settings.clipboardTimestamp = System.currentTimeMillis()
        d.send(Packet(Types.CLIPBOARD, bodyOf("content" to text)))
        InboxFeed.clipSent(listOf(d.id to name), text)
        core.toast("Clipboard sent to ${d.identity.deviceName}")
        return true
    }

    /**
     * The clipboard listener calls it while Flux is in front. It sends the
     * new clip to each connected paired computer. A clip that its app marks
     * as sensitive, for example a password, stays on the phone.
     */
    fun onLocalClipboard(core: FluxCore) {
        sendClipboardToAll(core, manual = false)
    }

    /**
     * Sends the clipboard to each connected paired computer. Call it on the
     * main thread while a window of Flux has focus. [manual] is true for a
     * user action, for example the tile: it gives 1 result to [notify] and
     * sends the current clip again. [notify] can run on another thread, for
     * example after an image transfer. With [manual] false, the listener
     * path reports nothing and drops a clip that it sent before and a clip
     * that came from a computer. Both paths skip text that its app marks as
     * sensitive.
     */
    fun sendClipboardToAll(core: FluxCore, manual: Boolean, notify: (String) -> Unit = {}): Boolean {
        if (!core.settings.syncClipboard) {
            if (manual) notify("Turn on Sync clipboard first")
            return false
        }
        val computers = core.connectedPaired()
        if (computers.isEmpty()) {
            if (manual) keepForConnect(core, notify)
            return false
        }
        val stamp = Android.clipTimestamp(core.app)
        // The same clip does not go out twice, for example from 2 listeners.
        if (!manual && stamp != 0L && stamp == lastSentStamp) return false
        Android.clipboardImage(core.app)?.let { (uri, mime) ->
            if (!manual && uri == ClipImage.lastRemote) return false
            val targets = computers.filter { Types.FLUX_CLIPBOARD_IMAGE in it.identity.incoming }
            if (targets.isEmpty()) {
                if (manual) notify("Update Flux on the computer to send images")
                return false
            }
            lastSentStamp = stamp
            core.settings.clipboardTimestamp = System.currentTimeMillis()
            ClipImage.send(core, targets, uri, mime, manual = manual) { sent ->
                if (sent > 0) InboxFeed.clipSent(targets.map { it.id to it.identity.deviceName }, null)
                // The message names the computer, so that the user knows where the image went.
                val one = targets.singleOrNull()?.identity?.deviceName
                if (manual) {
                    notify(
                        when {
                            sent < 0 -> "The image is larger than ${ClipImage.MAX_BYTES shr 20} MB"
                            one != null -> if (sent > 0) "Image sent to $one" else "Sending the image to $one failed"
                            sent == targets.size -> "Image sent to $sent computers"
                            sent > 0 -> "Image sent to $sent of ${targets.size} computers"
                            else -> "Sending the image to ${targets.size} computers failed"
                        },
                    )
                }
            }
            return true
        }
        val text = Android.clipboardText(core.app, automatic = true)
        if (text.isNullOrEmpty()) {
            if (manual) {
                notify(
                    if (Android.clipboardSensitive(core.app)) "Flux does not send a clip that its app marks as sensitive"
                    else "The clipboard is empty",
                )
            }
            return false
        }
        // The echo of the text that a computer just put on the clipboard.
        if (!manual && text == lastRemoteClip && SystemClock.elapsedRealtime() - selfWriteAt < ECHO_MS) return false
        if (text.toByteArray(Charsets.UTF_8).size > MAX_AUTO_TEXT) {
            if (manual) notify("The text is too large for the clipboard")
            return false
        }
        lastSentStamp = stamp
        core.settings.clipboardTimestamp = System.currentTimeMillis()
        computers.forEach { it.send(Packet(Types.CLIPBOARD, bodyOf("content" to text))) }
        InboxFeed.clipSent(computers.map { it.id to it.identity.deviceName }, text)
        if (manual) {
            notify(if (computers.size == 1) "Clipboard sent to ${computers[0].identity.deviceName}" else "Clipboard sent to ${computers.size} computers")
        }
        return true
    }

    /**
     * Reads the clipboard text for a manual send while no computer is
     * connected, and keeps it for the first computer that connects in
     * [PENDING_MS]. Flux can still be on its way to a link, for example
     * after the tile started a stopped process. Call it while a window of
     * Flux has focus.
     */
    private fun keepForConnect(core: FluxCore, notify: (String) -> Unit) {
        if (!core.enabled || !core.hasPaired()) {
            notify("No computer is connected")
            return
        }
        if (Android.clipboardImage(core.app) != null) {
            notify("No computer is connected. Open Flux, and send the image again")
            return
        }
        val text = Android.clipboardText(core.app, automatic = true)
        if (text.isNullOrEmpty()) {
            notify(
                if (Android.clipboardSensitive(core.app)) "Flux does not send a clip that its app marks as sensitive"
                else "The clipboard is empty",
            )
            return
        }
        if (text.toByteArray(Charsets.UTF_8).size > MAX_AUTO_TEXT) {
            notify("The text is too large for the clipboard")
            return
        }
        pendingClip = text
        pendingNotify = notify
        pendingUntil = SystemClock.elapsedRealtime() + PENDING_MS
        notify("Flux sends the clipboard when a computer connects")
    }

    /** Sends a kept manual text to [d] when it connects in time. */
    private fun sendPending(core: FluxCore, d: Device) {
        val text = pendingClip ?: return
        val notify = pendingNotify
        pendingClip = null
        pendingNotify = null
        if (SystemClock.elapsedRealtime() > pendingUntil || !d.paired || !core.settings.syncClipboard) return
        core.settings.clipboardTimestamp = System.currentTimeMillis()
        d.send(Packet(Types.CLIPBOARD, bodyOf("content" to text)))
        notify?.invoke("Clipboard sent to ${d.identity.deviceName}")
    }

    // --------------------------------------------------------- run commands

    private fun parseCommands(p: Packet): List<RemoteCommand> {
        // The computer sends the command list as a JSON string.
        val raw = p.string("commandList") ?: return emptyList()
        val obj = runCatching { json.parseToJsonElement(raw) as JsonObject }.getOrNull() ?: return emptyList()
        return obj.entries.mapNotNull { (key, v) ->
            val o = v as? JsonObject ?: return@mapNotNull null
            RemoteCommand(key, o.str("name") ?: key, o.str("command") ?: "")
        }
    }

    fun requestCommands(core: FluxCore, id: String) {
        core.device(id)?.send(Packet(Types.RUN_COMMAND_REQUEST, bodyOf("requestCommandList" to true)))
    }

    /** Sends [cmd] to the computer. It returns false when no link is open, and then sends nothing. */
    fun runCommand(core: FluxCore, id: String, cmd: RemoteCommand): Boolean {
        val d = core.device(id)
        if (d == null || !d.send(Packet(Types.RUN_COMMAND_REQUEST, bodyOf("key" to cmd.key)))) {
            Log.i("FluxCommands", "not sent: ${cmd.key}, no open link")
            core.toast("Not connected. Try again in a moment")
            return false
        }
        Log.i("FluxCommands", "sent: ${cmd.key}")
        // The computer does not report the end of the command, so the phone tells only that it sent the command.
        core.toast("Sent “${cmd.name}” to ${d.identity.deviceName}")
        return true
    }

    // ------------------------------------------------------------------ media

    private fun receiveMpris(d: Device, p: Packet) {
        if (p.has("playerList")) {
            d.players = p.strings("playerList")
            if (d.currentPlayer !in d.players) d.currentPlayer = d.players.firstOrNull()
            d.playerStates.keys.retainAll(d.players.toSet())
            d.currentPlayer?.let { requestNowPlaying(d, it) }
        }
        val name = p.string("player") ?: return
        d.playerStates[name] = mergePlayer(d.playerStates[name] ?: PlayerState(name), p.body, SystemClock.elapsedRealtime())
        if (d.currentPlayer == null) d.currentPlayer = name
        val cur = d.currentPlayer?.let { d.playerStates[it] }
        if (cur != null && !cur.playing && d.playerStates[name]?.playing == true) d.currentPlayer = name
    }

    private fun requestNowPlaying(d: Device, player: String) {
        d.send(Packet(Types.MPRIS_REQUEST, bodyOf("player" to player, "requestNowPlaying" to true, "requestVolume" to true)))
    }

    fun requestPlayers(core: FluxCore, id: String) {
        val d = core.device(id) ?: return
        d.send(Packet(Types.MPRIS_REQUEST, bodyOf("requestPlayerList" to true)))
        d.currentPlayer?.let { requestNowPlaying(d, it) }
    }

    /** Makes [name] the player that the Media screen controls. */
    fun selectPlayer(core: FluxCore, id: String, name: String) {
        val d = core.device(id) ?: return
        core.locked { d.currentPlayer = name }
        requestNowPlaying(d, name)
    }

    fun mediaAction(core: FluxCore, id: String, action: String) {
        val d = core.device(id) ?: return
        val player = d.currentPlayer ?: return
        d.send(Packet(Types.MPRIS_REQUEST, bodyOf("player" to player, "action" to action)))
        if (action == "PlayPause") {
            core.locked {
                d.playerStates[player]?.let { s ->
                    val now = SystemClock.elapsedRealtime()
                    val pos = if (s.playing) s.position + (now - s.updatedAt) else s.position
                    d.playerStates[player] = s.copy(playing = !s.playing, position = pos, updatedAt = now)
                }
            }
        }
    }

    /** Sets the volume of the current player, from 0 to 100. */
    fun setVolume(core: FluxCore, id: String, volume: Int) {
        val d = core.device(id) ?: return
        val player = d.currentPlayer ?: return
        val v = volume.coerceIn(0, 100)
        d.send(Packet(Types.MPRIS_REQUEST, bodyOf("player" to player, "setVolume" to v)))
        core.locked {
            d.playerStates[player]?.let { d.playerStates[player] = it.copy(volume = v) }
        }
    }

    fun seek(core: FluxCore, id: String, positionMs: Long) {
        val d = core.device(id) ?: return
        val player = d.currentPlayer ?: return
        d.send(Packet(Types.MPRIS_REQUEST, bodyOf("player" to player, "SetPosition" to positionMs)))
        core.locked {
            d.playerStates[player]?.let { d.playerStates[player] = it.copy(position = positionMs, updatedAt = SystemClock.elapsedRealtime()) }
        }
    }
}

/**
 * Merges a flux.mpris packet from the computer into the state of a
 * player. A field that the packet leaves out keeps its old value. The
 * volume is different: the computer sends the whole state with isPlaying,
 * and leaves out the volume for a player that takes no volume.
 */
internal fun mergePlayer(old: PlayerState, b: JsonObject, at: Long): PlayerState = old.copy(
    title = b.str("title") ?: old.title,
    artist = b.str("artist") ?: old.artist,
    album = b.str("album") ?: old.album,
    playing = b.bool("isPlaying") ?: old.playing,
    position = b.long("pos") ?: old.position,
    length = b.long("length") ?: old.length,
    canSeek = b.bool("canSeek") ?: old.canSeek,
    canGoNext = b.bool("canGoNext") ?: old.canGoNext,
    canGoPrevious = b.bool("canGoPrevious") ?: old.canGoPrevious,
    volume = if ("isPlaying" in b) b.long("volume")?.toInt()?.coerceIn(0, 100) else old.volume,
    artUrl = b.str("albumArtUrl")?.let(::albumArtUrl) ?: old.artUrl,
    updatedAt = at,
)

/** The longest album art address that the phone loads. */
private const val MAX_ART_URL = 2048

/**
 * The album art address that the phone loads: an https address, or empty.
 * The computer sends only web addresses, and the phone loads no address
 * without TLS.
 */
internal fun albumArtUrl(raw: String): String {
    val url = raw.trim()
    return if (url.length <= MAX_ART_URL && url.startsWith("https://", ignoreCase = true) && url.none { it.isWhitespace() }) url else ""
}
