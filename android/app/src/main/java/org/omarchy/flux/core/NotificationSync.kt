package org.omarchy.flux.core

import android.annotation.SuppressLint
import android.app.Notification
import android.app.RemoteInput
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
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

/**
 * The facts about 1 action of a notification that decide whether a
 * computer can use it. [needsUnlock] is true for an action that the app
 * protects with the phone lock, on Android 12 and later.
 */
internal data class ActionFacts(val title: String?, val freeFormReply: Boolean, val hasInputs: Boolean, val needsUnlock: Boolean)

/** The actions of 1 notification that a computer can use, by index: the reply action and the buttons. */
internal data class SharedActions(val reply: Int?, val buttons: List<Int>)

/**
 * Remembers the notifications and the buttons that the phone sent to each
 * computer. A computer can dismiss, answer, or press a button only on a
 * notification that the phone sent to it, and only a button that it got.
 * This class has no Android dependency, so the JVM tests check it.
 */
internal class NotificationGate {
    // The device ID, then the notification key, then the button titles.
    private val sent = ConcurrentHashMap<String, ConcurrentHashMap<String, Set<String>>>()

    /** Records that [deviceId] got the notification [key] with the buttons [titles]. */
    fun record(deviceId: String, key: String, titles: Set<String>) {
        sent.getOrPut(deviceId) { ConcurrentHashMap() }[key] = titles
    }

    /** True when [deviceId] got the notification [key]. */
    fun knows(deviceId: String, key: String): Boolean = sent[deviceId]?.containsKey(key) == true

    /** True when [deviceId] got the notification [key] with the button [title]. */
    fun allows(deviceId: String, key: String, title: String): Boolean = sent[deviceId]?.get(key)?.contains(title) == true

    /** Forgets the notification [key] for every computer. It returns the computers that had it. */
    fun forget(key: String): List<String> = sent.entries.filter { it.value.remove(key) != null }.map { it.key }

    /** Forgets what [deviceId] got, for example after an unpair. */
    fun forgetDevice(deviceId: String) {
        sent.remove(deviceId)
    }

    /** The notifications that each computer got. */
    fun keys(): Map<String, Set<String>> = sent.mapValues { it.value.keys.toSet() }

    fun clear() = sent.clear()

    companion object {
        /**
         * Picks the actions that a computer can use. The reply action takes
         * free text. A button takes no text, so an action with remote inputs
         * is not a button. An action that needs the phone lock is neither,
         * because a computer must not skip the lock.
         */
        fun pick(actions: List<ActionFacts>): SharedActions {
            val reply = actions.indexOfFirst { it.freeFormReply && !it.needsUnlock }.takeIf { it >= 0 }
            val buttons = actions.indices.filter { i ->
                val a = actions[i]
                !a.hasInputs && !a.needsUnlock && !a.title.isNullOrEmpty()
            }
            return SharedActions(reply, buttons)
        }
    }
}

/**
 * Sends phone notifications to the paired computers: flux.notification.
 * A computer can dismiss, answer, or press a button only on a notification
 * that the phone sent to it, and only while Share notifications is on.
 */
// The listener service lives as long as the process while the user grants
// notification access, and FluxNotificationListener clears it when Android
// unbinds the service.
@SuppressLint("StaticFieldLeak")
object NotificationSync {
    /** The listener service while Android keeps it bound. */
    @Volatile var listener: NotificationListenerService? = null

    private class ReplyTarget(val key: String, val action: Notification.Action)

    /** A notification as the phone shares it: the packet and the button titles in it. */
    private class Shared(val packet: Packet, val titles: Set<String>)

    private val replies = ConcurrentHashMap<String, ReplyTarget>()
    private val replyIds = ConcurrentHashMap<String, String>()
    private val gate = NotificationGate()

