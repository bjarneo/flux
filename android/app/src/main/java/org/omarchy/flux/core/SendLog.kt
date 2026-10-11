package org.omarchy.flux.core

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/** The kind of 1 entry of the Send thread. */
enum class SendKind {
    /** A web link that the browser of the computer opened. */
    Link,

    /** Text that went to the clipboard of the computer, for example from the composer. */
    Text,

    /** Text from a scan of the camera. The computer saves it as a text file in its scan folder. */
    Scan,

    /** The clipboard of this phone, with text. */
    Clip,

    /** The clipboard of this phone, with an image. */
    ClipImage,

    /** A file, in either direction. */
    File,
}

/**
 * 1 entry of the Send thread: what this phone sent to the computer
 * [deviceId], or a file that the computer sent ([incoming]). [text] is the
 * link, the text, or the file name. [size] and [done] are the bytes of a
 * file. [clipStamp] is the time that Android set on a clip that went out,
 * see Android.clipTimestamp. [at] is the time in milliseconds since the
 * epoch.
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
) {
    /** The part of a file that went through, from 0 to 1. */
    val progress: Float get() = if (size <= 0) (if (state == TransferState.Running) 0f else 1f) else (done.toFloat() / size).coerceIn(0f, 1f)
}

/** The most entries that the Send thread keeps. All running transfers stay. */
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

/** Sets the bytes of the running file [id] that went through, and its [size] when it is 0 or more. */
fun progressSend(list: List<SendEntry>, id: Long, done: Long, size: Long = -1): List<SendEntry> =
    list.map { if (it.id == id && it.state == TransferState.Running) it.copy(done = done, size = if (size >= 0) size else it.size) else it }

/** Marks the running file [id] as done or failed. A file that is done has all its bytes. */
fun endSend(list: List<SendEntry>, id: Long, ok: Boolean): List<SendEntry> =
    list.map {
        if (it.id == id && it.state == TransferState.Running) {
            it.copy(state = if (ok) TransferState.Done else TransferState.Failed, done = if (ok) it.size else it.done)
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
 * The Send thread: the links, text, clips, and files that this phone sent
 * to the computers, and the files that came from them. The share and
 * clipboard code reports to it. It keeps the entries in memory only, with
 * at most [SEND_TEXT_MAX] characters of a text, and no file content.
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

    /** Reports a new file of [size] bytes and returns its ID for [fileProgress] and [fileEnded]. */
    fun fileStarted(deviceId: String, computer: String, name: String, size: Long, incoming: Boolean): Long =
        add(entry(deviceId, computer, SendKind.File, name).copy(incoming = incoming, size = maxOf(size, 0), state = TransferState.Running))

    /** Reports the bytes of the file [id] that went through, and its [size] when the size was not known at the start. */
    fun fileProgress(id: Long, done: Long, size: Long = -1) {
        _entries.update { progressSend(it, id, done, size) }
    }

    fun fileEnded(id: Long, ok: Boolean) {
        _entries.update { endSend(it, id, ok) }
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

    /** Debug builds only: shows [list] in the place of the entries, for the sample computers. */
    internal fun replace(list: List<SendEntry>) {
        _entries.value = list
    }
}
