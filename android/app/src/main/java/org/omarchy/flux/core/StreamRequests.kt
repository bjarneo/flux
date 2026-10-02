package org.omarchy.flux.core

import android.annotation.SuppressLint
import android.app.NotificationManager
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

/**
 * A request of the computer [deviceId], named [computer], to start a stream
 * of [kind]. [at] is the time when the phone took it, in elapsed realtime.
 */
data class StreamRequest(val deviceId: String, val computer: String, val kind: StreamKind, val at: Long)

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
 * Drops a request of the same kind from the same computer that comes less
 * than [windowMs] after the last one. A dropped request also counts as the
 * last one, so a computer that repeats a request faster shows no new
 * request. A request while the stream runs counts too. The times are in
 * elapsed realtime.
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

/** What [StreamRequestBook.receive] did with a request. */
sealed interface StreamOutcome {
    /** The request is open. It replaced the open request of the same computer and kind. */
    data class Opened(val request: StreamRequest) : StreamOutcome

    /** The request came less than [StreamRequests.LIMIT_MS] after the last request of the same computer and kind. */
    data object TooSoon : StreamOutcome

    /** A stream of that kind already runs to that computer. */
    data object Running : StreamOutcome
}

/**
 * The open stream requests of all computers. Each computer has at most 1
 * open request of each kind. A request ends after [lifetimeMs], after an
 * answer, or after an unpair. The caller gives the time of each change, in
 * elapsed realtime. The book holds no timer.
 */
class StreamRequestBook(
    private val limit: StreamRequestLimit = StreamRequestLimit(),
    private val lifetimeMs: Long = StreamRequests.SHOW_MS,
) {
    private val open = ArrayList<StreamRequest>()

    /** The open requests, the oldest first. The prompt shows the newest one. */
    val requests: List<StreamRequest>
        @Synchronized get() = open.toList()

    /**
     * Takes a request, or ignores it. [running] is true while a stream of
     * [kind] runs to [deviceId]. A new request of the same computer and kind
     * replaces the open one and becomes the newest.
     */
    @Synchronized
    fun receive(deviceId: String, computer: String, kind: StreamKind, running: Boolean, now: Long): StreamOutcome {
        if (!limit.admit(deviceId, kind, now)) return StreamOutcome.TooSoon
        if (running) return StreamOutcome.Running
        val r = StreamRequest(deviceId, computer, kind, now)
        put(r)
        return StreamOutcome.Opened(r)
    }

    /** Opens [r] without the limit. Debug builds use it for the prompt pages. */
    @Synchronized
    fun put(r: StreamRequest) {
        open.removeAll { it.deviceId == r.deviceId && it.kind == r.kind }
        open.add(r)
    }

    /** True while [r] is younger than the lifetime of a request. */
    fun fresh(r: StreamRequest, now: Long): Boolean = now - r.at < lifetimeMs

    /** Ends the open request of [deviceId] and [kind] and returns it, or null when none is open. */
    @Synchronized
    fun remove(deviceId: String, kind: StreamKind): StreamRequest? {
        val i = open.indexOfFirst { it.deviceId == deviceId && it.kind == kind }
        return if (i < 0) null else open.removeAt(i)
    }

    /** Ends the requests that are as old as the lifetime or older, and returns them. */
    @Synchronized
    fun expire(now: Long): List<StreamRequest> {
        val old = open.filter { !fresh(it, now) }
        open.removeAll { !fresh(it, now) }
        return old
    }

    /** Ends the requests of the computer [deviceId] and removes its times, for example after an unpair. */
    @Synchronized
    fun forget(deviceId: String): List<StreamRequest> {
        limit.forget(deviceId)
        val gone = open.filter { it.deviceId == deviceId }
        open.removeAll { it.deviceId == deviceId }
        return gone
    }

    /** Ends all requests. The times stay. */
    @Synchronized
    fun clear(): List<StreamRequest> {
        val gone = open.toList()
        open.clear()
        return gone
    }
}

