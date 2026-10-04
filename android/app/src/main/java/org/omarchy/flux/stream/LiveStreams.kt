package org.omarchy.flux.stream

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.StreamKind
import org.omarchy.flux.mic.MicSession
import org.omarchy.flux.webcam.WebcamSession

/**
 * 1 webcam or mic stream of this phone. [live] is false while the stream
 * connects to the computer [deviceId].
 */
data class LiveStream(val kind: StreamKind, val deviceId: String, val live: Boolean)

/**
 * The webcam and the mic streams that start or run now. A stream keeps
 * running after its screen closes and while Flux is in the background.
 * The Inbox and the notification of [StreamService] show each stream.
 */
object LiveStreams {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var started = false

    /** The streams in the order webcam, mic. */
    val live: StateFlow<List<LiveStream>> = combine(WebcamSession.status, MicSession.status, ::liveStreams)
        .stateIn(scope, SharingStarted.Eagerly, emptyList())

    /**
     * Starts [StreamService] when a stream starts. [org.omarchy.flux.FluxApp]
     * calls it when the app starts. Later calls do nothing.
     */
    fun start(context: Context) {
        if (started) return
        started = true
        val app = context.applicationContext
        scope.launch { live.collect { if (it.isNotEmpty()) StreamService.ensure(app) } }
    }

    /** Stops the stream of [kind] and tells the computer. */
    fun stop(kind: StreamKind) = when (kind) {
        StreamKind.Webcam -> WebcamSession.stop(FluxCore, notify = true)
        StreamKind.Mic -> MicSession.stop(FluxCore, notify = true)
    }
}

/** The streams that the sessions start or run. */
internal fun liveStreams(webcam: WebcamSession.Status, mic: MicSession.Status): List<LiveStream> = buildList {
    val w = webcam.deviceId
    if (webcam.active && w != null) add(LiveStream(StreamKind.Webcam, w, webcam.phase == WebcamSession.Phase.Live))
    val m = mic.deviceId
    if (mic.active && m != null) add(LiveStream(StreamKind.Mic, m, mic.phase == MicSession.Phase.Live))
}

/**
 * 1 sentence without a period for the [kinds] of stream to the computer
 * [name], for example "The webcam and the mic stream to omarchy". While a
 * stream is not [live], it connects.
 */
internal fun streamSentence(kinds: List<StreamKind>, name: String, live: Boolean): String {
    val what = kinds.distinct().sorted().joinToString(" and ") { if (it == StreamKind.Webcam) "the webcam" else "the mic" }
        .replaceFirstChar { it.uppercase() }
    val verb = when {
        live && kinds.distinct().size > 1 -> "stream"
        live -> "streams"
        kinds.distinct().size > 1 -> "connect"
        else -> "connects"
    }
    return "$what $verb to $name"
}

/**
 * The title and the text of the notification for [streams]. [name] gives
 * the name of a computer from its device ID.
 */
internal fun streamNotice(streams: List<LiveStream>, name: (String) -> String): Pair<String, String> {
    if (streams.isEmpty()) return "The stream ended" to "Flux removes this notification."
    val groups = streams.groupBy { it.deviceId }
    if (groups.size == 1) {
        val (id, list) = groups.entries.first()
        val text = if (list.size == 1) "It keeps running in the background. Tap Stop to end it." else "They keep running in the background. Tap Stop to end one."
        return streamSentence(list.map { it.kind }, name(id), list.all { it.live }) to text
    }
    val text = groups.entries.joinToString(" ") { (id, list) -> streamSentence(list.map { it.kind }, name(id), list.all { it.live }) + "." }
    return "The webcam and the mic stream to 2 computers" to text
}
