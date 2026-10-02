package org.omarchy.flux.core

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.JsonPrimitive
import org.omarchy.flux.BuildConfig
import org.omarchy.flux.R
import org.omarchy.flux.mic.MicSession
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.ui.MainActivity
import org.omarchy.flux.webcam.WebcamSession
import java.security.SecureRandom

/** A stream that a computer can ask this phone to start. [key] is the value of "kind" on the wire. */
enum class StreamKind(val key: String) {
    Webcam("webcam"),
    Mic("mic");

    /** The title of the prompt and of the notification, for example "omarchy-xps asks for the webcam". */
    fun title(computer: String): String = "$computer asks for ${what()}"

    /** The label of the button and of the notification action that start the stream. */
    fun startLabel(): String = when (this) {
        Webcam -> "Start webcam"
        Mic -> "Start the mic"
    }

    /** The text of the notification. */
    fun tapText(): String = "Tap to start ${what()}."

    private fun what(): String = when (this) {
        Webcam -> "the webcam"
        Mic -> "the mic"
    }

    companion object {
        /** The kind for the wire value [key], or null for another value. */
        fun fromKey(key: String?): StreamKind? = entries.firstOrNull { it.key == key }
    }
}

/** A request of the computer [deviceId], named [computer], to start a stream of [kind]. [at] is in elapsed realtime. */
data class StreamRequest(val deviceId: String, val computer: String, val kind: StreamKind, val at: Long)

/** How the phone shows a stream request. */
enum class StreamDelivery {
    /** The prompt in the app, because Flux is on the screen. */
    Prompt,

    /** A notification, because Flux is not on the screen. */
    Notification,

    /** Nothing: a stream of that kind already runs to that computer, or the phone cannot show the request. */
    None,
}

/**
 * The flux.stream.request packet. The computer sends {"kind": "webcam"} or
 * {"kind": "mic"}. The packet only asks. It never starts the camera or the
 * microphone by itself.
 */
object StreamRequestPacket {
    /** Returns the kind of the request, or null for another packet or another kind. The parse ignores other fields. */
    fun parse(p: Packet): StreamKind? {
        if (p.type != Types.FLUX_STREAM_REQUEST) return null
        val kind = p.body["kind"] as? JsonPrimitive ?: return null
        if (!kind.isString) return null
        return StreamKind.fromKey(kind.content)
    }
}

/**
 * Chooses how the phone shows a request. A stream of the same kind that
 * already runs to the computer makes the request do nothing. Flux on the
 * screen shows the prompt. Else a notification shows, when Android lets
 * Flux post one.
 */
internal fun streamDelivery(running: Boolean, onScreen: Boolean, canNotify: Boolean): StreamDelivery = when {
    running -> StreamDelivery.None
    onScreen -> StreamDelivery.Prompt
    canNotify -> StreamDelivery.Notification
    else -> StreamDelivery.None
}

/**
 * Drops a request of the same kind from the same computer that comes less
 * than [windowMs] after the last one. A dropped request also counts as the
 * last one, so a computer that repeats a request faster shows no new
 * request. The times are in elapsed realtime.
 */
class StreamRequestLimit(private val windowMs: Long = StreamRequests.LIMIT_MS) {
    private val last = HashMap<Pair<String, StreamKind>, Long>()

    /** Records the time of a request. It returns true when the request can show. */
    @Synchronized
    fun admit(deviceId: String, kind: StreamKind, now: Long): Boolean {
        val prev = last.put(deviceId to kind, now)
        return prev == null || now - prev >= windowMs
    }

    /** Removes the times of the computer [deviceId], for example after an unpair. */
    @Synchronized
    fun forget(deviceId: String) {
        last.keys.removeAll { it.first == deviceId }
    }
}

/**
 * The one-time keys of the start actions in the notifications. MainActivity
 * takes other apps' intents too, so the stream starts at once only with a
 * key that this process put in its own notification. An intent without a
 * valid key only opens the page, and the user then presses Start. The keys
 * live in memory, so a new process opens the page only.
 */
class StreamStartKeys(private val validMs: Long, private val newKey: () -> String) {
    private data class Entry(val deviceId: String, val kind: StreamKind, val until: Long)

    private val open = HashMap<String, Entry>()

