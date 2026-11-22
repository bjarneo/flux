package org.omarchy.flux.core

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** The 3 link states of an agent thread. */
enum class ThreadLink { Connected, Connecting, Unreachable }

/**
 * The note above the dock of an agent thread. [title] is the first line.
 * [detail] is the second line, or empty. For [ThreadLink.Connected], [detail]
 * is the age of the output, such as `now` or `3m`.
 */
data class ThreadNote(val state: ThreadLink, val title: String, val detail: String)

/**
 * The texts about the link to a computer. The thread of an agent and the
 * rows of Chats and of the widget show them, so the app and the widget use
 * the same words. The model has no Android types. The caller gives [time]
 * a function that formats a time in the format of the phone.
 */
object LinkNote {
    /** `HH:MM` of a time, for tests and for a caller with no phone format. */
    fun clock(at: Long): String = SimpleDateFormat("HH:mm", Locale.US).format(Date(at))

    /**
     * The note of a thread, or null when it has no note: the computer is
     * connected and the phone has no output yet. [outputAt] is the time of
     * the last output, or 0 when it is not known.
     */
    fun threadNote(
        online: Boolean,
        connecting: Boolean,
        name: String,
        outputAt: Long,
        now: Long,
        time: (Long) -> String = ::clock,
    ): ThreadNote? = when {
        online -> if (outputAt > 0) ThreadNote(ThreadLink.Connected, "Output from ${time(outputAt)}", age(now - outputAt)) else null
        connecting -> ThreadNote(ThreadLink.Connecting, "Connecting to $name", "")
        else -> ThreadNote(
            ThreadLink.Unreachable,
            "$name is not reachable.",
            if (outputAt > 0) "This output is from ${time(outputAt)}." else "",
        )
    }

    /**
     * The line of a row of a computer that is not reachable, or null when
     * the computer is [online]. [lastSeen] is 0 when it is not known.
     */
    fun rowLine(online: Boolean, lastSeen: Long, time: (Long) -> String = ::clock): String? = when {
        online -> null
        lastSeen > 0 -> "Not reachable since ${time(lastSeen)}"
        else -> "Not reachable"
    }

    /** The age of an output: `now` under 1 minute, then `3m`, `2h`, or `4d`. */
    fun age(ms: Long): String {
        val min = ms.coerceAtLeast(0) / 60_000
        return when {
            min < 1 -> "now"
            min < 60 -> "${min}m"
            min < 24 * 60 -> "${min / 60}h"
            else -> "${min / (24 * 60)}d"
        }
    }
}