    fun onPosted(sbn: StatusBarNotification, silent: Boolean = false) {
        val core = FluxCore
        if (!core.settings.shareNotifications) return clear()
        val shared = share(sbn, silent)
        if (shared == null) {
            // An update can make a shared notification ongoing or private.
            cancel(sbn.key, forget(sbn.key))
            return
        }
        // A computer that connects later asks for all notifications, see sendAll().
        for (d in core.connectedPaired()) {
            if (d.send(shared.packet)) gate.record(d.id, sbn.key, shared.titles)
        }
    }

    fun onRemoved(sbn: StatusBarNotification) {
        val had = forget(sbn.key)
        if (!FluxCore.settings.shareNotifications) return clear()
        if (had.isEmpty() && !shouldShare(sbn)) return
        cancel(sbn.key, FluxCore.connectedPaired().map { it.id })
    }

    /** Sends every active notification to one device, as the answer to a request. */
    fun sendAll(d: Device) {
        if (!FluxCore.settings.shareNotifications) return clear()
        val l = listener ?: return
        FluxCore.io.execute {
            val active = runCatching { l.activeNotifications }.getOrNull() ?: return@execute
            for (sbn in active) {
                val shared = share(sbn, silent = true) ?: continue
                if (d.send(shared.packet)) gate.record(d.id, sbn.key, shared.titles)
            }
        }
    }

    /** Dismisses the notification [key] for the computer [deviceId]. */
    fun dismiss(deviceId: String, key: String) {
        val l = usable(deviceId, key) ?: return
        FluxCore.io.execute {
            live(l, key) ?: return@execute
            runCatching { l.cancelNotification(key) }
        }
    }

    /** Answers a chat for the computer [deviceId] with the reply action that the phone shared. */
    fun reply(deviceId: String, replyId: String, message: String) {
        val target = replies[replyId] ?: return
        val l = usable(deviceId, target.key) ?: return
        FluxCore.io.execute {
            // A chat that is gone gets no answer.
            live(l, target.key) ?: return@execute
            if (needsUnlock(target.action)) return@execute
            val inputs = target.action.remoteInputs ?: return@execute
            val intent = Intent()
            val results = Bundle()
            inputs.forEach { results.putCharSequence(it.resultKey, message) }
            RemoteInput.addResultsToIntent(inputs, intent, results)
            runCatching { target.action.actionIntent?.send(FluxCore.app, 0, intent) }
                .onFailure { Log.w(TAG, "reply failed", it) }
        }
    }

    /** Presses the button [title] of the notification [key] for the computer [deviceId]. */
    fun action(deviceId: String, key: String, title: String) {
        val l = usable(deviceId, key) ?: return
        if (!gate.allows(deviceId, key, title)) return
        FluxCore.io.execute {
            val sbn = live(l, key) ?: return@execute
            val actions = sbn.notification.actions.orEmpty()
            val picked = NotificationGate.pick(actions.map(::facts))
            val action = picked.buttons.map { actions[it] }.firstOrNull { it.title?.toString() == title } ?: return@execute
            runCatching { action.actionIntent?.send() }.onFailure { Log.w(TAG, "action failed", it) }
        }
    }

    /**
     * Stops the sharing. Each computer drops the notifications that it got,
     * and the phone forgets the reply targets. The Share notifications
     * switch calls it when it turns off. The listener calls it when the user
     * takes the notification access away.
     */
    fun stop() {
        for ((id, keys) in gate.keys()) {
            val d = FluxCore.device(id) ?: continue
            keys.forEach { d.send(cancelPacket(it)) }
        }
        clear()
    }

    /** Forgets what the phone shared: the reply targets and the notifications that each computer got. */
    fun clear() {
        replies.clear()
        replyIds.clear()
        gate.clear()
    }

    /** Forgets what the computer [deviceId] got, for example after an unpair. */
    fun forgetDevice(deviceId: String) = gate.forgetDevice(deviceId)

