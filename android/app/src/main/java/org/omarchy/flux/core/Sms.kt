package org.omarchy.flux.core

import kotlinx.serialization.json.JsonObject
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import org.omarchy.flux.protocol.str

/**
 * 1 text message from the SMS or the MMS table of the phone. [date] is in
 * milliseconds, and [type] uses the SMS message types. The first address of
 * a received message is the sender. [subId] is -1 when the phone does not
 * know the SIM.
 */
data class TextMessage(
    val id: Long,
    val threadId: Long,
    val body: String,
    val date: Long,
    val type: Int,
    val read: Boolean,
    val subId: Int,
    val addresses: List<String>,
    val mms: Boolean = false,
)

/** A request from a computer to send a text message. [subId] is -1 for the default SIM. */
data class SmsSend(val addresses: List<String>, val body: String, val subId: Int)

/** A request from a computer for the newest messages of 1 thread. */
data class ThreadRequest(val threadId: Long, val count: Int)

/** The place of 1 message in the SMS or the MMS table. [date] is in milliseconds. */
data class MessageRef(val mms: Boolean, val id: Long, val threadId: Long, val date: Long)

/**
 * The flux.sms packets. An address can carry contactName, and the answer
 * to a thread request carries threadID.
 */
object SmsPackets {
    // The message types of the SMS table. The MMS boxes use the same values.
    const val INBOX = 1
    const val SENT = 2
    const val DRAFT = 3
    const val OUTBOX = 4
    const val FAILED = 5
    const val QUEUED = 6

    /** The number of messages that a thread request gets when it gives no number. */
    const val DEFAULT_THREAD = 100

    /** The most messages that 1 thread request gets. */
    const val MAX_THREAD = 500

    // The event flags of a message.
    private const val EVENT_TEXT = 1
    private const val EVENT_MULTI_TARGET = 2

    /**
     * The flux.sms.messages packet for [list]. [names] maps an address
     * to its contact name. [threadId] marks the answer to a thread request,
     * so that the computer can tell it from a new message.
     */
    fun messages(list: List<TextMessage>, names: Map<String, String> = emptyMap(), threadId: Long? = null): Packet {
        val fields = buildList {
            add("version" to 2)
            add("messages" to list.map { message(it, names) })
            if (threadId != null) add("threadID" to threadId)
        }
        return Packet(Types.SMS_MESSAGES, bodyOf(*fields.toTypedArray()))
    }

    private fun message(m: TextMessage, names: Map<String, String>): JsonObject = bodyOf(
        "_id" to m.id,
        "thread_id" to m.threadId,
        "body" to m.body,
        "date" to m.date,
        "type" to m.type,
        "read" to if (m.read) 1 else 0,
        "sub_id" to m.subId,
        "event" to if (m.addresses.size > 1) EVENT_TEXT or EVENT_MULTI_TARGET else EVENT_TEXT,
        "addresses" to m.addresses.map { a ->
            val name = names[a]?.trim().orEmpty()
            if (name.isEmpty()) mapOf("address" to a) else mapOf("address" to a, "contactName" to name)
        },
    )

    /**
     * Reads a flux.sms.request, which gives a list of addresses. It returns
     * null without an address or a message.
     */
    fun send(p: Packet): SmsSend? {
        val addresses = p.array("addresses")?.mapNotNull { (it as? JsonObject)?.str("address") }.orEmpty()
            .map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        val body = p.string("messageBody") ?: return null
        if (addresses.isEmpty() || body.isBlank()) return null
        return SmsSend(addresses, body, p.int("subID") ?: -1)
    }

    /**
     * Reads a flux.sms.request_conversation. A missing or bad
     * numberToRequest gets [DEFAULT_THREAD].
     */
    fun thread(p: Packet): ThreadRequest? {
        val id = p.long("threadID") ?: return null
        val n = p.int("numberToRequest")?.takeIf { it > 0 } ?: DEFAULT_THREAD
        return ThreadRequest(id, n.coerceAtMost(MAX_THREAD))
    }

