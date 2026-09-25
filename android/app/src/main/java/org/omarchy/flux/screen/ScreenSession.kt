package org.omarchy.flux.screen

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.omarchy.flux.core.Device
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.protocol.Packet

/**
 * The state of the screen mirror, for the UI. [ScreenMirrorService] runs
 * the mirror, and it registers a stop function while it runs.
 */
object ScreenSession {
    enum class Phase { Idle, Connecting, Live, Error }

    data class Status(
        val phase: Phase = Phase.Idle,
        val message: String = "",
        val deviceId: String? = null,
    ) {
        val active: Boolean get() = phase == Phase.Connecting || phase == Phase.Live
    }

    private val _status = MutableStateFlow(Status())
    val status: StateFlow<Status> = _status

    private val lock = Any()
    private var stopper: ((notify: Boolean, status: Status) -> Unit)? = null

    internal fun attach(stop: (notify: Boolean, status: Status) -> Unit) = synchronized(lock) { stopper = stop }

    internal fun detach(status: Status) {
        synchronized(lock) { stopper = null }
        _status.value = status
    }

    internal fun set(status: Status) {
        _status.value = status
    }

    /** Stops the mirror. With [notify], the computer gets flux.screen "stop". */
    fun stop(notify: Boolean = true, status: Status = Status()) {
        val s = synchronized(lock) { stopper }
        if (s != null) s(notify, status) else _status.value = status
    }

    /** Handles flux.screen from the computer. The core lock is held, so the work moves to [FluxCore.io]. */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        val reply = ScreenReply.parse(p) ?: return
        if (_status.value.deviceId != d.id) return
        val name = d.identity.deviceName
        when (reply) {
            is ScreenReply.Live -> if (_status.value.active) {
                _status.value = Status(Phase.Live, "Mirrors to $name", d.id)
            }
            is ScreenReply.Failed -> core.io.execute { stop(notify = false, Status(Phase.Error, reply.message, d.id)) }
            ScreenReply.Stop -> core.io.execute { stop(notify = false, Status(Phase.Idle, "Stopped on $name", d.id)) }
        }
    }
}
