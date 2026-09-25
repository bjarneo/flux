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
import org.omarchy.flux.service.FluxService
import org.omarchy.flux.ui.ApproveActivity

/**
 * The approval and enrollment requests from the computers. The phone
 * shows 1 request at a time. docs/approve.md is the security design.
 */
object Approvals {
    private const val TAG = "FluxApprove"
    private val main = Handler(Looper.getMainLooper())

    private val _current = MutableStateFlow<ApproveRequest?>(null)

    /** The request that the Approve screen shows, or null. */
    val current: StateFlow<ApproveRequest?> = _current

    /** Handles flux.approve from a paired computer. The core lock is held. */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        when (p.string("kind")) {
            "cancel" -> {
                val id = p.string("id")
                if (id != null && _current.value?.id == id) main.post { clear(core.app, id) }
            }
            "request", "enroll" -> receive(core, d, p)
        }
    }

    private fun receive(core: FluxCore, d: Device, p: Packet) {
        val id = p.string("id") ?: return
        val r = ApproveMessage.parse(p, d.id, d.identity.deviceName)
        val problem = when {
            r == null -> "The request is not valid"
            !ApproveMessage.fresh(r, System.currentTimeMillis() / 1000) ->
                "The clocks of the phone and the computer differ by more than 10 minutes"
            r.kind == ApproveRequest.Kind.Approve && !ApproveKeys.has(d.id) ->
                "This phone has no key for the computer. Run: sudo flux approve enroll"
            _current.value != null && _current.value?.id != r.id -> "Another request is open on the phone"
            else -> null
        }
        if (problem != null || r == null) {
            Log.i(TAG, "refused a request from ${d.identity.deviceName}: $problem")
            d.send(ApproveMessage.failed(id, problem ?: "The request is not valid"))
            return
        }
        _current.value = r
        main.post {
            show(core.app, r)
            // The computer stops waiting at its timeout, so the screen closes too.
            main.postDelayed({ clear(core.app, r.id) }, r.timeoutSeconds * 1000L)
        }
    }

    private fun send(core: FluxCore, r: ApproveRequest, p: Packet): Boolean {
        val d = core.device(r.computerId) ?: return false
        return d.send(p)
    }

    /** Sends the signature of the approval message of the current request. */
    fun approve(core: FluxCore, r: ApproveRequest, signature: ByteArray): Boolean {
        val ok = send(core, r, ApproveMessage.approved(r.id, signature))
        clear(core.app, r.id)
        return ok
    }

    /** Sends the new public key and the proof of the current enrollment. */
    fun enrolled(core: FluxCore, r: ApproveRequest, spki: ByteArray, signature: ByteArray): Boolean {
        val ok = send(core, r, ApproveMessage.enrolled(r.id, spki, signature))
        clear(core.app, r.id)
        return ok
    }

    fun deny(core: FluxCore, r: ApproveRequest? = _current.value) {
        if (r == null) return
        send(core, r, ApproveMessage.denied(r.id))
        clear(core.app, r.id)
    }

    fun fail(core: FluxCore, r: ApproveRequest, message: String) {
        send(core, r, ApproveMessage.failed(r.id, message))
        clear(core.app, r.id)
    }

    /** Closes the request [id], and its notification. */
    fun clear(context: Context, id: String) {
        if (_current.value?.id != id) return
        _current.value = null
        NotificationManagerCompat.from(context).cancel(Android.ID_APPROVE)
    }

    @SuppressLint("MissingPermission")
    private fun show(context: Context, r: ApproveRequest) {
        val open = PendingIntent.getActivity(
            context, 10, Intent(context, ApproveActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val deny = PendingIntent.getService(
            context, 11, Intent(context, FluxService::class.java).setAction(FluxService.ACTION_APPROVE_DENY),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, Android.CHANNEL_APPROVE)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle(if (r.kind == ApproveRequest.Kind.Approve) "Approve ${r.service} on ${r.host}?" else "Enroll this phone on ${r.host}?")
            .setContentText(ApproveMessage.question(r))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setFullScreenIntent(open, true)
            .setContentIntent(open)
            .setOngoing(true)
            .setTimeoutAfter(r.timeoutSeconds * 1000L)
            .addAction(0, "Deny", deny)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(Android.ID_APPROVE, n) }
        if (FluxCore.foreground) {
            runCatching { context.startActivity(Intent(context, ApproveActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
    }
}
