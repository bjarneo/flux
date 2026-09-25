package org.omarchy.flux.mic

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.omarchy.flux.core.Device
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.stream.PinnedStream
import java.net.ServerSocket
import javax.net.ssl.SSLSocket

private const val TAG = "FluxMic"

/** How long the phone waits for the computer to connect. */
private const val CONNECT_TIMEOUT_MS = 10_000

/**
 * The phone as microphone: 1 stream at a time. The phone records 48 kHz
 * mono PCM and writes it to the computer, which plays it into the source
 * Flux Microphone. The stream runs while a screen that uses it is open.
 */
object MicSession {
    enum class Phase { Idle, Connecting, Starting, Live, Error }

    data class Status(
        val phase: Phase = Phase.Idle,
        val message: String = "",
        val deviceId: String? = null,
    ) {
        val active: Boolean get() = phase == Phase.Connecting || phase == Phase.Starting || phase == Phase.Live
    }

    private val _status = MutableStateFlow(Status())
    val status: StateFlow<Status> = _status

    private val _level = MutableStateFlow(0f)
    /** The peak input level, from 0 to 1, about 15 times per second. */
    val level: StateFlow<Float> = _level

    private val lock = Any()
    private var deviceId: String? = null
    private var server: ServerSocket? = null
    private var socket: SSLSocket? = null
    private var attempt = 0

    /** Starts a stream to [deviceId]. A running stream stops first. */
    fun start(core: FluxCore, deviceId: String) {
        stop(core, notify = true)
        val id = synchronized(lock) {
            this.deviceId = deviceId
            ++attempt
        }
        val name = core.device(deviceId)?.identity?.deviceName ?: "the computer"
        _status.value = Status(Phase.Connecting, "Waiting for $name…", deviceId)
        core.io.execute {
            try {
                val d = core.device(deviceId) ?: error("$name is not known")
                if (Types.FLUX_MIC !in d.identity.incoming) error("Update Flux on $name to use this phone as a microphone")
                val ssl = PinnedStream.accept(core, d, CONNECT_TIMEOUT_MS, { srv ->
                    val keep = synchronized(lock) { if (attempt == id) { server = srv; true } else false }
                    if (!keep) runCatching { srv.close() }
                }) { port -> MicPackets.start(port) }
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
                _status.value = Status(Phase.Starting, "Starting Flux Microphone on $name…", deviceId)
                record(d, ssl, id)
            } catch (e: Exception) {
                if (!current(id)) return@execute
                Log.i(TAG, "microphone stopped: ${e.message}")
                val message = when (e) {
                    is SecurityException -> "Allow the microphone for Flux in the app settings"
                    is java.io.IOException -> "The connection to $name closed"
                    else -> e.message ?: "The microphone could not start"
                }
                end(core, notify = true, Status(Phase.Error, message, deviceId), id)
            }
        }
    }

    /** Stops the stream. With [notify], the computer gets flux.mic "stop". */
    fun stop(core: FluxCore, notify: Boolean, status: Status = Status()) {
        val id = synchronized(lock) { attempt }
        end(core, notify, status, id)
    }

    /** Handles flux.mic from the computer. The core lock is held, so the work moves to [FluxCore.io]. */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        val reply = MicReply.parse(p) ?: return
        val mine = synchronized(lock) { deviceId == d.id }
        if (!mine) return
        val name = d.identity.deviceName
        when (reply) {
            is MicReply.Live -> if (_status.value.active) _status.value = Status(Phase.Live, "Live on $name as ${reply.source}", d.id)
            is MicReply.Failed -> core.io.execute { stop(core, notify = false, Status(Phase.Error, reply.message, d.id)) }
            MicReply.Stop -> core.io.execute { stop(core, notify = false, Status(Phase.Idle, "Stopped on $name", d.id)) }
        }
    }

    private fun current(id: Int): Boolean = synchronized(lock) { attempt == id }

    /** Records and writes 10 ms chunks until the stream ends. It runs on the io thread of the stream. */
    @SuppressLint("MissingPermission")
    private fun record(d: Device, ssl: SSLSocket, id: Int) {
        val rec = openRecorder()
        val chunk = ShortArray(MicPackets.RATE / 100)
        val bytes = ByteArray(chunk.size * 2)
        val out = ssl.outputStream
        var lastLevel = 0L
        try {
            rec.startRecording()
            while (current(id)) {
                val n = rec.read(chunk, 0, chunk.size)
                if (n < 0) error("The microphone stopped (error $n)")
                if (n == 0) continue
                Pcm.toLittleEndian(chunk, n, bytes)
                out.write(bytes, 0, n * 2)
                val now = SystemClock.elapsedRealtime()
                if (now - lastLevel >= 66) {
                    lastLevel = now
                    _level.value = Pcm.peak(chunk, n)
                }
                if (!d.online) error("The connection to ${d.identity.deviceName} closed")
            }
        } finally {
            runCatching { rec.stop() }
            rec.release()
            _level.value = 0f
        }
    }

    /**
     * Opens the microphone with voice processing, as a call app does. A phone
     * that has no voice source gets the plain microphone.
     */
    @SuppressLint("MissingPermission")
    private fun openRecorder(): AudioRecord {
        val min = AudioRecord.getMinBufferSize(MicPackets.RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val size = maxOf(min, MicPackets.RATE / 10 * 2)
        for (source in listOf(MediaRecorder.AudioSource.VOICE_COMMUNICATION, MediaRecorder.AudioSource.MIC)) {
            val rec = AudioRecord(source, MicPackets.RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, size)
            if (rec.state == AudioRecord.STATE_INITIALIZED) return rec
            rec.release()
        }
        error("This phone cannot record 48 kHz audio")
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
        if (notify && target != null && (sock != null || srv != null)) core.device(target)?.send(MicPackets.stop())
        _level.value = 0f
        _status.value = status
    }
}

/** The microphone settings that the phone keeps. */
object MicSettings {
    private const val PREFS = "flux-mic"
    private const val WITH_WEBCAM = "with-webcam"

    private val _withWebcam = MutableStateFlow(false)
    /** True when the Webcam mode also sends the microphone. */
    val withWebcam: StateFlow<Boolean> = _withWebcam

    fun load(context: Context) {
        _withWebcam.value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(WITH_WEBCAM, false)
    }

    fun setWithWebcam(context: Context, on: Boolean) {
        _withWebcam.value = on
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(WITH_WEBCAM, on).apply()
    }
}
