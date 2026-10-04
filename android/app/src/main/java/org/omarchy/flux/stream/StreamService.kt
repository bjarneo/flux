package org.omarchy.flux.stream

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import org.omarchy.flux.R
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.StreamKind
import org.omarchy.flux.mic.MicSettings

private const val TAG = "FluxStreams"

/**
 * How long the service waits after the last stream ends. A new frame size
 * of the webcam stops the stream and starts it again within this time.
 */
private const val GRACE_MS = 2_000L

/** The longest time of 1 hold of the wake lock. Each change of the streams holds it again. */
private const val WAKE_MS = 6 * 60 * 60_000L

/**
 * Keeps the webcam and the mic running while Flux is not on the screen.
 * Android gives the camera and the microphone to an app in the background
 * only through a foreground service of type camera or microphone, and only
 * when the service gets the type while the app is visible. [LiveStreams]
 * starts the service when a stream starts on its screen. The service stops
 * [GRACE_MS] after the last stream ends. Its notification names each
 * stream and has a Stop action for each one. Only the main thread uses
 * the service.
 */
class StreamService : Service() {
    companion object {
        private const val ACTION_STOP = "org.omarchy.flux.stream.STOP"
        private const val EXTRA_KIND = "flux.kind"

        /** True from [ensure] until the service stops. */
        private var wanted = false

        /** Starts the service, once. It runs on the main thread. */
        fun ensure(context: Context) {
            if (wanted) return
            wanted = true
            runCatching { ContextCompat.startForegroundService(context, Intent(context, StreamService::class.java)) }
                .onFailure {
                    wanted = false
                    Log.w(TAG, "the stream service did not start: ${it.message}")
                }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var foreground = false
    private var finishing = false

    /** The foreground service types that Android accepted. */
    private var types = 0
    private var end: Job? = null
    private val wake by lazy {
        getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "flux:stream").apply { setReferenceCounted(false) }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            StreamKind.fromKey(intent.getStringExtra(EXTRA_KIND))?.let { LiveStreams.stop(it) }
            // A Stop of an old notification, while this service does not run.
            if (!foreground) {
                finishing = true
                stopSelf()
            }
            return START_NOT_STICKY
        }
        if (foreground) return START_NOT_STICKY
        // Android needs the foreground state soon after the start, also when the stream ended already.
        update(LiveStreams.live.value, MicSettings.withWebcam.value)
        scope.launch {
            combine(LiveStreams.live, MicSettings.withWebcam, ::Pair).collect { (streams, withMic) -> update(streams, withMic) }
        }
        return START_NOT_STICKY
    }

    private fun update(streams: List<LiveStream>, withMic: Boolean) {
        // A new stream after finish() starts a new service, see ensure().
        if (finishing) return
        promote(streams, withMic)
        if (streams.isNotEmpty()) {
            end?.cancel()
            end = null
            runCatching { wake.acquire(WAKE_MS) }
        } else if (end?.isActive != true) {
            end = scope.launch {
                delay(GRACE_MS)
                finish()
            }
        }
    }

    /**
     * Shows the notification of [streams]. A stream that needs a new type
     * calls startForeground again. Android refuses the camera and the
     * microphone types while Flux is not visible, so a type that the
     * service has stays until the service stops.
     */
    private fun promote(streams: List<LiveStream>, withMic: Boolean) {
        val n = notification(streams)
        val next = types or typesFor(streams, withMic)
        if (foreground && next == types) {
            getSystemService(NotificationManager::class.java).notify(Android.ID_STREAMS, n)
            return
        }
        try {
            ServiceCompat.startForeground(this, Android.ID_STREAMS, n, next)
            types = next
        } catch (e: Exception) {
            Log.w(TAG, "Android refused the foreground types $next: ${e.message}")
            if (foreground) {
                getSystemService(NotificationManager::class.java).notify(Android.ID_STREAMS, n)
            } else {
                // The stream runs while Flux is visible. In the background, Android can stop its camera or microphone.
                runCatching { ServiceCompat.startForeground(this, Android.ID_STREAMS, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE) }
                    .onSuccess { types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE }
            }
        }
        foreground = true
    }

    /** The foreground service types for [streams]. Android 10 has no camera and microphone types. */
    private fun typesFor(streams: List<LiveStream>, withMic: Boolean): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        val webcam = streams.any { it.kind == StreamKind.Webcam }
        val mic = streams.any { it.kind == StreamKind.Mic } || (webcam && withMic)
        var t = 0
        if (webcam && granted(Manifest.permission.CAMERA)) t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        if (mic && granted(Manifest.permission.RECORD_AUDIO)) t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        return if (t == 0) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else t
    }

    private fun granted(permission: String) = ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    private fun notification(streams: List<LiveStream>): Notification {
        val (title, text) = streamNotice(streams) { id -> FluxCore.device(id)?.identity?.deviceName ?: "the computer" }
        val b = NotificationCompat.Builder(this, Android.CHANNEL_LIVE)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(Android.openApp(this))
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        for (s in streams) {
            val label = if (s.kind == StreamKind.Webcam) "Stop webcam" else "Stop the mic"
            val stop = PendingIntent.getService(
                this, s.kind.ordinal + 1,
                Intent(this, StreamService::class.java).setAction(ACTION_STOP).putExtra(EXTRA_KIND, s.kind.key),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            b.addAction(0, label, stop)
        }
        return b.build()
    }

    private fun finish() {
        if (LiveStreams.live.value.isNotEmpty()) return
        finishing = true
        wanted = false
        runCatching { if (wake.isHeld) wake.release() }
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        runCatching { if (wake.isHeld) wake.release() }
        // A service that the system stops can start again with the next stream.
        if (!finishing) wanted = false
        super.onDestroy()
    }
}
