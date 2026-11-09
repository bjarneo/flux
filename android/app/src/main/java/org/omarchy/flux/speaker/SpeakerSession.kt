package org.omarchy.flux.speaker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Process
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.omarchy.flux.core.Device
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.desktop.FrameReader
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.stream.PinnedStream
import java.io.IOException
import java.net.ServerSocket
import javax.net.ssl.SSLSocket

private const val TAG = "FluxSpeaker"

/** How long the phone waits for the computer to connect. */
private const val CONNECT_TIMEOUT_MS = 10_000

/** The largest frame that the phone reads. The computer sends frames of 3840 bytes. */
private const val MAX_FRAME = 64 * 1024

/**
 * The phone as a speaker of the computer: 1 stream at a time. The computer
 * captures the audio of its default output and writes it to the phone,
 * which plays it as media. The phone then plays it on its own speaker or
 * on its Bluetooth headphones. The stream keeps running in the background,
 * see [org.omarchy.flux.stream.StreamService].
 */
object SpeakerSession {
    enum class Phase { Idle, Connecting, Live, Error }

    /**
     * The state of the stream. [muted] is the output of the computer that
     * the computer muted while the phone plays, or empty.
     */
    data class Status(
        val phase: Phase = Phase.Idle,
        val message: String = "",
        val deviceId: String? = null,
        val muted: String = "",
    ) {
        val active: Boolean get() = phase == Phase.Connecting || phase == Phase.Live
    }

    private val _status = MutableStateFlow(Status())
    val status: StateFlow<Status> = _status

    private val lock = Any()
    private var deviceId: String? = null
    private var server: ServerSocket? = null
    private var socket: SSLSocket? = null
    private var attempt = 0

    /** Starts a stream from [deviceId]. A running stream stops first. */
    fun start(core: FluxCore, deviceId: String) {
        stop(core, notify = true)
        val id = synchronized(lock) {
            this.deviceId = deviceId
            ++attempt
        }
        val name = core.device(deviceId)?.identity?.deviceName ?: "the computer"
        _status.value = Status(Phase.Connecting, "Connecting to $name…", deviceId)
        core.io.execute {
            try {
                val d = core.device(deviceId) ?: error("$name is not known")
                if (Types.FLUX_SPEAKER !in d.identity.incoming) error("Update Flux on $name to play its audio on this phone")
                val mute = SpeakerSettings.muteComputer.value
                val ssl = PinnedStream.accept(core, d, CONNECT_TIMEOUT_MS, { srv ->
                    val keep = synchronized(lock) { if (attempt == id) { server = srv; true } else false }
                    if (!keep) runCatching { srv.close() }
                }) { port -> SpeakerPackets.start(port, mute) }
                val keep = synchronized(lock) {
                    if (attempt != id) false else {
                        server = null
                        socket = ssl
                        true
                    }
                }
                if (!keep) {
                    runCatching { ssl.close() }
                    return@execute
                }
                play(core, d, ssl, id)
                // The computer closed the stream without a stop packet first.
                end(core, notify = false, Status(Phase.Idle, "$name stopped the audio", deviceId), id)
            } catch (e: Exception) {
                if (!current(id)) return@execute
                Log.i(TAG, "speaker stopped: ${e.message}")
                val message = when (e) {
                    is IOException -> "The connection to $name closed"
                    else -> e.message ?: "The audio of $name could not play"
                }
                end(core, notify = true, Status(Phase.Error, message, deviceId), id)
                core.toast(message)
            }
        }
    }

    /** True while a stream from [deviceId] runs or starts. */
    fun runsTo(deviceId: String): Boolean = _status.value.active && synchronized(lock) { this.deviceId == deviceId }

    /** Stops the stream. With [notify], the computer gets flux.speaker "stop". */
    fun stop(core: FluxCore, notify: Boolean, status: Status = Status()) {
        val id = synchronized(lock) { attempt }
        end(core, notify, status, id)
    }

    /** Stops the stream when it comes from [deviceId], for example after an unpair. */
    fun stopFor(core: FluxCore, deviceId: String, message: String) {
        val id = synchronized(lock) { attempt.takeIf { this.deviceId == deviceId } } ?: return
        end(core, notify = false, Status(Phase.Error, message, deviceId), id)
    }

    /**
     * Saves the mute choice, and tells the computer of a stream that runs.
     * Call it from the main thread.
     */
    fun setMute(core: FluxCore, context: Context, on: Boolean) {
        SpeakerSettings.setMuteComputer(context, on)
        val target = synchronized(lock) { deviceId } ?: return
        if (!_status.value.active) return
        core.io.execute { core.device(target)?.send(SpeakerPackets.mute(on)) }
    }