/**
 * The one-time keys of the start actions in the notifications. MainActivity
 * takes other apps' intents too, so the stream starts only with a key that
 * this process put in its own notification. An intent without a valid key
 * does nothing. The keys live in memory, so a new process has no keys.
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

    /** Removes the key of [kind] from [deviceId], for example after an answer in the prompt. */
    @Synchronized
    fun drop(deviceId: String, kind: StreamKind) {
        open.entries.removeAll { (_, e) -> e.deviceId == deviceId && e.kind == kind }
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
 * tap of the user on the phone. While Flux is on the screen, the prompt
 * shows the open requests. Else a notification shows each new request. A
 * tap on Start in the prompt, or on the Start action of the notification,
 * opens the Webcam or Mic page of that computer, and the page starts the
 * stream with the saved settings. A tap on the notification itself only
 * opens Flux, which then shows the prompt.
 *
 * The open requests, the keys, and the start change on the main thread.
 */
object StreamRequests {
    private const val TAG = "FluxStreamRequest"

    /** The shortest time between 2 requests of the same kind from the same computer. */
    const val LIMIT_MS = 3_000L

    /** How long a request stays open, and how long its notification shows. */
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

    /**
     * How long Start in the prompt ignores taps after the prompt is fully
     * open and Flux is in front. The computer chooses when a request comes,
     * so it must not catch a tap that the user already makes.
     */
    const val ARM_MS = 800L

    /** The intent action of the Start action in a notification. Only this action starts a stream. */
    const val ACTION_START = "org.omarchy.flux.STREAM_START"

    /** The tag of the notifications of the stream requests. */
    private const val TAG_STREAM = "stream"

    private val main = Handler(Looper.getMainLooper())
    private val random = SecureRandom()
    private val book = StreamRequestBook()
    private val keys = StreamStartKeys(KEY_MS) {
        ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
    }

    /**
     * True while MainActivity is on the screen. Another activity of Flux,
     * such as the approval screen, does not show the prompt, so it does not
     * count. See [setOnScreen].
     */
    @Volatile private var onScreen = false

    private val _requests = MutableStateFlow<List<StreamRequest>>(emptyList())

    /** The open requests, the oldest first. The prompt in the app shows the newest one. */
    val requests: StateFlow<List<StreamRequest>> = _requests

    private val _start = MutableStateFlow<StreamStart?>(null)

    /** The start that the page of a stream takes, see [take]. */
    val start: StateFlow<StreamStart?> = _start

    /** Handles flux.stream.request from a paired computer. The core lock is held, so the work moves to the main thread, which keeps the order of the packets. */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        val kind = StreamRequestPacket.parse(p) ?: return
        val id = d.id
        val name = d.identity.deviceName
        main.post { receive(core.app, id, name, kind) }
    }

    /** True while a stream of [kind] to [deviceId] runs or starts. */
    fun running(deviceId: String, kind: StreamKind): Boolean = when (kind) {
        StreamKind.Webcam -> WebcamSession.runsTo(deviceId)
        StreamKind.Mic -> MicSession.runsTo(deviceId)
    }

    private fun receive(context: Context, deviceId: String, computer: String, kind: StreamKind) {
        // An unpair can come between the packet and this call.
        if (FluxCore.device(deviceId)?.paired != true) return
        val now = SystemClock.elapsedRealtime()
        when (val o = book.receive(deviceId, computer, kind, running(deviceId, kind), now)) {
            StreamOutcome.TooSoon -> Log.i(TAG, "ignored a ${kind.key} request from $computer: less than 3 seconds after the last one")
            StreamOutcome.Running -> Log.i(TAG, "ignored a ${kind.key} request from $computer: the stream runs")
            is StreamOutcome.Opened -> {
                publish()
                main.postDelayed(::expire, SHOW_MS)
                when {
                    // The prompt shows the request.
                    onScreen -> cancelNotification(context, deviceId, kind)
                    NotificationManagerCompat.from(context).areNotificationsEnabled() -> notify(context, o.request)
                    // The prompt shows the request when Flux comes on the screen in time.
                    else -> Log.i(TAG, "no notification for a ${kind.key} request from $computer: notifications are off")
                }
            }
        }
    }

    /**
     * MainActivity calls it in onStart and in onStop. While Flux is on the
     * screen, the prompt shows the open requests, so their notifications go
     * away. Call it on the main thread.
     */
    fun setOnScreen(context: Context, shown: Boolean) {
        onScreen = shown
        if (!shown) return
        // A timer of the main thread does not count while the phone sleeps.
        expire()
        for (r in book.requests) cancelNotification(context, r.deviceId, r.kind)
    }

    /** Ends the requests that are too old. Their notifications go away by themselves. */
    private fun expire() {
        if (book.expire(SystemClock.elapsedRealtime()).isNotEmpty()) publish()
    }

    private fun publish() {
        _requests.value = book.requests
    }

    /** Ends [r] after an answer: its key and its notification go. */
    private fun end(context: Context, r: StreamRequest) {
        keys.drop(r.deviceId, r.kind)
        cancelNotification(context, r.deviceId, r.kind)
        publish()
    }

    /**
     * Ends the request [r] after a tap on Start in the prompt. It returns
     * true when the page of the stream can start it: the request was open
     * and is not too old. Then call [startAfterTap].
     */
    fun accept(context: Context, r: StreamRequest): Boolean {
        val open = book.remove(r.deviceId, r.kind) ?: return false
        end(context, open)
        return book.fresh(open, SystemClock.elapsedRealtime())
    }

    /**
     * Ends the request of [kind] from [deviceId] without a stream, for
     * example after a tap on Not now.
     */
    fun dismiss(context: Context, deviceId: String, kind: StreamKind) {
        val open = book.remove(deviceId, kind) ?: return
        end(context, open)
    }

    /** Ends all requests. Debug builds call it before each debug page. */
    fun dismissAll(context: Context) {
        for (r in book.clear()) end(context, r)
        publish()
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
     * Uses the key of the Start action of a notification. It returns true
     * when the intent came from the notification of this process for
     * [deviceId] and [kind]. Then the request ends, and its notification
     * goes away. Another value changes nothing.
     */
    fun redeem(context: Context, key: String?, deviceId: String, kind: StreamKind): Boolean {
        if (key == null || !keys.redeem(key, deviceId, kind, SystemClock.elapsedRealtime())) return false
        book.remove(deviceId, kind)
        cancelNotification(context, deviceId, kind)
        publish()
        return true
    }

    private fun notificationId(deviceId: String, kind: StreamKind) = "$deviceId|${kind.key}".hashCode()

    private fun cancelNotification(context: Context, deviceId: String, kind: StreamKind) {
        NotificationManagerCompat.from(context).cancel(TAG_STREAM, notificationId(deviceId, kind))
    }

    /**
     * Removes the notifications of the stream requests that an earlier
     * process posted. Their keys were in the memory of that process, so
     * their Start actions can no longer start a stream. FluxCore calls it
     * once when the process starts.
     */
    fun removeStale(context: Context) {
        runCatching {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.activeNotifications.filter { it.tag == TAG_STREAM }.forEach { nm.cancel(TAG_STREAM, it.id) }
        }
    }

    /**
     * Shows the notification of a request. The title names the computer.
     * Only the Start action starts the stream. A tap on the notification
     * itself opens Flux, and Flux then shows the prompt. A new request of
     * the same computer and kind replaces the notification without a new
     * alert. Android removes the notification after [SHOW_MS].
     */
    @SuppressLint("MissingPermission")
    private fun notify(context: Context, r: StreamRequest) {
        val id = notificationId(r.deviceId, r.kind)
        val key = keys.issue(r.deviceId, r.kind, SystemClock.elapsedRealtime())
        // The action and the identifier make this PendingIntent differ from
        // each other PendingIntent of Flux, so that no other notification
        // can carry the key.
        val start = Intent(context, MainActivity::class.java)
            .setAction(ACTION_START)
            .setIdentifier("${r.deviceId}|${r.kind.key}")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(MainActivity.EXTRA_STREAM_DEVICE, r.deviceId)
            .putExtra(MainActivity.EXTRA_STREAM_KIND, r.kind.key)
            .putExtra(MainActivity.EXTRA_STREAM_KEY, key)
        val startIntent = PendingIntent.getActivity(context, id, start, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(context, Android.CHANNEL_STREAM)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle(r.kind.title(r.computer))
            .setContentText(r.kind.tapText())
            .setContentIntent(Android.openApp(context))
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setTimeoutAfter(SHOW_MS)
            .addAction(0, r.kind.startLabel(), startIntent)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(TAG_STREAM, id, n) }
    }

    /**
     * Removes the requests, the notifications, and the start of the computer
     * [deviceId], for example after an unpair. The work runs on the main
     * thread after each request that came before.
     */
    fun forget(context: Context, deviceId: String) {
        main.post {
            keys.forget(deviceId)
            book.forget(deviceId)
            publish()
            _start.value?.takeIf { it.deviceId == deviceId }?.let { _start.compareAndSet(it, null) }
            for (kind in StreamKind.entries) cancelNotification(context, deviceId, kind)
        }
    }

    /**
     * Debug builds only: shows the prompt, or with [notification] the
     * notification, of a request from [deviceId], without the limit. The
     * notification of this page is not an open request, so the prompt does
     * not show it. See the Test section of docs/android.md.
     */
    fun debugShow(context: Context, deviceId: String, computer: String, kind: StreamKind, notification: Boolean) {
        if (!BuildConfig.DEBUG) return
        val r = StreamRequest(deviceId, computer, kind, SystemClock.elapsedRealtime())
        if (notification) {
            notify(context, r)
            return
        }
        book.put(r)
        publish()
        main.postDelayed(::expire, SHOW_MS)
    }
}