    /** Makes a new key for a request. It replaces the key of the last request of the same kind from the same computer. */
    @Synchronized
    fun issue(deviceId: String, kind: StreamKind, now: Long): String {
        open.entries.removeAll { (_, e) -> e.until <= now || (e.deviceId == deviceId && e.kind == kind) }
        val key = newKey()
        open[key] = Entry(deviceId, kind, now + validMs)
        return key
    }

    /** Uses the key [key]. It returns true only once, for the same computer and kind, before the key expires. */
    @Synchronized
    fun redeem(key: String, deviceId: String, kind: StreamKind, now: Long): Boolean {
        val e = open.remove(key) ?: return false
        return e.deviceId == deviceId && e.kind == kind && now < e.until
    }

    /** Removes the keys of the computer [deviceId], for example after an unpair. */
    @Synchronized
    fun forget(deviceId: String) {
        open.entries.removeAll { (_, e) -> e.deviceId == deviceId }
    }
}

/**
 * A start that the user asked for with a tap on Start. The page of the
 * stream takes it, and then starts the stream with the existing start
 * path. [at] is in elapsed realtime.
 */
data class StreamStart(val deviceId: String, val kind: StreamKind, val at: Long)

/** Reports whether the page of [deviceId] and [kind] can take the start [s] at [now]. */
internal fun takesStart(s: StreamStart?, deviceId: String, kind: StreamKind, now: Long): Boolean =
    s != null && s.deviceId == deviceId && s.kind == kind && now - s.at in 0 until StreamRequests.START_MS

/**
 * The requests of the computers to start the webcam or the mic of this
 * phone. The phone never turns on the camera or the microphone without a
 * tap of the user on the phone. A request shows a prompt while Flux is on
 * the screen, else a notification. A tap on Start opens the Webcam or Mic
 * page of that computer, and the page starts the stream with the saved
 * settings.
 */
object StreamRequests {
    private const val TAG = "FluxStreamRequest"

    /** The shortest time between 2 requests of the same kind from the same computer. */
    const val LIMIT_MS = 3_000L

    /** How long the prompt and the notification show. */
    const val SHOW_MS = 60_000L

    /** How long the key of a notification is valid: the time of the notification, and 1 minute to unlock the phone. */
    private const val KEY_MS = SHOW_MS + 60_000L

    /** How long the page of the stream can take a start after the tap. */
    const val START_MS = 30_000L

    /**
     * How long the page waits until it can start the stream, for example
     * while the computer is not reachable. After it, the user presses Start
     * on the page.
     */
    const val START_WAIT_MS = 60_000L

    /** The tag of the notifications of the stream requests. */
    private const val TAG_STREAM = "stream"

    private val main = Handler(Looper.getMainLooper())
    private val random = SecureRandom()
    private val limit = StreamRequestLimit()
    private val keys = StreamStartKeys(KEY_MS) {
        ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
    }

    /**
     * True while MainActivity is on the screen. MainActivity sets it in
     * onStart and onStop. Another activity of Flux, such as the approval
     * screen, does not show the prompt, so it does not count.
     */
    @Volatile var onScreen = false

    private val _prompt = MutableStateFlow<StreamRequest?>(null)

    /** The request that the prompt in the app shows, or null. */
    val prompt: StateFlow<StreamRequest?> = _prompt

    private val _start = MutableStateFlow<StreamStart?>(null)

    /** The start that the page of a stream takes, see [take]. */
    val start: StateFlow<StreamStart?> = _start

