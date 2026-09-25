package org.omarchy.flux.core

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

private const val TAG = "FluxCapture"

/** How long the watch waits after a MediaStore change before it scans, in milliseconds. */
private const val SCAN_DELAY_MS = 1_500L

/** The most images that 1 scan reads. */
private const val PAGE = 200

/** The longest time that 1 image may take to go out, in minutes. */
private const val SEND_TIMEOUT_MIN = 10L

/**
 * Sends each new screenshot and camera photo to the connected computers,
 * when its switch is on. It watches MediaStore, and [planCapture] decides
 * what goes out, so that no image goes out twice.
 */
object CaptureWatch {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "flux-capture").apply { isDaemon = true } }
    private var observer: ContentObserver? = null
    private val scan = Runnable { worker.execute { scanNow(FluxCore) } }

    private val images: Uri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI

    /** The permissions to ask for, for this Android version. */
    fun permissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= 34 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    /**
     * Reports whether Flux can see every new image. Access to selected
     * photos only is not enough, because new images are not in the
     * selection.
     */
    fun hasAccess(context: Context): Boolean {
        val p = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE
        return ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED
    }

    /** Starts or stops the watch to match the switches. The service calls it at start, and each switch calls it. */
    fun refresh(context: Context) {
        val app = context.applicationContext
        val on = (FluxCore.settings.sendScreenshots || FluxCore.settings.sendPhotos) && hasAccess(app)
        main.post {
            if (on && observer == null) {
                val o = object : ContentObserver(main) {
                    override fun onChange(selfChange: Boolean) = poke()
                }
                runCatching { app.contentResolver.registerContentObserver(images, true, o) }
                    .onSuccess { observer = o }
                    .onFailure { Log.w(TAG, "watch failed", it) }
                poke()
            } else if (!on && observer != null) {
                observer?.let { app.contentResolver.unregisterContentObserver(it) }
                observer = null
                main.removeCallbacks(scan)
            }
        }
    }

    /** Stops the watch, for example when the service stops. */
    fun stop(context: Context) {
        main.post {
            observer?.let { context.applicationContext.contentResolver.unregisterContentObserver(it) }
            observer = null
            main.removeCallbacks(scan)
        }
    }

    /** Scans soon. A new image, or a computer that connects, calls it. */
    fun poke() {
        main.removeCallbacks(scan)
        main.postDelayed(scan, SCAN_DELAY_MS)
    }

    /**
     * Turns a switch on or off. A new switch starts at the newest image now,
     * so that older images do not go out. Runs on the worker, in order with
     * the scans.
     */
    fun setKind(context: Context, kind: CaptureKind, on: Boolean) {
        val app = context.applicationContext
        worker.execute {
            val s = FluxCore.settings
            s.captureState = if (on) s.captureState.enable(kind, newestId(app)) else s.captureState.disable(kind)
        }
    }

    private fun newestId(context: Context): Long =
        runCatching {
            context.contentResolver.query(images, arrayOf(MediaStore.Images.Media._ID), queryArgs(0, newestFirst = true), null)?.use { c ->
                if (c.moveToFirst()) c.getLong(0) else 0L
            } ?: 0L
        }.getOrDefault(0L)

    /**
     * The query for the images after [after]. It includes pending images,
     * because MediaStore leaves them out by default, and a pending image
     * that the scan does not see would go past the baseline.
     */
    private fun queryArgs(after: Long, newestFirst: Boolean = false, limit: Int = 0): Bundle = Bundle().apply {
        putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION, "${MediaStore.Images.Media._ID} > ?")
        putStringArray(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arrayOf(after.toString()))
        putString(android.content.ContentResolver.QUERY_ARG_SQL_SORT_ORDER, "${MediaStore.Images.Media._ID} ${if (newestFirst) "DESC" else "ASC"}")
        if (newestFirst) putInt(android.content.ContentResolver.QUERY_ARG_LIMIT, 1)
        if (limit > 0) putInt(android.content.ContentResolver.QUERY_ARG_LIMIT, limit)
        if (Build.VERSION.SDK_INT >= 30) putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
    }

    private fun readImages(context: Context, after: Long): List<MediaImage> {
        val cols = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.IS_PENDING,
            MediaStore.Images.Media.DATE_ADDED,
        )
        @Suppress("DEPRECATION")
        val uri = if (Build.VERSION.SDK_INT >= 30) images else MediaStore.setIncludePending(images)
        val out = mutableListOf<MediaImage>()
        context.contentResolver.query(uri, cols, queryArgs(after, limit = PAGE), null)?.use { c ->
            while (c.moveToNext()) {
                out += MediaImage(
                    id = c.getLong(0),
                    relativePath = c.getString(1) ?: "",
                    name = c.getString(2) ?: "image-${c.getLong(0)}.jpg",
                    pending = c.getInt(3) != 0,
                    dateAdded = c.getLong(4),
                )
            }
        }
        return out
    }

    /** Scans the new images and sends the ones that [planCapture] picks. Runs on the worker. */
    private fun scanNow(core: FluxCore) {
        val s = core.settings
        if (!(s.sendScreenshots || s.sendPhotos) || !hasAccess(core.app)) return
        val list = runCatching { readImages(core.app, s.captureState.baseline) }
            .onFailure { Log.w(TAG, "scan failed", it) }
            .getOrNull() ?: return
        var state = s.captureState
        val plan = planCapture(state, list, System.currentTimeMillis() / 1000)
        // A full page can have more images after it.
        val more = list.size >= PAGE && plan.state.baseline > state.baseline
        state = plan.state
        s.captureState = state
        if (plan.send.isEmpty()) {
            if (more) poke()
            return
        }
        val targets = core.connectedPaired()
        if (targets.isEmpty()) return
        for ((img, kind) in plan.send) {
            if (sendToAll(core, targets, img, kind)) {
                state = state.markSent(img.id)
                s.captureState = state
            }
        }
        // The sent images can move the baseline now.
        poke()
    }

    /** Sends 1 image to each target. Returns true when at least 1 target took it. */
    private fun sendToAll(core: FluxCore, targets: List<Device>, img: MediaImage, kind: CaptureKind): Boolean {
        val uri = ContentUris.withAppendedId(images, img.id)
        val extra: Map<String, Any?> = when (kind) {
            // The photo marker too, so that an older fluxd saves it as a photo.
            CaptureKind.Screenshot -> mapOf("photo" to true, "screenshot" to true)
            CaptureKind.Photo -> mapOf("photo" to true)
        }
        var any = false
        for (d in targets) {
            val done = CountDownLatch(1)
            var ok = false
            Share.sendCapture(core, d.id, uri, img.name, extra) { result ->
                ok = result.isSuccess
                done.countDown()
            }
            done.await(SEND_TIMEOUT_MIN, TimeUnit.MINUTES)
            if (ok) {
                any = true
                Log.i(TAG, "sent ${img.name} to ${d.identity.deviceName}")
            }
        }
        return any
    }
}
