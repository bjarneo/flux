package org.omarchy.flux.core

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

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
 * what goes out, so that no image goes out twice. An image that no
 * computer takes waits longer before each new try, see [CaptureRetries].
 */
object CaptureWatch {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "flux-capture").apply { isDaemon = true } }
    private var observer: ContentObserver? = null

    // The uptime of the waiting scan in milliseconds, or 0 when no scan waits. Only the main thread uses it.
    private var scanAt = 0L
    private val scan = Runnable {
        scanAt = 0L
        worker.execute { scanNow(FluxCore) }
    }

    // The worker uses these. The failed tries of each image, and whether a
    // package may write the images that Flux sends.
    private val retries = HashMap<Long, CaptureRetry>()
    private val systemApps = HashMap<String, Boolean>()

    // The images that an upload still sends after its wait ended, and the
    // images whose late upload succeeded. The IO threads change them.
    private val inFlight: MutableSet<Long> = ConcurrentHashMap.newKeySet()
    private val lateSent: MutableSet<Long> = ConcurrentHashMap.newKeySet()

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
                cancelScan()
            }
        }
    }

    /** Stops the watch, for example when the service stops. */
    fun stop(context: Context) {
        main.post {
            observer?.let { context.applicationContext.contentResolver.unregisterContentObserver(it) }
            observer = null
            cancelScan()
        }
    }

    /** Scans soon. A new image, a computer that connects, or the end of a late upload calls it. */
    fun poke() {
        main.post { scanAfter(SCAN_DELAY_MS, keepSooner = false) }
    }

    /**
     * Scans at the next try of an image that no computer took. An image
     * whose upload still goes on does not count, because the end of that
     * upload scans. A new image or a new computer scans earlier. Runs on
     * the worker.
     */
    private fun scanAtNextTry() {
        val next = CaptureRetries.nextTry(retries, inFlight) ?: return
        val delay = maxOf(SCAN_DELAY_MS, (next - System.currentTimeMillis() / 1000) * 1000)
        main.post { scanAfter(delay, keepSooner = true) }
    }

    /**
     * Scans after [delay] milliseconds, in place of the waiting scan. With
     * [keepSooner], a waiting scan that starts earlier stays, so that a new
     * image does not wait for the next try of another image. Runs on the
     * main thread.
     */
    private fun scanAfter(delay: Long, keepSooner: Boolean) {
        val at = SystemClock.uptimeMillis() + delay
        if (keepSooner && scanAt != 0L && scanAt <= at) return
        main.removeCallbacks(scan)
        scanAt = at
        main.postAtTime(scan, at)
    }

    /** Removes the waiting scan. Runs on the main thread. */
    private fun cancelScan() {
        main.removeCallbacks(scan)
        scanAt = 0L
    }

    /** True while the switch of [kind] is on. The user can turn it off while a batch goes out. */
    private fun switchOn(s: Settings, kind: CaptureKind): Boolean = when (kind) {
        CaptureKind.Screenshot -> s.sendScreenshots
        CaptureKind.Photo -> s.sendPhotos
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
            MediaStore.Images.Media.OWNER_PACKAGE_NAME,
        )
        @Suppress("DEPRECATION")
        val uri = if (Build.VERSION.SDK_INT >= 30) images else MediaStore.setIncludePending(images)
        val cameras = cameraApps(context)
        val out = mutableListOf<MediaImage>()
        context.contentResolver.query(uri, cols, queryArgs(after, limit = PAGE), null)?.use { c ->
            while (c.moveToNext()) {
                out += MediaImage(
                    id = c.getLong(0),
                    relativePath = c.getString(1) ?: "",
                    name = c.getString(2) ?: "image-${c.getLong(0)}.jpg",
                    pending = c.getInt(3) != 0,
                    dateAdded = c.getLong(4),
                    trusted = trustedOwner(context, c.getString(5), cameras),
                )
            }
        }
        return out
    }

    /**
     * Reports whether an image of [owner] can go out by itself. Any app can
     * add an image to a camera folder through MediaStore. So only an app of
     * the system, such as the camera or the screenshot tool, or the default
     * camera app counts. An image without an owner comes from the media
     * scanner, and an app needs a storage permission to write it.
     */
    private fun trustedOwner(context: Context, owner: String?, cameras: Set<String>): Boolean {
        if (owner.isNullOrEmpty() || owner in cameras) return true
        val system = systemApps.getOrPut(owner) {
            runCatching {
                val flags = context.packageManager.getApplicationInfo(owner, 0).flags
                flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
            }.getOrDefault(false)
        }
        if (!system) Log.i(TAG, "skipped an image of $owner: not a camera or screenshot app")
        return system
    }

    /** The default camera apps: the apps that open for the camera button and for a photo request. */
    private fun cameraApps(context: Context): Set<String> {
        val pm = context.packageManager
        return listOf(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA, MediaStore.ACTION_IMAGE_CAPTURE).mapNotNull { action ->
            runCatching { pm.resolveActivity(Intent(action), PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName }.getOrNull()
        }.filter { it != "android" }.toSet()
    }

    /** Scans the new images and sends the ones that [planCapture] picks. Runs on the worker. */
    private fun scanNow(core: FluxCore) {
        val s = core.settings
        if (!(s.sendScreenshots || s.sendPhotos) || !hasAccess(core.app)) return
        // The images whose upload goes on after its wait. Copy them before the scan reads lateSent.
        // A late upload adds its image to lateSent before it removes the image from inFlight.
        // So the image is in 1 of the 2 sets, and it does not go out twice.
        val busy = inFlight.toSet()
        // An upload that ended after its wait can have gone out.
        for (id in lateSent.toList()) {
            lateSent -= id
            retries -= id
            s.captureState = s.captureState.markSent(id)
        }
        val list = runCatching { readImages(core.app, s.captureState.baseline) }
            .onFailure { Log.w(TAG, "scan failed", it) }
            .getOrNull() ?: return
        var state = s.captureState
        val now = System.currentTimeMillis() / 1000
        val plan = planCapture(state, list, now, retries, busy)
        // A full page can have more images after it.
        val more = list.size >= PAGE && plan.state.baseline > state.baseline
        state = plan.state
        s.captureState = state
        retries.keys.retainAll(list.map { it.id }.toSet())
        if (plan.send.isEmpty()) {
            if (more) poke() else scanAtNextTry()
            return
        }
        val targets = core.connectedPaired()
        // A computer that connects scans again.
        if (targets.isEmpty()) return
        var sent = false
        for ((img, kind) in plan.send) {
            // The user can turn the switch off while the batch goes out. The image then waits, as if it did not go out.
            if (!switchOn(s, kind)) continue
            val delivery = sendToAll(core, targets, img, kind)
            if (delivery == Delivery.Taken) {
                sent = true
                retries -= img.id
                state = state.markSent(img.id)
                s.captureState = state
                continue
            }
            // All computers can leave during the batch. The image then waits for the next computer and does not use a try.
            if (delivery == Delivery.NoTarget || !switchOn(s, kind)) continue
            val retry = CaptureRetries.failed(retries[img.id], System.currentTimeMillis() / 1000)
            if (CaptureRetries.givesUp(retry)) {
                // 1 image that no computer takes must not stop the watch.
                retries -= img.id
                state = state.markSent(img.id)
                s.captureState = state
                Log.w(TAG, "gave up on ${img.name} after ${retry.failures} tries")
                Android.showEvent(core.app, "Flux did not send ${img.name}", "The computers did not take it after ${retry.failures} tries.")
            } else {
                retries[img.id] = retry
            }
        }
        // The sent images can move the baseline now. After failures only, the next try waits.
        if (sent || more) poke() else scanAtNextTry()
    }

    /** What happened to 1 image in [sendToAll]. */
    private enum class Delivery {
        /** At least 1 computer took the image. */
        Taken,

        /** Flux sent the image to at least 1 computer, and no computer took it. This counts as a try. */
        Failed,

        /** No target was paired and connected, so the image did not go to a computer. This is not a try. */
        NoTarget,
    }

    /** Sends 1 image to each target that is still paired and connected. */
    private fun sendToAll(core: FluxCore, targets: List<Device>, img: MediaImage, kind: CaptureKind): Delivery {
        val uri = ContentUris.withAppendedId(images, img.id)
        val extra: Map<String, Any?> = when (kind) {
            // The photo marker too, so that an older fluxd saves it as a photo.
            CaptureKind.Screenshot -> mapOf("photo" to true, "screenshot" to true)
            CaptureKind.Photo -> mapOf("photo" to true)
        }
        var tried = false
        var any = false
        for (d in targets) {
            if (!switchOn(core.settings, kind)) break
            if (!d.paired || !d.online) continue
            tried = true
            val done = CountDownLatch(1)
            val ok = AtomicBoolean(false)
            val waiting = AtomicBoolean(true)
            inFlight += img.id
            Share.sendCapture(core, d.id, uri, img.name, extra) { result ->
                ok.set(result.isSuccess)
                done.countDown()
                // After the wait ended, the scan did not count this upload. A second count does no harm.
                val late = !waiting.get()
                if (late && result.isSuccess) lateSent += img.id
                // The image leaves inFlight after it is in lateSent, see scanNow.
                inFlight -= img.id
                // The scans skipped the image while this upload went on.
                if (late) poke()
            }
            done.await(SEND_TIMEOUT_MIN, TimeUnit.MINUTES)
            waiting.set(false)
            // The upload can end between the wait and the flag, so the latch decides.
            if (done.count > 0) {
                // The upload goes on. The next scans skip the image until it ends.
                Log.w(TAG, "${img.name} to ${d.identity.deviceName} takes more than $SEND_TIMEOUT_MIN minutes")
                break
            }
            if (ok.get()) {
                any = true
                Log.i(TAG, "sent ${img.name} to ${d.identity.deviceName}")
            }
        }
        return when {
            any -> Delivery.Taken
            tried -> Delivery.Failed
            else -> Delivery.NoTarget
        }
    }
}
