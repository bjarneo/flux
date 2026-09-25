package org.omarchy.flux.service

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.content.ContextCompat
import org.omarchy.flux.core.CallEvent
import org.omarchy.flux.core.CallPackets
import org.omarchy.flux.core.CallTracker
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.LineState
import org.omarchy.flux.protocol.Types

private const val TAG = "FluxCalls"

/**
 * Sends the calls of this phone to the connected computers as
 * kdeconnect.telephony packets. FluxService runs it, so it works with the
 * app in the background.
 *
 * The call state comes from TelephonyCallback on Android 12 and later, and
 * from PhoneStateListener before that. The number needs READ_CALL_LOG. On
 * Android 12 and later, it comes from the PHONE_STATE broadcast, which can
 * arrive after the state. Then the phone sends ringing again with the
 * number, and the computer replaces its notification. The contact name
 * needs READ_CONTACTS.
 */
class CallMonitor(private val context: Context) {
    private val tm = context.getSystemService(TelephonyManager::class.java)
    private val tracker = CallTracker()
    private var number: String? = null
    private var listener: Any? = null
    private var receiver: BroadcastReceiver? = null

    val running: Boolean get() = listener != null

    fun start() {
        if (running || tm == null || !granted(Manifest.permission.READ_PHONE_STATE)) return
        runCatching {
            if (Build.VERSION.SDK_INT >= 31) {
                val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                    override fun onCallStateChanged(state: Int) = onState(state, null)
                }
                tm.registerTelephonyCallback(context.mainExecutor, cb)
                listener = cb
                if (granted(Manifest.permission.READ_CALL_LOG)) {
                    val r = object : BroadcastReceiver() {
                        override fun onReceive(c: Context, i: Intent) {
                            @Suppress("DEPRECATION")
                            i.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)?.let(::onNumber)
                        }
                    }
                    ContextCompat.registerReceiver(context, r, IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
                    receiver = r
                }
            } else {
                @Suppress("DEPRECATION")
                val l = object : PhoneStateListener() {
                    @Deprecated("Deprecated in Java")
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) = onState(state, phoneNumber)
                }
                @Suppress("DEPRECATION")
                tm.listen(l, PhoneStateListener.LISTEN_CALL_STATE)
                listener = l
            }
        }.onFailure { Log.w(TAG, "cannot follow calls", it) }
    }

    fun stop() {
        val l = listener ?: return
        listener = null
        runCatching {
            if (Build.VERSION.SDK_INT >= 31 && l is TelephonyCallback) {
                tm?.unregisterTelephonyCallback(l)
            } else if (l is PhoneStateListener) {
                @Suppress("DEPRECATION")
                tm?.listen(l, PhoneStateListener.LISTEN_NONE)
            }
        }
        receiver?.let { runCatching { context.unregisterReceiver(it) } }
        receiver = null
    }

    private fun onState(state: Int, phoneNumber: String?) {
        if (!phoneNumber.isNullOrBlank()) number = phoneNumber
        val next = when (state) {
            TelephonyManager.CALL_STATE_RINGING -> LineState.Ringing
            TelephonyManager.CALL_STATE_OFFHOOK -> LineState.OffHook
            else -> LineState.Idle
        }
        for (e in tracker.onState(next)) send(e)
        if (next == LineState.Idle) number = null
    }

    /** The number from the PHONE_STATE broadcast. */
    private fun onNumber(n: String) {
        if (n.isBlank() || n == number) return
        val late = number == null && tracker.state == LineState.Ringing
        number = n
        if (late) send(CallEvent("ringing"))
    }

    private fun send(e: CallEvent) {
        val n = number
        FluxCore.io.execute {
            val packet = CallPackets.packet(e, n, n?.let(::contactName))
            FluxCore.connectedPaired().filter { Types.TELEPHONY in it.identity.incoming }.forEach { it.send(packet) }
        }
    }

    /** The name of the contact with the number, or null without the contacts permission. */
    private fun contactName(n: String): String? {
        if (!granted(Manifest.permission.READ_CONTACTS)) return null
        val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(n))
        return runCatching {
            context.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        }.getOrNull()
    }

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}
