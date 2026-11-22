package org.omarchy.flux.core

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/** The kind of 1 entry of the chat log. */
enum class SendKind {
    /** A web link that the browser of the computer opened. */
    Link,

    /** Text that went to the clipboard of the computer, for example from the composer. */
    Text,

    /** Text from a scan of the camera. The computer saves it as a text file in its scan folder. */
    Scan,

    /** A clip with text, from this phone or from the computer. */
    Clip,

    /** A clip with an image, from this phone or from the computer. */
    ClipImage,

    /** A file, in either direction. */
    File,

    /** A sudo, polkit, or enrollment request that this phone approved. */
    Approved,

    /** A sudo, polkit, or enrollment request that this phone denied. */
    Denied,
}

/**
 * 1 entry of the chat log: what this phone sent to the computer
 * [deviceId], or what came from it ([incoming]): a file, a clip, or the
 * answer of this phone to an [approval]. [text] is the link, the text, the
 * file name, or the service of the approval. [size] and [done] are the
 * bytes of a file. [uri] is the received file in Downloads, the source of
 * a file that went out, or empty.
 * [clipStamp] is the time that Android set on a clip that went out, see
 * Android.clipTimestamp. [at] is the time in milliseconds since the epoch.
 */
data class SendEntry(
    val id: Long,
    val deviceId: String,
    val computer: String,
    val kind: SendKind,
    val text: String,
    val incoming: Boolean = false,
    val at: Long = 0,
    val size: Long = 0,
    val done: Long = 0,
    val state: TransferState = TransferState.Done,
    val clipStamp: Long = 0,
    val uri: String = "",
    val approval: ApproveRequest? = null,
) {
    /** The part of a file that went through, from 0 to 1. */
    val progress: Float get() = if (size <= 0) (if (state == TransferState.Running) 0f else 1f) else (done.toFloat() / size).coerceIn(0f, 1f)
}

/** The most entries that the chat log keeps. All running transfers stay. */
const val MAX_SEND_LOG = 60

/** The most characters of a text or a link that an entry keeps. */
const val SEND_TEXT_MAX = 400

/** Adds [e] at the end, and drops the oldest finished entries above [max]. */
fun addSend(list: List<SendEntry>, e: SendEntry, max: Int = MAX_SEND_LOG): List<SendEntry> {
    val all = list + e
    var drop = all.size - max
    if (drop <= 0) return all
    return all.filter { x ->
        if (drop > 0 && x.state != TransferState.Running) {
            drop--
            false
        } else {
            true
        }
    }
}

/** Removes the entries of the computer [deviceId]. The entries of the other computers stay. */
fun clearSends(list: List<SendEntry>, deviceId: String): List<SendEntry> = list.filterNot { it.deviceId == deviceId }

/** Removes the entry [id]. */
fun removeSend(list: List<SendEntry>, id: Long): List<SendEntry> = list.filterNot { it.id == id }

/** Sets the bytes of the running file [id] that went through, and its [size] when it is 0 or more. */
fun progressSend(list: List<SendEntry>, id: Long, done: Long, size: Long = -1): List<SendEntry> =
    list.map { if (it.id == id && it.state == TransferState.Running) it.copy(done = done, size = if (size >= 0) size else it.size) else it }

/** Adds the clip [e] from a computer at the end. It takes the place of the last clip from a computer, because the clipboard holds 1 clip. */
fun addClipIn(list: List<SendEntry>, e: SendEntry, max: Int = MAX_SEND_LOG): List<SendEntry> =
    addSend(list.filterNot { it.incoming && (it.kind == SendKind.Clip || it.kind == SendKind.ClipImage) }, e, max)

/**
 * Marks the running file [id] as done or failed. A file that is done has
 * all its bytes, and [uri] names it when it came in. A file that went out
 * keeps its source.
 */
fun endSend(list: List<SendEntry>, id: Long, ok: Boolean, uri: String = ""): List<SendEntry> =
    list.map {
        if (it.id == id && it.state == TransferState.Running) {
            val name = if (!it.incoming) it.uri else if (ok) uri else ""
            it.copy(state = if (ok) TransferState.Done else TransferState.Failed, done = if (ok) it.size else it.done, uri = name)
        } else {
            it
        }
    }

/** Marks the ended file [id] as running again, for a transfer that the computer sends again. */
fun resumeSend(list: List<SendEntry>, id: Long, done: Long): List<SendEntry> =
    list.map { if (it.id == id) it.copy(state = TransferState.Running, done = done) else it }

/**
 * Lets a progress value through when the whole percent changes, so that a
 * transfer updates the screen at most 100 times.
 */
