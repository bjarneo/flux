package org.omarchy.flux.core

import android.util.Log
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
     * [SystemClock.elapsedRealtime]. The automatic reader ignores the log
     * lines for [ClipGate.SELF_WRITE_MS] after this time, because a Flux
     * write also makes the denial line.
     */
    @Volatile var selfWriteAt: Long = 0L

    /**
     * The longest text from a computer that Flux puts on the clipboard, in
     * UTF-8 bytes. Android sends a clip through a binder call, and a much
     * larger clip stops the app.
     */
    const val MAX_CLIPBOARD_TEXT = 256 * 1024

    /**
     * The longest text that the automatic sync sends to the computers, in
     * UTF-8 bytes. `fluxd` takes up to 1 MiB from a device.
     */
    const val MAX_AUTO_TEXT = 1 shl 20

    fun onConnected(core: FluxCore, d: Device) {
        sendBattery(core, d)
        HerdrSync.onConnected(d)
        // New images that no computer took yet go out now.
        CaptureWatch.poke()
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
        putRemoteText(core, d.identity.deviceName, text)
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
        // The write makes the same denial line, so the reader ignores it.
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
                core.toast(
                    when {
                        sent > 0 -> "Image sent to $name"
                        sent < 0 -> "The image is larger than ${ClipImage.MAX_BYTES shr 20} MB"
                        else -> "Sending the image failed"
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
        core.toast("Clipboard sent to ${d.identity.deviceName}")
        return true
    }

    /**
     * Called when the local clipboard changes, from the listener and from
     * the automatic reader. It sends the new clip to each connected paired
     * computer. A clip that its app marks as sensitive, for example a
     * password, stays on the phone.
     */
    fun onLocalClipboard(core: FluxCore) {
        sendClipboardToAll(core, manual = false)
    }

    /**
     * Sends the clipboard to each connected paired computer. Call it on the
     * main thread while a window of Flux has focus. [manual] is true for a
     * user action, for example the tile: it shows 1 toast with the result
     * and sends the current clip again. The automatic path ([manual] false)
     * shows no toast and drops a clip that it sent before, a clip that came
     * from a computer, and a clip that its app marks as sensitive.
     */
    fun sendClipboardToAll(core: FluxCore, manual: Boolean): Boolean {
        if (!core.settings.syncClipboard) {
            if (manual) core.toast("Turn on Sync clipboard first")
            return false
        }
        val computers = core.connectedPaired()
        if (computers.isEmpty()) {
            if (manual) core.toast("No computer is connected")
            return false
        }
        val stamp = Android.clipTimestamp(core.app)
        // The same clip does not go out twice, for example from 2 listeners.
        if (!manual && stamp != 0L && stamp == lastSentStamp) return false
        Android.clipboardImage(core.app)?.let { (uri, mime) ->
            if (!manual && uri == ClipImage.lastRemote) return false
            val targets = computers.filter { Types.FLUX_CLIPBOARD_IMAGE in it.identity.incoming }
            if (targets.isEmpty()) {
                if (manual) core.toast("Update Flux on the computer to send images")
                return false
            }
            lastSentStamp = stamp
            core.settings.clipboardTimestamp = System.currentTimeMillis()
            ClipImage.send(core, targets, uri, mime, manual = manual) { sent ->
                if (manual) {
                    core.toast(
                        when {
                            sent > 0 -> if (sent == 1) "Image sent to ${targets[0].identity.deviceName}" else "Image sent to $sent computers"
                            sent < 0 -> "The image is larger than ${ClipImage.MAX_BYTES shr 20} MB"
                            else -> "Sending the image failed"
                        },
                    )
                }
            }
            return true
        }
        val text = Android.clipboardText(core.app, automatic = true)
        if (text.isNullOrEmpty()) {
            if (manual) core.toast("The clipboard is empty")
            return false
        }
        if (!manual && text == lastRemoteClip) return false
        if (text.toByteArray(Charsets.UTF_8).size > MAX_AUTO_TEXT) {
            if (manual) core.toast("The text is too large for the clipboard")
            return false
        }
        lastSentStamp = stamp
        core.settings.clipboardTimestamp = System.currentTimeMillis()
        computers.forEach { it.send(Packet(Types.CLIPBOARD, bodyOf("content" to text))) }
        if (manual) {
            core.toast(if (computers.size == 1) "Clipboard sent to ${computers[0].identity.deviceName}" else "Clipboard sent to ${computers.size} computers")
        }
        return true
    }

    /**
     * Sends selected text to each connected paired computer, for the "Send
     * to computer" text action. It shows 1 toast with the result.
     */
    fun sendTextToComputers(core: FluxCore, text: String?) {
        val body = text?.takeIf { it.isNotBlank() }
        if (body == null) {
            core.toast("No text to send")
            return
        }
        if (!core.settings.syncClipboard) {
            core.toast("Turn on Sync clipboard first")
            return
        }
        if (body.toByteArray(Charsets.UTF_8).size > MAX_AUTO_TEXT) {
            core.toast("The text is too large for the clipboard")
            return
        }
        val computers = core.connectedPaired()
        if (computers.isEmpty()) {
            core.toast("No computer is connected")
            return
        }
        computers.forEach { it.send(Packet(Types.CLIPBOARD, bodyOf("content" to body))) }
        core.toast(if (computers.size == 1) "Sent to ${computers[0].identity.deviceName}" else "Sent to ${computers.size} computers")
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

    fun runCommand(core: FluxCore, id: String, cmd: RemoteCommand) {
        val d = core.device(id)
        if (d == null || !d.send(Packet(Types.RUN_COMMAND_REQUEST, bodyOf("key" to cmd.key)))) {
            Log.i("FluxCommands", "not sent: ${cmd.key}, no open link")
            core.toast("Not connected. Try again in a moment")
            return
        }
        Log.i("FluxCommands", "sent: ${cmd.key}")
        core.toast("Ran “${cmd.name}”")
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
    updatedAt = at,
)
