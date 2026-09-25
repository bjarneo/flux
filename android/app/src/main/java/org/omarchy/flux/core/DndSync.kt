package org.omarchy.flux.core

import android.app.NotificationManager
import android.content.Context
import android.os.SystemClock
import android.util.Log
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf

private const val TAG = "FluxDnd"

/**
 * Syncs Do Not Disturb between this phone and the computers with flux.dnd.
 * Each side sends the state only after a local change. [guard] keeps a
 * change from going back to the side that made it.
 */
object DndSync {
    private val guard = DndGuard()

    private fun manager(context: Context) = context.getSystemService(NotificationManager::class.java)

    /** Reports whether Flux may read and set Do Not Disturb. */
    fun hasAccess(context: Context): Boolean = manager(context)?.isNotificationPolicyAccessGranted == true

    /** Reports whether Do Not Disturb is on. Every filter that is not "all" counts as on. */
    fun isOn(context: Context): Boolean {
        val f = manager(context)?.currentInterruptionFilter ?: return false
        return f != NotificationManager.INTERRUPTION_FILTER_ALL && f != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
    }

    /** Sets the start value. The service calls it when it starts, so that the start is not a change. */
    fun start(context: Context) {
        guard.local(isOn(context), SystemClock.elapsedRealtime())
    }

    /** Handles a change of the interruption filter on this phone. */
    fun onLocalChange(core: FluxCore) {
        val on = isOn(core.app)
        val change = guard.local(on, SystemClock.elapsedRealtime())
        if (!change || !core.settings.syncDnd || !hasAccess(core.app)) return
        Log.i(TAG, "Do Not Disturb is ${if (on) "on" else "off"} on this phone")
        send(core, on, except = null)
    }

    /**
     * Handles flux.dnd from a computer. The core lock is held, so the work
     * moves to [FluxCore.io].
     */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        val on = p.bool("on") ?: return
        if (!core.settings.syncDnd || !hasAccess(core.app)) return
        if (!guard.remote(on, SystemClock.elapsedRealtime())) return
        val from = d.id
        core.io.execute {
            val filter = if (on) NotificationManager.INTERRUPTION_FILTER_PRIORITY else NotificationManager.INTERRUPTION_FILTER_ALL
            runCatching { manager(core.app)?.setInterruptionFilter(filter) }
                .onFailure { Log.w(TAG, "set Do Not Disturb failed", it) }
            send(core, on, except = from)
        }
    }

    /** Sends the state to each connected computer that accepts flux.dnd, except [except]. */
    private fun send(core: FluxCore, on: Boolean, except: String?) {
        for (d in core.connectedPaired()) {
            if (d.id == except || Types.FLUX_DND !in d.identity.incoming) continue
            d.send(Packet(Types.FLUX_DND, bodyOf("on" to on)))
        }
    }
}
