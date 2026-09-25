package org.omarchy.flux.core

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
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
    const val ID_SERVICE = 1
    const val ID_PAIR = 2
    const val ID_RING = 3
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

    fun createChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL_SERVICE, "Connection", NotificationManager.IMPORTANCE_MIN).apply {
            description = "Keeps the link to your computers open"
            setShowBadge(false)
        })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_EVENTS, "Events", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Received files, links, and pairing requests"
        })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_RING, "Find my phone", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Rings the phone when a computer asks"
            setSound(null, null)
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