    /** Handles flux.stream.request from a paired computer. The core lock is held. */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        val kind = StreamRequestPacket.parse(p) ?: return
        val now = SystemClock.elapsedRealtime()
        if (!limit.admit(d.id, kind, now)) {
            Log.i(TAG, "ignored a ${kind.key} request from ${d.identity.deviceName}: less than 3 seconds after the last one")
            return
        }
        val r = StreamRequest(d.id, d.identity.deviceName, kind, now)
        main.post { deliver(core.app, r) }
    }

    /** True while a stream of [kind] to [deviceId] runs or starts. */
    fun running(deviceId: String, kind: StreamKind): Boolean = when (kind) {
        StreamKind.Webcam -> WebcamSession.runsTo(deviceId)
        StreamKind.Mic -> MicSession.runsTo(deviceId)
    }

    private fun deliver(context: Context, r: StreamRequest) {
        val canNotify = NotificationManagerCompat.from(context).areNotificationsEnabled()
        when (streamDelivery(running(r.deviceId, r.kind), onScreen, canNotify)) {
            StreamDelivery.Prompt -> showPrompt(r)
            StreamDelivery.Notification -> notify(context, r)
            StreamDelivery.None -> Log.i(TAG, "did not show a ${r.kind.key} request from ${r.computer}")
        }
    }

    private fun showPrompt(r: StreamRequest) {
        _prompt.value = r
        main.postDelayed({ _prompt.compareAndSet(r, null) }, SHOW_MS)
    }

    /** Closes the prompt of [r]. A newer request stays. */
    fun dismiss(r: StreamRequest) {
        _prompt.compareAndSet(r, null)
    }

    /** Closes the prompt. Debug builds call it before each debug page. */
    fun dismissAll() {
        _prompt.value = null
    }

    /**
     * Records the tap on Start for [deviceId] and [kind]. The page of the
     * stream then starts it with [take]. Call it only for a tap of the user.
     */
    fun startAfterTap(deviceId: String, kind: StreamKind) {
        _start.value = StreamStart(deviceId, kind, SystemClock.elapsedRealtime())
    }

    /**
     * Takes the start for the page of [deviceId] and [kind]. It returns true
     * once, and only in [START_MS] after the tap.
     */
    fun take(deviceId: String, kind: StreamKind): Boolean {
        val s = _start.value
        if (!takesStart(s, deviceId, kind, SystemClock.elapsedRealtime())) return false
        return _start.compareAndSet(s, null)
    }

    /**
     * Uses the key of a notification. It returns true when the intent came
     * from the notification of this process for [deviceId] and [kind].
     */
    fun redeem(key: String?, deviceId: String, kind: StreamKind): Boolean =
        key != null && keys.redeem(key, deviceId, kind, SystemClock.elapsedRealtime())

    private fun notificationId(deviceId: String, kind: StreamKind) = "$deviceId|${kind.key}".hashCode()

    /** Removes the notification of [kind] from [deviceId]. */
    fun cancelNotification(context: Context, deviceId: String, kind: StreamKind) {
        NotificationManagerCompat.from(context).cancel(TAG_STREAM, notificationId(deviceId, kind))
    }

    /**
     * Shows the notification of a request. The title names the computer,
     * and a tap on the notification or on its action opens the page of the
     * stream and starts it. Android removes the notification after
     * [SHOW_MS].
     */
    @SuppressLint("MissingPermission")
    private fun notify(context: Context, r: StreamRequest) {
        val id = notificationId(r.deviceId, r.kind)
        val key = keys.issue(r.deviceId, r.kind, SystemClock.elapsedRealtime())
        val open = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(MainActivity.EXTRA_STREAM_DEVICE, r.deviceId)
            .putExtra(MainActivity.EXTRA_STREAM_KIND, r.kind.key)
            .putExtra(MainActivity.EXTRA_STREAM_KEY, key)
        val start = PendingIntent.getActivity(context, id, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(context, Android.CHANNEL_STREAM)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle(r.kind.title(r.computer))
            .setContentText(r.kind.tapText())
            .setContentIntent(start)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setTimeoutAfter(SHOW_MS)
            .addAction(0, r.kind.startLabel(), start)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(TAG_STREAM, id, n) }
    }

    /** Removes the requests, the notifications, and the start of the computer [deviceId], for example after an unpair. */
    fun forget(context: Context, deviceId: String) {
        limit.forget(deviceId)
        keys.forget(deviceId)
        _prompt.value?.takeIf { it.deviceId == deviceId }?.let { _prompt.compareAndSet(it, null) }
        _start.value?.takeIf { it.deviceId == deviceId }?.let { _start.compareAndSet(it, null) }
        for (kind in StreamKind.entries) cancelNotification(context, deviceId, kind)
    }

    /**
     * Debug builds only: shows the prompt, or with [notification] the
     * notification, of a request from [deviceId], without the limit. See
     * the Test section of docs/android.md.
     */
    fun debugShow(context: Context, deviceId: String, computer: String, kind: StreamKind, notification: Boolean) {
        if (!BuildConfig.DEBUG) return
        val r = StreamRequest(deviceId, computer, kind, SystemClock.elapsedRealtime())
        if (notification) notify(context, r) else showPrompt(r)
    }
}
