package org.omarchy.flux.core

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.omarchy.flux.R
import org.omarchy.flux.service.FluxService
import org.omarchy.flux.ui.RingActivity

/**
 * Find my phone. The phone plays the alarm sound at full alarm volume and
 * shows a full-screen notification until the user stops it.
 */
object Ringer {
    private const val MAX_RING_MS = 2 * 60 * 1000L

    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var ringing = false
    private var savedVolume = -1
    private val handler = Handler(Looper.getMainLooper())

    fun start(context: Context, from: String) {
        // A second ring request while the phone rings stops it. This lets the
        // computer stop a ring that nobody can reach on the phone.
        if (ringing) {
            stop(context)
            return
        }
        ringing = true
        val am = context.getSystemService(AudioManager::class.java)
        savedVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
        runCatching { am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0) }
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        player = runCatching {
            MediaPlayer().apply {
                setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                setDataSource(context, uri)
                isLooping = true
                prepare()
                start()
            }
        }.onFailure { Log.w("FluxRing", "cannot play the alarm sound", it) }.getOrNull()
        vibrator = vibrator(context)?.also {
            it.vibrate(
                VibrationEffect.createWaveform(longArrayOf(0, 600, 400), 0),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build(),
            )
        }
        FluxCore.setRinging(from)
        showNotification(context, from)
        // Stop after 2 minutes, so a ring that nobody stops cannot run on.
        val app = context.applicationContext
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ if (ringing) stop(app) }, MAX_RING_MS)
    }

    private fun vibrator(context: Context): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Vibrator::class.java)
        }

    fun stop(context: Context) {
        ringing = false
        handler.removeCallbacksAndMessages(null)
        player?.let { runCatching { it.stop(); it.release() } }
        player = null
        // Cancel the vibrator that started the ring, and the default vibrator,
        // in case the process started again since the ring began.
        vibrator?.cancel()
        vibrator = null
        vibrator(context)?.cancel()
        if (savedVolume >= 0) {
            runCatching { context.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, savedVolume, 0) }
            savedVolume = -1
        }
        NotificationManagerCompat.from(context).cancel(Android.ID_RING)
        FluxCore.setRinging(null)
    }

    @Suppress("MissingPermission")
    private fun showNotification(context: Context, from: String) {
        val full = PendingIntent.getActivity(
            context, 1, Intent(context, RingActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            context, 2, Intent(context, FluxService::class.java).setAction(FluxService.ACTION_STOP_RING),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, Android.CHANNEL_RING)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle("Ringing from $from")
            .setContentText("Tap to stop")
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setFullScreenIntent(full, true)
            .setContentIntent(full)
            .setOngoing(true)
            .addAction(0, "I found it", stop)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(Android.ID_RING, n) }
        if (FluxCore.foreground) runCatching { context.startActivity(Intent(context, RingActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }
}