    /** Handles flux.speaker from the computer. The core lock is held, so the work moves to [FluxCore.io]. */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        val reply = SpeakerReply.parse(p) ?: return
        val mine = synchronized(lock) { deviceId == d.id }
        if (!mine) return
        val name = d.identity.deviceName
        when (reply) {
            SpeakerReply.Live -> _status.value.let { s ->
                if (s.active) _status.value = s.copy(phase = Phase.Live, message = "The audio of $name plays on this phone")
            }
            is SpeakerReply.Muted -> {
                _status.value.let { s -> if (s.active) _status.value = s.copy(muted = reply.output) }
                reply.message?.let { core.toast(it) }
            }
            is SpeakerReply.Failed -> core.io.execute {
                stop(core, notify = false, Status(Phase.Error, reply.message, d.id))
                core.toast(reply.message)
            }
            SpeakerReply.Stop -> core.io.execute { stop(core, notify = false, Status(Phase.Idle, "Stopped on $name", d.id)) }
        }
    }

    private fun current(id: Int): Boolean = synchronized(lock) { attempt == id }

    /**
     * Plays the frames of the stream until it ends. It runs on the io
     * thread of the stream, with the priority of audio. The phone takes the
     * audio focus, so another player of the phone pauses. When another app
     * takes the focus for good, or the headphones disconnect, the stream
     * stops.
     */
    private fun play(core: FluxCore, d: Device, ssl: SSLSocket, id: Int) {
        val app = core.app
        val name = d.identity.deviceName
        val audio = app.getSystemService(AudioManager::class.java)
        val player = SpeakerPlayer()
        val endWith = { message: String ->
            core.io.execute {
                if (current(id)) {
                    end(core, notify = true, Status(Phase.Idle, message, d.id), id)
                    core.toast(message)
                }
            }
        }
        val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(player.attributes)
            .setOnAudioFocusChangeListener { change ->
                when (change) {
                    AudioManager.AUDIOFOCUS_LOSS -> endWith("Another app plays audio, so the audio of $name stopped")
                    // A call or a voice prompt: the stream goes on, silent, until it ends.
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> player.setVolume(0f)
                    AudioManager.AUDIOFOCUS_GAIN -> player.setVolume(1f)
                }
            }
            .build()
        val noisy = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    endWith("The headphones disconnected, so the audio of $name stopped")
                }
            }
        }
        val priority = Process.getThreadPriority(Process.myTid())
        var focused = false
        var registered = false
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            if (audio.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_FAILED) {
                error("The phone plays other audio, for example a call. End it, then try again")
            }
            focused = true
            ContextCompat.registerReceiver(app, noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), ContextCompat.RECEIVER_NOT_EXPORTED)
            registered = true
            val frames = FrameReader(ssl.inputStream, MAX_FRAME)
            while (current(id)) {
                val f = frames.next() ?: return
                if (!f.isAudio) continue
                // The pairing can end while the stream runs.
                if (!d.paired) error("$name is no longer paired")
                player.write(f.data, f.length)
            }
        } finally {
            if (player.dropped > 0) Log.i(TAG, "dropped ${player.dropped} bytes to keep the delay short")
            if (registered) runCatching { app.unregisterReceiver(noisy) }
            if (focused) runCatching { audio.abandonAudioFocusRequest(focus) }
            player.close()
            runCatching { Process.setThreadPriority(priority) }
        }
    }

    private fun end(core: FluxCore, notify: Boolean, status: Status, id: Int) {
        val (target, srv, sock) = synchronized(lock) {
            if (attempt != id) return
            attempt++
            val r = Triple(deviceId, server, socket)
            deviceId = null
            server = null
            socket = null
            r
        }
        runCatching { srv?.close() }
        runCatching { sock?.close() }
        if (notify && target != null && (sock != null || srv != null)) core.device(target)?.send(SpeakerPackets.stop())
        _status.value = status
    }
}

/** The speaker settings that the phone keeps. */
object SpeakerSettings {
    private const val PREFS = "flux-speaker"
    private const val MUTE_COMPUTER = "mute-computer"

    private val _muteComputer = MutableStateFlow(false)

    /** True when the computer mutes its default output while this phone plays its audio. */
    val muteComputer: StateFlow<Boolean> = _muteComputer

    fun load(context: Context) {
        _muteComputer.value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(MUTE_COMPUTER, false)
    }

    fun setMuteComputer(context: Context, on: Boolean) {
        _muteComputer.value = on
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putBoolean(MUTE_COMPUTER, on) }
    }
}
