package org.omarchy.flux.screen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.Display
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import org.omarchy.flux.R
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.stream.PinnedStream
import org.omarchy.flux.webcam.H264Encoder
import java.net.ServerSocket
import javax.net.ssl.SSLSocket

private const val TAG = "FluxScreen"
private const val CHANNEL = "flux.mirror"
private const val NOTIFICATION_ID = 40
private const val CONNECT_TIMEOUT_MS = 10_000

/**
 * Mirrors the phone screen to the computer. Android needs a foreground
 * service of type mediaProjection for screen capture. The service starts
 * after the user allows the capture, and it runs until a stop: from the
 * notification, from the computer, from the system, or when the link drops.
 */
class ScreenMirrorService : Service() {
    companion object {
        private const val EXTRA_DEVICE = "flux.device"
        private const val EXTRA_CODE = "flux.code"
        private const val EXTRA_DATA = "flux.data"
        private const val ACTION_STOP = "org.omarchy.flux.screen.STOP"

        /** Starts the mirror to [deviceId] with the result of the capture consent. */
        fun start(context: Context, deviceId: String, resultCode: Int, data: Intent) {
            val i = Intent(context, ScreenMirrorService::class.java)
                .putExtra(EXTRA_DEVICE, deviceId)
                .putExtra(EXTRA_CODE, resultCode)
                .putExtra(EXTRA_DATA, data)
            context.startForegroundService(i)
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var encoder: H264Encoder? = null
    private var server: ServerSocket? = null
    private var socket: SSLSocket? = null
    private var deviceId: String? = null
    private var size = 0 to 0
    @Volatile private var finished = false

    private val displays by lazy { getSystemService(DisplayManager::class.java) }

    /** Follows rotation: a new frame size gives a new encoder on the same stream. */
    private val rotation = object : DisplayManager.DisplayListener {
        override fun onDisplayChanged(displayId: Int) {
            if (displayId == Display.DEFAULT_DISPLAY) resize()
        }

        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit
    }

    /** Checks the link every second and stops the mirror when it drops. */
    private val watch = object : Runnable {
        override fun run() {
            val d = deviceId?.let { FluxCore.device(it) }
            if (d == null || !d.online) {
                finish(notify = false, ScreenSession.Status(ScreenSession.Phase.Error, "The connection to the computer closed", deviceId))
                return
            }
            main.postDelayed(this, 1000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            if (projection == null) {
                // A stop from an old notification, with no mirror in this service.
                stopSelf()
                return START_NOT_STICKY
            }
            ScreenSession.stop(notify = true, ScreenSession.Status(ScreenSession.Phase.Idle, "Stopped on this phone", deviceId))
            return START_NOT_STICKY
        }
        if (projection != null) return START_NOT_STICKY
        val id = intent?.getStringExtra(EXTRA_DEVICE)
        val code = intent?.getIntExtra(EXTRA_CODE, 0) ?: 0
        val data = if (Build.VERSION.SDK_INT >= 33) intent?.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        else @Suppress("DEPRECATION") intent?.getParcelableExtra(EXTRA_DATA)
        deviceId = id
        val name = id?.let { FluxCore.device(it)?.identity?.deviceName } ?: "the computer"
        // The service must run in the foreground before it gets the projection.
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(name), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        if (id == null || data == null) {
            finish(notify = false, ScreenSession.Status(ScreenSession.Phase.Error, "The screen capture did not start"))
            return START_NOT_STICKY
        }
        val proj = runCatching { getSystemService(MediaProjectionManager::class.java).getMediaProjection(code, data) }.getOrNull()
        if (proj == null) {
            finish(notify = false, ScreenSession.Status(ScreenSession.Phase.Error, "Android did not allow the screen capture", id))
            return START_NOT_STICKY
        }
        // Android 14 and later need a callback before the virtual display.
        proj.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                main.post { finish(notify = true, ScreenSession.Status(ScreenSession.Phase.Idle, "The screen mirror stopped", id)) }
            }
        }, main)
        projection = proj
        ScreenSession.attach { notify, status -> main.post { finish(notify, status) } }
        ScreenSession.set(ScreenSession.Status(ScreenSession.Phase.Connecting, "Waiting for $name…", id))
        FluxCore.io.execute { connect(id, name) }
        return START_NOT_STICKY
    }

