package org.omarchy.flux.core

import kotlinx.serialization.json.JsonObject
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf

/** The state of the phone line, as TelephonyManager reports it. */
enum class LineState { Idle, Ringing, OffHook }

/** 1 kdeconnect.telephony event. [cancel] is true when the event ends. */
data class CallEvent(val event: String, val cancel: Boolean = false)

/**
 * Turns the line states of the phone into telephony events, in the order
 * that KDE Connect sends them:
 *
 * - Idle to Ringing: ringing.
 * - Ringing or Idle to OffHook: talking. The user answered, or started a call.
 * - Ringing to Idle: missedCall, then the end of ringing.
 * - OffHook to Idle: the end of talking.
 */
class CallTracker {
    var state = LineState.Idle
        private set

    fun onState(next: LineState): List<CallEvent> {
        val prev = state
        state = next
        return when {
            prev == next -> emptyList()
            next == LineState.Ringing -> listOf(CallEvent("ringing"))
            next == LineState.OffHook -> listOf(CallEvent("talking"))
            prev == LineState.Ringing -> listOf(CallEvent("missedCall"), CallEvent("ringing", cancel = true))
            else -> listOf(CallEvent("talking", cancel = true))
        }
    }
}

object CallPackets {
    /** The contact name when the phone knows neither the number nor the name. */
    const val UNKNOWN = "Unknown caller"

    /**
     * The body of a kdeconnect.telephony packet. Without the contacts
     * permission, [name] is null, and the packet has only the number. With
     * no number either, the name is [UNKNOWN].
     */
    fun body(e: CallEvent, number: String?, name: String?): JsonObject {
        val n = number?.trim().orEmpty()
        val c = name?.trim().orEmpty().ifEmpty { if (n.isEmpty()) UNKNOWN else "" }
        val fields = buildList {
            add("event" to e.event)
            if (n.isNotEmpty()) add("phoneNumber" to n)
            if (c.isNotEmpty()) add("contactName" to c)
            if (e.cancel) add("isCancel" to true)
        }
        return bodyOf(*fields.toTypedArray())
    }

    fun packet(e: CallEvent, number: String?, name: String?) = Packet(Types.TELEPHONY, body(e, number, name))
}
