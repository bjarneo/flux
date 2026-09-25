package org.omarchy.flux.core

import android.app.Notification
import android.app.RemoteInput
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

private const val TAG = "FluxNotif"

/** Sends phone notifications to the paired computers: kdeconnect.notification. */
object NotificationSync {
    /** The listener service while Android keeps it bound. */
    @Volatile var listener: NotificationListenerService? = null

    private class ReplyTarget(val key: String, val action: Notification.Action)

    private val replies = ConcurrentHashMap<String, ReplyTarget>()
    private val replyIds = ConcurrentHashMap<String, String>()

    fun onPosted(sbn: StatusBarNotification, silent: Boolean = false) {
        val core = FluxCore
        if (!core.settings.shareNotifications) return
        val packet = toPacket(sbn, silent) ?: return
        core.connectedPaired().forEach { it.send(packet) }
    }

    fun onRemoved(sbn: StatusBarNotification) {
        if (!FluxCore.settings.shareNotifications) return
        if (!shouldShare(sbn)) return
        replyIds.remove(sbn.key)?.let { replies.remove(it) }
        val p = Packet(Types.NOTIFICATION, bodyOf("id" to sbn.key, "isCancel" to true))
        FluxCore.connectedPaired().forEach { it.send(p) }
    }

    /** Sends every active notification to one device, as the answer to a request. */
    fun sendAll(d: Device) {
        if (!FluxCore.settings.shareNotifications) return
        val l = listener ?: return
        FluxCore.io.execute {
            val active = runCatching { l.activeNotifications }.getOrNull() ?: return@execute
            active.forEach { sbn -> toPacket(sbn, silent = true)?.let { d.send(it) } }
        }
    }

    fun dismiss(key: String) {
        runCatching { listener?.cancelNotification(key) }
    }

    fun reply(replyId: String, message: String) {
        val target = replies[replyId] ?: return
        val inputs = target.action.remoteInputs ?: return
        val intent = Intent()
        val results = Bundle()
        inputs.forEach { results.putCharSequence(it.resultKey, message) }
        RemoteInput.addResultsToIntent(inputs, intent, results)
        runCatching { target.action.actionIntent.send(FluxCore.app, 0, intent) }
            .onFailure { Log.w(TAG, "reply failed", it) }
    }

    fun action(key: String, title: String) {
        val sbn = listener?.activeNotifications?.firstOrNull { it.key == key } ?: return
        val action = sbn.notification.actions?.firstOrNull { it.title?.toString() == title } ?: return
        runCatching { action.actionIntent.send() }.onFailure { Log.w(TAG, "action failed", it) }
    }

    private fun shouldShare(sbn: StatusBarNotification): Boolean {
        if (sbn.packageName == FluxCore.app.packageName) return false
        val n = sbn.notification
        if (n.flags and Notification.FLAG_ONGOING_EVENT != 0) return false
        if (n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return false
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        return true
    }

    private fun toPacket(sbn: StatusBarNotification, silent: Boolean): Packet? {
        if (!shouldShare(sbn)) return null
        val n = sbn.notification
        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        if (title.isEmpty() && text.isEmpty()) return null
        val app = appName(sbn.packageName)
        val actions = n.actions.orEmpty()
        val replyAction = actions.firstOrNull { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }
        var replyId: String? = null
        if (replyAction != null) {
            replyId = replyIds.getOrPut(sbn.key) { UUID.randomUUID().toString() }
            replies[replyId] = ReplyTarget(sbn.key, replyAction)
        }
        val buttons = actions.filter { it !== replyAction }.mapNotNull { it.title?.toString() }
        val ticker = if (title.isNotEmpty() && text.isNotEmpty()) "$title: $text" else title + text
        return Packet(
            Types.NOTIFICATION,
            bodyOf(
                "id" to sbn.key,
                "appName" to app,
                "title" to title,
                "text" to text,
                "ticker" to ticker,
                "time" to sbn.postTime.toString(),
                "isClearable" to sbn.isClearable,
                "silent" to silent,
                "onlyOnce" to (n.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0),
                "requestReplyId" to replyId,
                "actions" to buttons.ifEmpty { null },
            ).let { o -> kotlinx.serialization.json.JsonObject(o.filterValues { it !is kotlinx.serialization.json.JsonNull }) },
        )
    }

    private fun appName(pkg: String): String = runCatching {
        val pm = FluxCore.app.packageManager
        val info = if (android.os.Build.VERSION.SDK_INT >= 33) {
            pm.getApplicationInfo(pkg, PackageManager.ApplicationInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.getApplicationInfo(pkg, 0)
        }
        pm.getApplicationLabel(info).toString()
    }.getOrDefault(pkg)
}
