package org.omarchy.flux.core

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.omarchy.flux.R
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.service.FluxService
import org.omarchy.flux.ui.SshSignActivity

/**
 * The SSH key requests from the computers: the key, and the sign requests
 * of the ssh-agent of fluxd. The phone shows 1 sign request at a time.
 * docs/ssh.md is the design.
 */
object SshAgent {
    private const val TAG = "FluxSsh"
    private val main = Handler(Looper.getMainLooper())

    private val _current = MutableStateFlow<SshRequest?>(null)

    /** The sign request that the SSH screen shows, or null. */
    val current: StateFlow<SshRequest?> = _current

    /** Handles flux.ssh from a paired computer. The core lock is held. */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        when (p.string("kind")) {
            "key" -> d.send(SshMessage.keyPacket(SshKeys.spki()))
            "sign" -> receive(core, d, p)
            "cancel" -> {
                // Only the computer of the open request can cancel it.
                val id = p.string("id")
                val open = _current.value
                if (id != null && open?.id == id && open.computerId == d.id) main.post { clear(core.app, id) }
            }
        }
    }

    /** Sends the key, or no key, to each connected computer that takes flux.ssh. Call it after the key changes. */
    fun sendKey(core: FluxCore) {
        val packet = SshMessage.keyPacket(SshKeys.spki())
        for (d in core.connectedPaired()) {
            if (Types.FLUX_SSH in d.identity.incoming) d.send(packet)
        }
    }

    private fun receive(core: FluxCore, d: Device, p: Packet) {
        when (val parsed = SshMessage.parse(p, d.id, d.identity.deviceName, SshKeys.spki())) {
            SshMessage.Parsed.Invalid -> Log.i(TAG, "dropped a sign request without an ID from ${d.identity.deviceName}")
            is SshMessage.Parsed.Refused -> {
                Log.i(TAG, "refused a sign request from ${d.identity.deviceName}: ${parsed.message}")
                d.send(SshMessage.failed(parsed.id, parsed.message))
            }
            is SshMessage.Parsed.Ok -> {
                val r = parsed.request
                if (_current.value != null) {
                    d.send(SshMessage.failed(r.id, "Another SSH request is open on the phone"))
                    return
                }
                _current.value = r
                main.post {
                    show(core.app, r)
                    // The computer stops waiting at its timeout, so the screen closes too.
                    main.postDelayed({ clear(core.app, r.id) }, r.timeoutSeconds * 1000L)
                }
            }
        }
    }

    private fun send(core: FluxCore, r: SshRequest, p: Packet): Boolean = core.device(r.computerId)?.send(p) ?: false

    /** Sends the signature of the current request. */
    fun signed(core: FluxCore, r: SshRequest, der: ByteArray): Boolean {
        val ok = send(core, r, SshMessage.signed(r.id, der))
        clear(core.app, r.id)
        return ok
    }

    fun deny(core: FluxCore, r: SshRequest? = _current.value) {
        if (r == null) return
        send(core, r, SshMessage.denied(r.id))
        clear(core.app, r.id)
    }

    fun fail(core: FluxCore, r: SshRequest, message: String) {
        send(core, r, SshMessage.failed(r.id, message))
        clear(core.app, r.id)
    }

    /** Closes the requests of a computer that is no longer paired. */
    fun forget(context: Context, computerId: String) {
        _current.value?.takeIf { it.computerId == computerId }?.let { clear(context, it.id) }
    }

    /** Closes the request [id], and its notification. */
    fun clear(context: Context, id: String) {
        if (_current.value?.id != id) return
        _current.value = null
        NotificationManagerCompat.from(context).cancel(Android.ID_SSH)
    }

    @SuppressLint("MissingPermission")
    private fun show(context: Context, r: SshRequest) {
        val open = PendingIntent.getActivity(
            context, 12, Intent(context, SshSignActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val deny = PendingIntent.getService(
            context, 13, Intent(context, FluxService::class.java).setAction(FluxService.ACTION_SSH_DENY),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, Android.CHANNEL_APPROVE)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle("${SshMessage.action(r.what)} on ${r.computerName}?")
            .setContentText(r.program.ifEmpty { "SSH key of this phone" })
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setFullScreenIntent(open, true)
            .setContentIntent(open)
            .setOngoing(true)
            .setTimeoutAfter(r.timeoutSeconds * 1000L)
            .addAction(0, "Deny", deny)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(Android.ID_SSH, n) }
        if (FluxCore.foreground) {
            runCatching { context.startActivity(Intent(context, SshSignActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
    }
}