class ProgressGate(private val size: Long) {
    private var last = -1L

    fun pass(done: Long): Boolean {
        if (size <= 0) return false
        val pct = done * 100 / size
        if (pct == last) return false
        last = pct
        return true
    }
}

/**
 * The chat log: the links, text, clips, and files that this phone sent to
 * the computers, the files and the last clip that came from them, and the
 * answers to approvals. The share, clipboard, and approval code reports to
 * it. It keeps the entries in memory only, with at most [SEND_TEXT_MAX]
 * characters of a text, and no file content.
 */
object SendLog {
    private val ids = AtomicLong()
    private val _entries = MutableStateFlow<List<SendEntry>>(emptyList())

    /** The entries, oldest first. */
    val entries: StateFlow<List<SendEntry>> = _entries

    private fun add(e: SendEntry): Long {
        _entries.update { addSend(it, e) }
        return e.id
    }

    private fun entry(deviceId: String, computer: String, kind: SendKind, text: String) =
        SendEntry(ids.incrementAndGet(), deviceId, computer, kind, cut(text), at = System.currentTimeMillis())

    private fun cut(text: String): String = if (text.length > SEND_TEXT_MAX) text.take(SEND_TEXT_MAX - 1) + "…" else text

    /** Reports a web link that went to the browser of a computer. */
    fun link(deviceId: String, computer: String, url: String) {
        add(entry(deviceId, computer, SendKind.Link, url))
    }

    /** Reports text that went to the clipboard of a computer. */
    fun text(deviceId: String, computer: String, text: String) {
        add(entry(deviceId, computer, SendKind.Text, text.trim()))
    }

    /** Reports text from a scan of the camera, which the computer saves as a file. */
    fun scan(deviceId: String, computer: String, text: String) {
        add(entry(deviceId, computer, SendKind.Scan, text.trim()))
    }

    /** Reports the clipboard of this phone that went to a computer. [text] is null for an image. */
    fun clip(deviceId: String, computer: String, text: String?, stamp: Long) {
        val e = entry(deviceId, computer, if (text == null) SendKind.ClipImage else SendKind.Clip, text?.trim().orEmpty())
        add(e.copy(clipStamp = stamp))
    }

    /** Reports a clip from a computer. [text] is null for an image. */
    fun clipIn(deviceId: String, computer: String, text: String?) {
        val e = entry(deviceId, computer, if (text == null) SendKind.ClipImage else SendKind.Clip, text.orEmpty()).copy(incoming = true)
        _entries.update { addClipIn(it, e) }
    }

    /** Reports that this phone approved or denied the request [r]. */
    fun approval(r: ApproveRequest, approved: Boolean) {
        val e = entry(r.computerId, r.computerName, if (approved) SendKind.Approved else SendKind.Denied, r.service)
        add(e.copy(incoming = true, approval = r))
    }

    /**
     * Reports a new file of [size] bytes and returns its ID for [fileProgress]
     * and [fileEnded]. [uri] is the source of a file that goes out, so that
     * the chat can show a photo, or empty.
     */
    fun fileStarted(deviceId: String, computer: String, name: String, size: Long, incoming: Boolean, uri: String = ""): Long =
        add(entry(deviceId, computer, SendKind.File, name).copy(incoming = incoming, size = maxOf(size, 0), state = TransferState.Running, uri = uri))

    /** Reports the bytes of the file [id] that went through, and its [size] when the size was not known at the start. */
    fun fileProgress(id: Long, done: Long, size: Long = -1) {
        _entries.update { progressSend(it, id, done, size) }
    }

    /** Reports the end of the file [id]. [uri] is the received file in Downloads, or empty when the chat must not open it. */
    fun fileEnded(id: Long, ok: Boolean, uri: String = "") {
        _entries.update { endSend(it, id, ok, uri) }
    }

    /** Reports that the file [id] runs again from byte [done]. It returns false when the thread no longer has the file. */
    fun fileResumed(id: Long, done: Long): Boolean {
        var found = false
        _entries.update { list ->
            found = list.any { it.id == id }
            resumeSend(list, id, done)
        }
        return found
    }

    /** Removes the entries of the computer [deviceId], for Clear this chat. The files that the computer saved stay. */
    fun clear(deviceId: String) {
        _entries.update { clearSends(it, deviceId) }
    }

    /** Removes the entry [id], for a send that the user sends again. */
    fun remove(id: Long) {
        _entries.update { removeSend(it, id) }
    }

    /** Debug builds only: shows [list] in the place of the entries, for the sample computers. */
    internal fun replace(list: List<SendEntry>) {
        _entries.value = list
    }
}