    /** Waits for the computer, then starts the capture on the main thread. */
    private fun connect(id: String, name: String) {
        try {
            val d = FluxCore.device(id) ?: error("$name is not known")
            if (Types.FLUX_SCREEN !in d.identity.incoming) error("Update Flux on $name to mirror this screen")
            val (w, h) = frameSize()
            val ssl = PinnedStream.accept(FluxCore, d, CONNECT_TIMEOUT_MS, { srv ->
                if (finished) runCatching { srv.close() } else server = srv
            }) { port -> ScreenPackets.start(port, w, h) }
            main.post {
                server = null
                if (finished) {
                    runCatching { ssl.close() }
                    return@post
                }
                socket = ssl
                begin(ssl, w, h)
            }
        } catch (e: Exception) {
            Log.i(TAG, "mirror did not start: ${e.message}")
            main.post { finish(notify = true, ScreenSession.Status(ScreenSession.Phase.Error, e.message ?: "The screen mirror did not start", id)) }
        }
    }

    private fun begin(ssl: SSLSocket, w: Int, h: Int) {
        val proj = projection ?: return
        try {
            val enc = newEncoder(ssl, w, h)
            encoder = enc
            size = w to h
            display = proj.createVirtualDisplay(
                "Flux mirror", w, h, resources.displayMetrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, enc.inputSurface, null, main,
            )
            enc.requestKeyFrame()
            displays.registerDisplayListener(rotation, main)
            main.postDelayed(watch, 1000)
        } catch (e: Exception) {
            Log.w(TAG, "capture failed", e)
            finish(notify = true, ScreenSession.Status(ScreenSession.Phase.Error, "The screen capture failed: ${e.message}", deviceId))
        }
    }

    private fun newEncoder(ssl: SSLSocket, w: Int, h: Int) = H264Encoder(w, h, MirrorSize.bitrate(w, h), ssl.outputStream) {
        main.post { finish(notify = false, ScreenSession.Status(ScreenSession.Phase.Error, "The connection to the computer closed", deviceId)) }
    }

    /**
     * Gives the stream a new frame size after a rotation. The old encoder
     * stops before the new one writes, so the stream stays valid. The
     * computer reads the new size from the next key frame.
     */
    private fun resize() {
        val vd = display ?: return
        val ssl = socket ?: return
        val next = frameSize()
        if (next == size || finished) return
        try {
            vd.surface = null
            encoder?.release()
            val enc = newEncoder(ssl, next.first, next.second)
            encoder = enc
            size = next
            vd.resize(next.first, next.second, resources.displayMetrics.densityDpi)
            vd.surface = enc.inputSurface
            enc.requestKeyFrame()
        } catch (e: Exception) {
            Log.w(TAG, "resize failed", e)
            finish(notify = true, ScreenSession.Status(ScreenSession.Phase.Error, "The screen mirror stopped after the rotation", deviceId))
        }
    }

    /** The frame size for the screen in its current rotation. */
    private fun frameSize(): Pair<Int, Int> {
        val p = Point()
        @Suppress("DEPRECATION")
        displays.getDisplay(Display.DEFAULT_DISPLAY).getRealSize(p)
        return MirrorSize.fit(p.x, p.y)
    }

    /** Stops everything once. With [notify], the computer gets "stop". */
    private fun finish(notify: Boolean, status: ScreenSession.Status) {
        if (finished) return
        finished = true
        main.removeCallbacks(watch)
        runCatching { displays.unregisterDisplayListener(rotation) }
        runCatching { display?.release() }
        display = null
        runCatching { encoder?.release() }
        encoder = null
        val hadStream = socket != null || server != null
        runCatching { server?.close() }
        runCatching { socket?.close() }
        server = null
        socket = null
        val proj = projection
        projection = null
        runCatching { proj?.stop() }
        val id = deviceId
        if (notify && hadStream && id != null) FluxCore.io.execute { FluxCore.device(id)?.send(ScreenPackets.stop()) }
        ScreenSession.detach(status)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        finish(notify = true, ScreenSession.Status(ScreenSession.Phase.Idle, "The screen mirror stopped", deviceId))
        super.onDestroy()
    }

    private fun notification(name: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Screen mirror", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shows while this screen shows on a computer"
            setShowBadge(false)
        })
        val stop = PendingIntent.getService(
            this, 0, Intent(this, ScreenMirrorService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle("Mirroring this screen")
            .setContentText("$name shows this screen. Tap Stop to end.")
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .addAction(0, "Stop", stop)
            .build()
    }
}