    /** True for a sent message that is still on its way. */
    fun pending(type: Int) = type == OUTBOX || type == QUEUED

    /** The text that stands for an MMS attachment of the MIME type. */
    fun attachmentLabel(mime: String): String = when {
        mime.startsWith("image/") -> "[Image]"
        mime.startsWith("video/") -> "[Video]"
        mime.startsWith("audio/") -> "[Audio]"
        mime == "text/x-vcard" || mime == "text/vcard" -> "[Contact]"
        else -> "[Attachment]"
    }

    /**
     * The addresses of 1 MMS of [type]. [people] are the other people in
     * the thread. A received message starts with its sender [from]. Without
     * [people], the receivers [to] of the message are the rest, and they
     * can include this phone.
     */
    fun mmsAddresses(type: Int, from: String?, to: List<String>, people: List<String>): List<String> {
        val rest = people.ifEmpty { to }
        if (type != INBOX || from == null) return rest.distinct()
        return (listOf(from) + rest.filter { !samePhone(it, from) }).distinct()
    }

    /**
     * Reports whether 2 addresses are the same phone. Phone numbers match
     * on their last 8 digits, so that +47 912 34 567 matches 91234567.
     * Other addresses, such as email addresses, match without case.
     */
    fun samePhone(a: String, b: String): Boolean {
        val da = a.filter { it.isDigit() }
        val db = b.filter { it.isDigit() }
        val phone = { s: String, d: String -> d.length >= 3 && s.all { it.isDigit() || it in "+-() ." } }
        if (!phone(a, da) || !phone(b, db)) return a.equals(b, ignoreCase = true)
        return da.takeLast(8) == db.takeLast(8)
    }
}

/**
 * Finds the newest message of each thread in the SMS and MMS tables. The
 * reader gives each message to [offer] in any order.
 */
class NewestPerThread {
    private val newest = HashMap<Long, MessageRef>()

    fun offer(r: MessageRef) {
        val old = newest[r.threadId]
        if (old == null || r.date > old.date) newest[r.threadId] = r
    }

    /** The newest message of the [limit] most recent threads, the most recent first. */
    fun result(limit: Int): List<MessageRef> = newest.values.sortedByDescending { it.date }.take(limit)
}

/**
 * Decides which known messages go to the computers again after the SMS
 * tables change. It watches each sent message that is still on its way and
 * each received message that is unread. A new type or read state then goes
 * out, so that the computer shows a sent message and clears an unread
 * conversation. It watches at most [capacity] messages, and it forgets the
 * oldest first.
 */
class SmsChanges(private val capacity: Int = 200) {
    private data class Key(val mms: Boolean, val id: Long)
    private data class Status(val type: Int, val read: Boolean)

    private val watched = LinkedHashMap<Key, Status>()

    /** Records a message that went to a computer. */
    fun watch(m: TextMessage) {
        val key = Key(m.mms, m.id)
        watched.remove(key)
        if (SmsPackets.pending(m.type) || (m.type == SmsPackets.INBOX && !m.read)) {
            watched[key] = Status(m.type, m.read)
            while (watched.size > capacity) watched.remove(watched.keys.first())
        }
    }

    /** The IDs of the watched messages in the SMS table, or in the MMS table with [mms]. */
    fun ids(mms: Boolean): List<Long> = watched.keys.filter { it.mms == mms }.map { it.id }

    /**
     * Compares [current], the watched messages as the tables have them now,
     * with the recorded state. It returns the messages that changed, and it
     * forgets the watched messages that are gone.
     */
    fun changed(current: List<TextMessage>): List<TextMessage> {
        val now = current.associateBy { Key(it.mms, it.id) }
        watched.keys.retainAll(now.keys)
        return current.filter { m -> watched[Key(m.mms, m.id)]?.let { it != Status(m.type, m.read) } == true }
    }
}
