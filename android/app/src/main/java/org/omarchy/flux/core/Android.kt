package org.omarchy.flux.core

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.UiModeManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.omarchy.flux.R
import org.omarchy.flux.ui.MainActivity
import java.io.OutputStream

/** Small wrappers around Android APIs that the core uses. */
object Android {
    const val CHANNEL_SERVICE = "flux.service"
    const val CHANNEL_EVENTS = "flux.events"
    const val CHANNEL_RING = "flux.ring"
    const val CHANNEL_COMPUTER = "flux.computer"
    private const val TAG_COMPUTER = "computer"
    const val CHANNEL_APPROVE = "flux.approve"
    const val CHANNEL_AGENT_INPUT = "flux.agents.input"
    const val CHANNEL_AGENT_DONE = "flux.agents.done"
    private const val TAG_AGENT = "agent"
    const val ID_SERVICE = 1
    const val ID_PAIR = 2
    const val ID_RING = 3
    const val ID_APPROVE = 4
    private var nextId = 100

    fun deviceName(context: Context): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: Build.MODEL

    fun onWifi(context: Context): Boolean {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return false
        return cm.allNetworks.any { n ->
            cm.getNetworkCapabilities(n)?.let {
                it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || it.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
            } == true
        }
    }

    fun hasNotificationAccess(context: Context): Boolean =
        NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)

    /** Returns the charge in percent and the charging state of the phone. */
    fun battery(context: Context): Pair<Int, Boolean> {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val plugged = (intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        val pct = if (level >= 0 && scale > 0) level * 100 / scale else 0
        return pct to plugged
    }

    /** Reads the clipboard. Android returns null when the app has no focus. */
    fun clipboardText(context: Context): String? {
        val cm = context.getSystemService(ClipboardManager::class.java) ?: return null
        val clip = cm.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).coerceToText(context)?.toString()
    }

    fun setClipboard(context: Context, text: String) {
        val cm = context.getSystemService(ClipboardManager::class.java) ?: return
        cm.setPrimaryClip(ClipData.newPlainText("Flux", text))
    }

    /**
     * Android 12 and later: sets the night mode of the app, so that the
     * system splash screen and the -night resources match the theme.
     * [ThemeMode.System] removes the override.
     */
    fun setNightMode(context: Context, mode: ThemeMode) {
        if (Build.VERSION.SDK_INT < 31) return
        val night = when (mode) {
            ThemeMode.System -> UiModeManager.MODE_NIGHT_AUTO
            ThemeMode.Light -> UiModeManager.MODE_NIGHT_NO
            ThemeMode.Dark -> UiModeManager.MODE_NIGHT_YES
        }
        context.getSystemService(UiModeManager::class.java)?.setApplicationNightMode(night)
    }

    fun createChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL_SERVICE, "Connection", NotificationManager.IMPORTANCE_MIN).apply {
            description = "Keeps the link to your computers open"
            setShowBadge(false)
        })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_EVENTS, "Events", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Received files, links, and pairing requests"
        })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_COMPUTER, "From computers", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Notifications that a computer sends, for example with flux-cli notify"
        })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_RING, "Find my phone", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Rings the phone when a computer asks"
            setSound(null, null)
        })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_APPROVE, "Approvals", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Asks you to approve sudo on a computer with your fingerprint"
        })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_AGENT_INPUT, "Agents that need input", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "A coding agent in herdr on a computer waits for an approval or an answer"
        })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_AGENT_DONE, "Agents that finish", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "A coding agent in herdr on a computer finished its work"
        })
    }

    private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
        context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun canNotify(context: Context) = NotificationManagerCompat.from(context).areNotificationsEnabled()

    @Suppress("MissingPermission")
    fun showPairNotification(context: Context, name: String, key: String) {
        if (!canNotify(context)) return
        val n = NotificationCompat.Builder(context, CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle("Pair with $name?")
            .setContentText("Open Flux and check the code $key")
            .setContentIntent(openApp(context))
            .setAutoCancel(true)
            .setTimeoutAfter(INCOMING_TIMEOUT_SECONDS * 1000)
            .build()
        NotificationManagerCompat.from(context).notify(ID_PAIR, n)
    }

    @Suppress("MissingPermission")
    fun showEvent(context: Context, title: String, text: String, intent: Intent? = null) {
        if (!canNotify(context)) return
        val pi = intent?.let {
            PendingIntent.getActivity(context, nextId, it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
        } ?: openApp(context)
        val n = NotificationCompat.Builder(context, CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(context).notify(nextId++, n)
    }

    /**
     * Shows a notification from a computer. The notification listener
     * skips the notifications of Flux, so it does not go back to the computer.
     */
    @Suppress("MissingPermission")
    fun showFromComputer(context: Context, n: ComputerNotification) {
        if (!canNotify(context)) return
        val b = NotificationCompat.Builder(context, CHANNEL_COMPUTER)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle(n.title)
            .setSubText(n.subText)
            .setWhen(n.time)
            .setShowWhen(true)
            .setContentIntent(openApp(context))
            .setAutoCancel(n.clearable)
            .setOngoing(!n.clearable)
        if (n.text.isNotEmpty()) {
            b.setContentText(n.text).setStyle(NotificationCompat.BigTextStyle().bigText(n.text))
        }
        NotificationManagerCompat.from(context).notify(TAG_COMPUTER, n.notificationId, b.build())
    }

    fun cancelFromComputer(context: Context, n: ComputerNotification) {
        NotificationManagerCompat.from(context).cancel(TAG_COMPUTER, n.notificationId)
    }

    private fun agentId(deviceId: String, pane: String) = "$deviceId|$pane".hashCode()

    /**
     * Shows that a herdr agent needs input or finished. Each pane has 1
     * notification, and a tap opens the screen of the agent.
     */
    @Suppress("MissingPermission")
    fun showAgent(context: Context, deviceId: String, computer: String, agent: HerdrAgent) {
        if (!canNotify(context)) return
        val id = agentId(deviceId, agent.pane)
        val blocked = agent.status == AgentStatus.Blocked
        val where = agent.project.ifEmpty { agent.workspace }.ifEmpty { agent.pane }
        val open = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(MainActivity.EXTRA_DEVICE, deviceId)
            .putExtra(MainActivity.EXTRA_PANE, agent.pane)
        val pi = PendingIntent.getActivity(context, id, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = NotificationCompat.Builder(context, if (blocked) CHANNEL_AGENT_INPUT else CHANNEL_AGENT_DONE)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle(if (blocked) "${agent.agent} in $where needs input" else "${agent.agent} in $where finished")
            .setSubText(computer)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setCategory(if (blocked) NotificationCompat.CATEGORY_REMINDER else NotificationCompat.CATEGORY_STATUS)
        if (agent.title.isNotEmpty()) b.setContentText(agent.title)
        NotificationManagerCompat.from(context).notify(TAG_AGENT, id, b.build())
    }

    fun cancelAgent(context: Context, deviceId: String, pane: String) {
        NotificationManagerCompat.from(context).cancel(TAG_AGENT, agentId(deviceId, pane))
    }

    /** True when the phone lets Flux read the call state. */
    fun hasPhoneState(context: Context): Boolean =
        androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.READ_PHONE_STATE) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    /** A file in the public Downloads folder that is still being written. */
    class Download(val uri: Uri, val stream: OutputStream)

    fun createDownload(context: Context, name: String, mime: String?): Download {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
            if (mime != null) put(MediaStore.Downloads.MIME_TYPE, mime)
        }
        val uri = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("cannot create $name in Downloads")
        val stream = context.contentResolver.openOutputStream(uri) ?: error("cannot open $name")
        return Download(uri, stream)
    }

    fun finishDownload(context: Context, d: Download, ok: Boolean) {
        runCatching { d.stream.close() }
        if (!ok) {
            context.contentResolver.delete(d.uri, null, null)
            return
        }
        context.contentResolver.update(d.uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
    }

    fun mimeType(name: String): String? {
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext.isEmpty()) return null
        return android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
    }
}
