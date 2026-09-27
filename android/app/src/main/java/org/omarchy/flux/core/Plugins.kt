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

    fun onConnected(core: FluxCore, d: Device) {
        sendBattery(core, d)
        HerdrSync.onConnected(d)
        // New images that no computer took yet go out now.
        CaptureWatch.poke()
        if (core.foreground && core.settings.syncClipboard) {
            main.post {
                val text = Android.clipboardText(core.app) ?: return@post
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
            Types.BATTERY_REQUEST -> sendBattery(core, d)
            Types.CLIPBOARD -> receiveClipboard(core, p.string("content"), null)
            Types.CLIPBOARD_CONNECT -> receiveClipboard(core, p.string("content"), p.long("timestamp") ?: 0L)
            Types.SHARE -> Share.receive(core, d, p)
            Types.SHARE_UPDATE -> Unit
            Types.NOTIFICATION -> {
                val n = ComputerNotification.from(p, d.id, d.identity.deviceName, System.currentTimeMillis()) ?: return
                if (n.cancel) Android.cancelFromComputer(core.app, n) else Android.showFromComputer(core.app, n)
            }
            Types.NOTIFICATION_REQUEST -> {
                if (p.bool("request") == true) NotificationSync.sendAll(d)
                p.string("cancel")?.let { NotificationSync.dismiss(it) }
            }
            Types.NOTIFICATION_REPLY -> {
                val id = p.string("requestReplyId") ?: return
                NotificationSync.reply(id, p.string("message") ?: "")
            }
            Types.NOTIFICATION_ACTION -> {
                val key = p.string("key") ?: return
                NotificationSync.action(key, p.string("action") ?: return)
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
            Types.FLUX_INPUT -> d.remoteInput = p.bool("enabled")
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

    private fun receiveClipboard(core: FluxCore, text: String?, timestamp: Long?) {
        if (text.isNullOrEmpty() || !core.settings.syncClipboard) return
        if (timestamp != null && timestamp in 1..core.settings.clipboardTimestamp) return
        lastRemoteClip = text
        main.post { Android.setClipboard(core.app, text) }
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
            ClipImage.send(core, listOf(d), uri, mime) { sent ->
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

    /** Called when the local clipboard changes while the app is on screen. */
    fun onLocalClipboard(core: FluxCore) {
        if (!core.settings.syncClipboard) return
        Android.clipboardImage(core.app)?.let { (uri, mime) ->
            if (uri == ClipImage.lastRemote) return
            val computers = core.connectedPaired().filter { Types.FLUX_CLIPBOARD_IMAGE in it.identity.incoming }
            if (computers.isEmpty()) return
            core.settings.clipboardTimestamp = System.currentTimeMillis()
            ClipImage.send(core, computers, uri, mime)
            return
        }
        val text = Android.clipboardText(core.app) ?: return
        if (text == lastRemoteClip) return
        core.settings.clipboardTimestamp = System.currentTimeMillis()
        core.connectedPaired().forEach { it.send(Packet(Types.CLIPBOARD, bodyOf("content" to text))) }
    }

    // --------------------------------------------------------- run commands

    private fun parseCommands(p: Packet): List<RemoteCommand> {
        val raw = p.body["commandList"] ?: return emptyList()
        val obj: JsonObject = (raw as? JsonObject)
            ?: runCatching { json.parseToJsonElement(raw.str() ?: "{}") as JsonObject }.getOrNull()
            ?: return emptyList()
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
 * Merges a kdeconnect.mpris packet from the computer into the state of a
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
