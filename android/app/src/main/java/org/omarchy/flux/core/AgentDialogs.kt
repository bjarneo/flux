package org.omarchy.flux.core

import kotlinx.coroutines.flow.MutableStateFlow
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/** How many lines a dialog read asks for. This is the scan range of [findChoices]. */
const val DIALOG_READ_LINES = 40

/** How long a dialog read waits for the answer, in milliseconds. A later answer is not used. */
const val DIALOG_READ_TIMEOUT_MS = 3_000L

/** The lines above the choices that [AgentDialog] keeps. */
private const val DIALOG_LINES = 4

/**
 * The question of a blocked agent. [question] is the line that asks, or
 * empty. [lines] are the lines above the choices, for example the command
 * that a choice approves. [choices] are the numbered choices or the menu
 * row, and the list is empty for a question with free text. [id] is the
 * first 16 hex digits of the SHA-256 of the question, the lines, and the
 * labels of the choices. [at] is the time of the read, in milliseconds.
 */
data class AgentDialog(
    val question: String,
    val lines: List<String>,
    val choices: List<AgentChoice>,
    val command: Boolean,
    val id: String,
    val at: Long,
)

/** The ID of a dialog: the first 16 hex digits of the SHA-256 of its question, lines, and labels. */
fun dialogId(question: String, lines: List<String>, labels: List<String>): String {
    val sha = MessageDigest.getInstance("SHA-256")
    // The separator is a control character that a terminal line does not hold.
    val text = (listOf(question) + lines + "\u0001" + labels).joinToString("\u0000")
    return sha.digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }.take(16)
}

/**
 * Parses the dialog at the end of [out]. It returns null for an output with
 * an error or with no lines. An output with no choices gives a dialog with
 * an empty choice list. Then the question is the last line that ends with a
 * question mark, or empty.
 */
fun parseDialog(out: HerdrOutput, at: Long): AgentDialog? {
    if (out.error != null || out.lines.isEmpty()) return null
    val texts = out.lines.map { it.text }
    val choices = out.choices
    val ask = agentAsk(texts, DIALOG_LINES)
    val question = ask?.question?.takeIf { it.isNotEmpty() }
        ?: if (choices.isEmpty()) texts.takeLast(12).lastOrNull { it.trim().endsWith("?") }?.trim().orEmpty() else ""
    val lines = ask?.lines.orEmpty()
    return AgentDialog(question, lines, choices, ask?.command ?: false, dialogId(question, lines, choices.map { it.label }), at)
}

/** What [DialogBook] needs from the app. The tests replace it. */
interface DialogIo {
    /** True while the agent screen of [pane] shows its output. */
    fun screenOpen(deviceId: String, pane: String): Boolean

    /** True while the agent screen of [pane] waits for an answer. */
    fun screenReading(deviceId: String, pane: String): Boolean

    /** Asks the agent screen to read [pane] again. It returns false when the computer is not reachable. */
    fun readScreen(deviceId: String, pane: String): Boolean

    /**
     * Sends a read of [pane] with a new request number. It calls [register]
     * with the number while it holds the core lock, so that the answer
     * cannot come first. It returns false when the computer is not reachable.
     */
    fun send(deviceId: String, pane: String, register: (Long) -> Unit): Boolean

    fun now(): Long

    /** Runs [task] after [ms] milliseconds. */
    fun later(ms: Long, task: () -> Unit)

    /** Runs [task] outside the core lock. */
    fun post(task: () -> Unit)
}

/**
 * Keeps the last dialog of each blocked pane and reads a dialog on request.
 * It keeps at most 1 read of a pane in flight, because fluxd answers only
 * the newest read of a pane. When the agent screen of the pane is open, the
 * read goes through that screen, so the screen and the notification share
 * 1 answer. Else the read has its own request number, and its answer does
 * not replace the output of a screen.
 */
class DialogBook(private val io: DialogIo) {
    private class Wait(val key: String) {
        val callbacks = ArrayList<(AgentDialog?) -> Unit>()

        /** The request number of the read, or null for a read of the screen or before the send. */
        var request: Long? = null
    }

    private val waits = HashMap<String, Wait>()
    private val last = HashMap<String, AgentDialog>()

    private fun key(deviceId: String, pane: String) = "$deviceId|$pane"

    /** The last dialog that a read found for [pane], or null. */
    @Synchronized
    fun latest(deviceId: String, pane: String): AgentDialog? = last[key(deviceId, pane)]

    /** Forgets the dialog of [pane], for example when the agent is no longer blocked. */
    @Synchronized
    fun forget(deviceId: String, pane: String) {
        last.remove(key(deviceId, pane))
    }