    /**
     * Returns the listener when the computer [deviceId] can act on the
     * notification [key]: the switch is on, and the phone sent [key] to it.
     */
    private fun usable(deviceId: String, key: String): NotificationListenerService? {
        if (!FluxCore.settings.shareNotifications) {
            clear()
            return null
        }
        val l = listener ?: return null
        return l.takeIf { gate.knows(deviceId, key) }
    }

    /** Returns the active notification [key] while the phone shares it. It asks Android, so it runs on [FluxCore.io]. */
    private fun live(l: NotificationListenerService, key: String): StatusBarNotification? =
        runCatching { l.getActiveNotifications(arrayOf(key)) }.getOrNull()
            ?.firstOrNull { it.key == key }
            ?.takeIf { shouldShare(it) }

    /** Forgets the notification [key] and its reply target. It returns the computers that had it. */
    private fun forget(key: String): List<String> {
        replyIds.remove(key)?.let { replies.remove(it) }
        return gate.forget(key)
    }

    private fun cancel(key: String, deviceIds: List<String>) {
        if (deviceIds.isEmpty()) return
        val p = cancelPacket(key)
        for (d in FluxCore.connectedPaired()) if (d.id in deviceIds) d.send(p)
    }

    private fun cancelPacket(key: String) = Packet(Types.NOTIFICATION, bodyOf("id" to key, "isCancel" to true))

    private fun needsUnlock(a: Notification.Action): Boolean = Build.VERSION.SDK_INT >= 31 && a.isAuthenticationRequired

    private fun facts(a: Notification.Action) = ActionFacts(
        title = a.title?.toString(),
        freeFormReply = a.remoteInputs?.any { it.allowFreeFormInput } == true,
        hasInputs = !a.remoteInputs.isNullOrEmpty(),
        needsUnlock = needsUnlock(a),
    )

    /**
     * Reports whether the phone shares a notification. It leaves out the
     * notifications of Flux, ongoing and foreground service notifications,
     * group summaries, and notifications that the lock screen hides.
     */
    private fun shouldShare(sbn: StatusBarNotification): Boolean {
        if (sbn.packageName == FluxCore.app.packageName) return false
        val n = sbn.notification
        if (n.flags and Notification.FLAG_ONGOING_EVENT != 0) return false
        if (n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return false
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        if (n.visibility == Notification.VISIBILITY_SECRET) return false
        return !secretChannel(sbn)
    }

    /** True when the channel of the notification hides it on the lock screen. */
    private fun secretChannel(sbn: StatusBarNotification): Boolean {
        val l = listener ?: return false
        val ranking = NotificationListenerService.Ranking()
        val found = runCatching { l.currentRanking?.getRanking(sbn.key, ranking) == true }.getOrDefault(false)
        return found && ranking.channel?.lockscreenVisibility == Notification.VISIBILITY_SECRET
    }

    /**
     * Builds the packet of a notification and keeps its reply target. It
     * returns null for a notification that the phone does not share.
     */
    private fun share(sbn: StatusBarNotification, silent: Boolean): Shared? {
        if (!shouldShare(sbn)) return null
        val n = sbn.notification
        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        if (title.isEmpty() && text.isEmpty()) return null
        val app = appName(sbn.packageName)
        val actions = n.actions.orEmpty()
        val picked = NotificationGate.pick(actions.map(::facts))
        val replyAction = picked.reply?.let { actions[it] }
        var replyId: String? = null
        if (replyAction != null) {
            replyId = replyIds.getOrPut(sbn.key) { UUID.randomUUID().toString() }
            replies[replyId] = ReplyTarget(sbn.key, replyAction)
        } else {
            replyIds.remove(sbn.key)?.let { replies.remove(it) }
        }
        val buttons = picked.buttons.mapNotNull { actions[it].title?.toString() }.distinct()
        val ticker = if (title.isNotEmpty() && text.isNotEmpty()) "$title: $text" else title + text
        val packet = Packet(
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
        return Shared(packet, buttons.toSet())
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
