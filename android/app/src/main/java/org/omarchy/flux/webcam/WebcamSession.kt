package org.omarchy.flux.webcam

import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.omarchy.flux.core.Device
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.net.Payload
import org.omarchy.flux.net.Tls
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import java.io.OutputStream
import java.net.ServerSocket
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLSocket

private const val TAG = "FluxWebcam"

/** How long the phone waits for the computer to connect. */
private const val CONNECT_TIMEOUT_MS = 10_000

/**
 * The network side of the webcam: 1 stream at a time. The phone listens,
 * announces the port with flux.webcam "start", and gives the socket to
 * [Listener.onConnected] when the computer connects.
 */
object WebcamSession {
    enum class Phase { Idle, Connecting, Starting, Live, Error }

    data class Status(
        val phase: Phase = Phase.Idle,
        val message: String = "",
        val device: String = "",
        val label: String = "",
    ) {
        val active: Boolean get() = phase == Phase.Connecting || phase == Phase.Starting || phase == Phase.Live
    }

    /** The camera side, which starts and stops the encoder. */
    interface Listener {
        fun onConnected(out: OutputStream)
        fun onEnded()
    }

    private val _status = MutableStateFlow(Status())
    val status: StateFlow<Status> = _status

    private val watchdog = Executors.newSingleThreadScheduledExecutor { Thread(it, "flux-webcam-watch").apply { isDaemon = true } }
    private val lock = Any()
    private var deviceId: String? = null
    private var server: ServerSocket? = null
    private var socket: SSLSocket? = null
    private var listener: Listener? = null
    private var watch: ScheduledFuture<*>? = null
    private var attempt = 0

    /** Starts a stream to [deviceId]. A running stream stops first. */
    fun start(core: FluxCore, deviceId: String, resolution: Resolution, listener: Listener) {
        stop(core, notify = true)
        val id = synchronized(lock) {
            this.deviceId = deviceId
            this.listener = listener
            ++attempt
        }
        val name = core.device(deviceId)?.identity?.deviceName ?: "the computer"
        _status.value = Status(Phase.Connecting, "Waiting for $name…")
        core.io.execute {
            try {
                val d = core.device(deviceId) ?: error("$name is not known")
                if (Types.FLUX_WEBCAM !in d.identity.incoming) error("Update Flux on $name to use this phone as a webcam")
                val cert = d.certificate ?: error("$name is not connected")
                val tls = core.tls ?: error("The network is not ready")
                val srv = Payload.openServer()
                srv.soTimeout = CONNECT_TIMEOUT_MS
                if (!current(id)) return@execute srv.close()
                synchronized(lock) { server = srv }
                if (!d.send(WebcamPackets.start(srv.localPort, resolution))) {
                    srv.close()
                    error("Not connected to $name")
                }
                val raw = srv.accept()
                raw.tcpNoDelay = true
                val ssl = tls.wrap(raw, server = true)
                val peer = Tls.peerCertificate(ssl)
                if (peer == null || !peer.encoded.contentEquals(cert.encoded)) {
                    runCatching { ssl.close() }
                    error("The connection did not come from $name")
                }
                runCatching { srv.close() }
                val l = synchronized(lock) {
                    if (attempt != id) null else {
                        server = null
                        socket = ssl
                        this.listener
                    }
                } ?: return@execute runCatching { ssl.close() }.let { }
                _status.value = Status(Phase.Starting, "Starting Flux Camera on $name…")
                l.onConnected(ssl.outputStream)
                watch(core, d, id)
            } catch (e: Exception) {
                if (!current(id)) return@execute
                Log.i(TAG, "webcam start failed: ${e.message}")
                val message = if (e is java.net.SocketTimeoutException) "$name did not connect. Update Flux on the computer." else e.message ?: "The webcam could not start"
                end(core, notify = true, Status(Phase.Error, message), id)
            }
        }
    }

    /** Stops the stream. With [notify], the computer gets flux.webcam "stop". */
    fun stop(core: FluxCore, notify: Boolean, status: Status = Status()) {
        val id = synchronized(lock) { attempt }
        end(core, notify, status, id)
    }

    /**
     * Handles flux.webcam from the computer. The core lock is held, so the
     * work moves to [FluxCore.io].
     */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        val reply = WebcamReply.parse(p) ?: return
        val mine = synchronized(lock) { deviceId == d.id }
        if (!mine) return
        val name = d.identity.deviceName
        when (reply) {
            is WebcamReply.Live -> {
                if (_status.value.active) _status.value = Status(Phase.Live, "Live on $name as ${reply.label}", reply.device, reply.label)
            }
            is WebcamReply.Failed -> core.io.execute { stop(core, notify = false, Status(Phase.Error, reply.message)) }
            WebcamReply.Stop -> core.io.execute { stop(core, notify = false, Status(Phase.Idle, "Stopped on $name")) }
        }
    }

    private fun current(id: Int): Boolean = synchronized(lock) { attempt == id }

    /** Checks the link every second and stops the stream when it drops. */
    private fun watch(core: FluxCore, d: Device, id: Int) {
        val future = watchdog.scheduleWithFixedDelay({
            if (current(id) && !d.online) end(core, notify = false, Status(Phase.Error, "The connection to ${d.identity.deviceName} closed"), id)
        }, 1, 1, TimeUnit.SECONDS)
        synchronized(lock) { watch?.cancel(false); watch = future }
    }

    private fun end(core: FluxCore, notify: Boolean, status: Status, id: Int) {
        val (target, srv, sock, l, w) = synchronized(lock) {
            if (attempt != id) return
            attempt++
            val r = Parts(deviceId, server, socket, listener, watch)
            deviceId = null
            server = null
            socket = null
            listener = null
            watch = null
            r
        }
        w?.cancel(false)
        l?.onEnded()
        runCatching { srv?.close() }
        runCatching { sock?.close() }
        if (notify && target != null && (sock != null || srv != null)) core.device(target)?.send(WebcamPackets.stop())
        _status.value = status
    }

    private data class Parts(
        val deviceId: String?,
        val server: ServerSocket?,
        val socket: SSLSocket?,
        val listener: Listener?,
        val watch: ScheduledFuture<*>?,
    )
}