    /**
     * Reads the dialog of [pane] and calls [done] with it. [done] gets null
     * when the read fails, takes more than [timeoutMs], or finds no dialog.
     * A second call while a read waits joins that read.
     */
    fun peek(deviceId: String, pane: String, timeoutMs: Long = DIALOG_READ_TIMEOUT_MS, done: (AgentDialog?) -> Unit) {
        val k = key(deviceId, pane)
        val wait: Wait
        synchronized(this) {
            waits[k]?.let {
                it.callbacks += done
                return
            }
            wait = Wait(k)
            wait.callbacks += done
            waits[k] = wait
        }
        val sent = if (io.screenOpen(deviceId, pane)) {
            io.screenReading(deviceId, pane) || io.readScreen(deviceId, pane)
        } else {
            io.send(deviceId, pane) { r -> synchronized(this) { wait.request = r } }
        }
        if (!sent) {
            finish(wait, null)
            return
        }
        io.later(timeoutMs) { finish(wait, null) }
    }

    /**
     * Reads the dialog again and calls [onSame] with the new dialog when its
     * ID is [id]. Else it calls [onChanged] with the new dialog, or with null
     * when the read failed. Thus a caller sends only the choice of the new
     * read, and a menu choice gets the arrows from the new selection.
     */
    fun verify(
        deviceId: String,
        pane: String,
        id: String,
        timeoutMs: Long = DIALOG_READ_TIMEOUT_MS,
        onSame: (AgentDialog) -> Unit,
        onChanged: (AgentDialog?) -> Unit,
    ) = peek(deviceId, pane, timeoutMs) { d -> if (d != null && d.id == id) onSame(d) else onChanged(d) }

    /**
     * Takes an output that answers a read of this book. It returns true when
     * it took the output, and then the screen must not use it. The core lock
     * is held.
     */
    fun onOutput(deviceId: String, out: HerdrOutput): Boolean {
        val wait: Wait
        synchronized(this) {
            wait = waits[key(deviceId, out.pane)] ?: return false
            val request = wait.request ?: return false
            // An older fluxd sends no request number, so the pane is the match.
            if (out.request != null && out.request != request) return false
        }
        finish(wait, out)
        return true
    }

    /** Takes the output that the agent screen of a pane accepted, for the reads that went through the screen. The core lock is held. */
    fun onScreenOutput(deviceId: String, out: HerdrOutput) {
        val wait: Wait
        synchronized(this) {
            wait = waits[key(deviceId, out.pane)] ?: return
            if (wait.request != null || out.loading) return
        }
        finish(wait, out)
    }

    private fun finish(wait: Wait, out: HerdrOutput?) {
        val callbacks: List<(AgentDialog?) -> Unit>
        val dialog = out?.let { parseDialog(it, io.now()) }
        synchronized(this) {
            if (waits[wait.key] !== wait) return
            waits.remove(wait.key)
            if (dialog != null) last[wait.key] = dialog
            callbacks = wait.callbacks.toList()
        }
        io.post { callbacks.forEach { it(dialog) } }
    }
}

/** The dialogs of the app. The notification and the answer activity use it. */
object AgentDialogs {
    private val io = object : DialogIo {
        override fun screenOpen(deviceId: String, pane: String) =
            FluxCore.locked { FluxCore.device(deviceId)?.herdrOutput?.pane == pane }

        override fun screenReading(deviceId: String, pane: String) =
            FluxCore.locked { FluxCore.device(deviceId)?.herdrOutput?.takeIf { it.pane == pane }?.loading == true }

        override fun readScreen(deviceId: String, pane: String): Boolean {
            if (FluxCore.device(deviceId)?.link == null) return false
            HerdrSync.read(FluxCore, deviceId, pane)
            return FluxCore.locked { FluxCore.device(deviceId)?.herdrOutput?.error == null }
        }

        override fun send(deviceId: String, pane: String, register: (Long) -> Unit): Boolean =
            HerdrSync.readDialog(FluxCore, deviceId, pane, register)

        override fun now() = System.currentTimeMillis()

        override fun later(ms: Long, task: () -> Unit) {
            FluxCore.scheduler.schedule(task, ms, TimeUnit.MILLISECONDS)
        }

        override fun post(task: () -> Unit) {
            FluxCore.scheduler.execute(task)
        }
    }

    internal val book = DialogBook(io)

    fun peek(core: FluxCore, deviceId: String, pane: String, done: (AgentDialog?) -> Unit) = book.peek(deviceId, pane, done = done)

    fun latest(deviceId: String, pane: String): AgentDialog? = book.latest(deviceId, pane)

    fun verify(core: FluxCore, deviceId: String, pane: String, id: String, onSame: (AgentDialog) -> Unit, onChanged: (AgentDialog?) -> Unit) =
        book.verify(deviceId, pane, id, onSame = onSame, onChanged = onChanged)

    fun forget(deviceId: String, pane: String) = book.forget(deviceId, pane)
}

/**
 * The agent threads that show the line "The question changed. Pick again.".
 * The answer activity sets it, and the dock of the thread shows it.
 */
object QuestionChanged {
    private val shown = MutableStateFlow<Set<String>>(emptySet())
    val flow get() = shown

    private fun key(deviceId: String, pane: String) = "$deviceId|$pane"

    fun show(deviceId: String, pane: String) {
        shown.value = shown.value + key(deviceId, pane)
    }

    fun clear(deviceId: String, pane: String) {
        shown.value = shown.value - key(deviceId, pane)
    }

    fun isShown(set: Set<String>, deviceId: String, pane: String) = key(deviceId, pane) in set
}
