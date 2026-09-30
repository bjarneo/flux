package org.omarchy.flux.desktop

import android.util.Log
import android.view.Surface
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.omarchy.flux.core.Device
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.stream.PinnedStream
import java.net.ServerSocket
import java.net.Socket

private const val TAG = "FluxDesktop"
private const val CONNECT_TIMEOUT_MS = 15_000

/**
 * The screen of a computer on this phone. The session opens a listener,
 * the computer connects and streams 1 monitor, and a [VideoDecoder] shows
 * the frames on the surface of the screen. 1 session runs at a time.
 */
object DesktopSession {
    enum class Phase { Idle, Connecting, Live, Error }

    data class Status(
        val phase: Phase = Phase.Idle,
        val message: String = "",
        val deviceId: String? = null,
        val monitor: String = "",
        val monitors: List<String> = emptyList(),
        /** The size of the video, or 0 before the computer tells it. */
        val width: Int = 0,
        val height: Int = 0,
    ) {
        val active: Boolean get() = phase == Phase.Connecting || phase == Phase.Live
    }

    private val _status = MutableStateFlow(Status())
    val status: StateFlow<Status> = _status

    private val lock = Any()
    private var run: Run? = null
    private var surface: Surface? = null

    /** Starts the stream from [deviceId]. A running stream stops first. [monitor] selects a monitor of the computer. */
    fun start(core: FluxCore, deviceId: String, monitor: String? = null) {
        val next = Run(core, deviceId, monitor)
        val old = synchronized(lock) {
            val old = run
            run = next
            next.surface = surface
            old
        }
        old?.stop(notify = true)
        val name = core.device(deviceId)?.identity?.deviceName ?: "the computer"
        _status.value = Status(Phase.Connecting, "Waiting for $name…", deviceId, monitor ?: "")
        next.thread.start()
    }

    /** Stops the stream. With [notify], the computer gets "stop". */
    fun stop(notify: Boolean = true, status: Status = Status()) {
        val old = synchronized(lock) {
            val old = run
            run = null
            old
        }
        old?.stop(notify)
        _status.value = status
    }

    /** Stops the stream when it comes from [deviceId], for example after an unpair. */
    fun stopFor(deviceId: String, message: String) {
        val old = synchronized(lock) {
            run?.takeIf { it.deviceId == deviceId }?.also { run = null }
        } ?: return
        old.stop(notify = false)
        _status.value = Status(Phase.Error, message, deviceId)
    }

    /** Sets the surface that shows the video, or null when the view goes. */
    fun attach(s: Surface?) {
        synchronized(lock) {
            surface = s
            run?.surface = s
        }
    }

    /** Handles flux.desktop from the computer. The core lock is held, so the work moves to [FluxCore.io]. */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        val reply = DesktopReply.parse(p) ?: return
        if (_status.value.deviceId != d.id) return
        val name = d.identity.deviceName
        when (reply) {
            is DesktopReply.Live -> {
                val s = _status.value
                if (s.active) {
                    _status.value = s.copy(
                        phase = Phase.Live, message = "Shows $name", monitor = reply.monitor, monitors = reply.monitors,
                        width = if (s.width > 0) s.width else reply.width, height = if (s.height > 0) s.height else reply.height,
                    )
                }
            }
            is DesktopReply.Failed -> core.io.execute { stop(notify = false, Status(Phase.Error, reply.message, d.id)) }
            DesktopReply.Stop -> core.io.execute { stop(notify = false, Status(Phase.Idle, "Stopped on $name", d.id)) }
        }
    }

    /** Sets the video size that the stream or the decoder reports. */
    private fun setSize(r: Run, w: Int, h: Int) {
        synchronized(lock) { if (run !== r) return }
        val s = _status.value
        if (s.width != w || s.height != h) _status.value = s.copy(width = w, height = h)
    }

    /** Ends a run that the computer or the network ended. */
    private fun ended(r: Run, message: String) {
        val current = synchronized(lock) {
            if (run === r) {
                run = null
                true
            } else {
                false
            }
        }
        if (current) _status.value = Status(Phase.Error, message, r.deviceId)
    }

    /** 1 stream: its thread, its sockets, and its decoder. */
    private class Run(val core: FluxCore, val deviceId: String, val monitor: String?) {
        val thread = Thread(::work, "flux-desktop").apply { isDaemon = true }
        @Volatile var stopped = false
        @Volatile var surface: Surface? = null
        @Volatile private var server: ServerSocket? = null
        @Volatile private var socket: Socket? = null

        // The decoder and its surface belong to the thread.
        private var decoder: VideoDecoder? = null
        private var decoderSurface: Surface? = null

        fun stop(notify: Boolean) {
            if (stopped) return
            stopped = true
            runCatching { server?.close() }
            runCatching { socket?.close() }
            // The link sends in order, so a stop goes out before the start of a next run.
            if (notify) core.device(deviceId)?.send(DesktopPackets.stop())
        }

        private fun work() {
            val d = core.device(deviceId)
            val name = d?.identity?.deviceName ?: "The computer"
            try {
                if (d == null) error("$name is not known")
                if (Types.FLUX_DESKTOP !in d.identity.incoming) error("Update Flux on $name to show its screen")
                val ssl = PinnedStream.accept(core, d, CONNECT_TIMEOUT_MS, { srv ->
                    if (stopped) runCatching { srv.close() } else server = srv
                }) { port -> DesktopPackets.start(port, monitor) }
                server = null
                socket = ssl
                if (stopped) {
                    runCatching { ssl.close() }
                    return
                }
                read(FrameReader(ssl.inputStream))
                if (!stopped) ended(this, "$name stopped the stream")
            } catch (e: Exception) {
                if (!stopped) {
                    Log.i(TAG, "stream ended: ${e.message}")
                    ended(this, e.message ?: "The connection to $name closed")
                }
            } finally {
                decoder?.release()
                decoder = null
                runCatching { socket?.close() }
            }
        }

        /** Reads frames until the end of the stream and shows them. */
        private fun read(frames: FrameReader) {
            var size = 0 to 0
            var config: Pair<ByteArray, ByteArray>? = null
            while (!stopped) {
                val f = frames.next() ?: return
                // The pairing can end while the stream runs.
                if (core.device(deviceId)?.paired != true) error("The computer is no longer paired")
                when {
                    f.isFormat -> f.size()?.let {
                        size = it
                        setSize(this, it.first, it.second)
                    }
                    f.isConfig -> config = codecConfig(f.data, f.length)
                    else -> {
                        // A new surface needs a new decoder, which starts at a key frame.
                        val s = surface
                        if (s !== decoderSurface) {
                            decoder?.release()
                            decoder = null
                            decoderSurface = null
                        }
                        val c = config
                        if (decoder == null && s != null && s.isValid && c != null && f.isKey) {
                            decoder = try {
                                VideoDecoder(s, size.first.coerceAtLeast(16), size.second.coerceAtLeast(16), c) { w, h -> setSize(this, w, h) }
                            } catch (e: Exception) {
                                throw IllegalStateException("This phone cannot show the stream: ${e.message}", e)
                            }
                            decoderSurface = s
                        }
                        try {
                            decoder?.feed(f.data, f.length, f.isKey)
                        } catch (e: Exception) {
                            // For example, the surface went away. The next key frame starts a new decoder.
                            Log.i(TAG, "decoder failed: ${e.message}")
                            decoder?.release()
                            decoder = null
                            decoderSurface = null
                        }
                    }
                }
            }
        }
    }
}
