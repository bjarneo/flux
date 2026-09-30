package org.omarchy.flux.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.Identity
import org.omarchy.flux.protocol.MAX_IDENTITY_LINE
import org.omarchy.flux.protocol.OUTGOING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.SMS_INCOMING
import org.omarchy.flux.protocol.SMS_OUTGOING
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import org.omarchy.flux.protocol.long
import org.omarchy.flux.protocol.str

class SmsTest {
    private fun msg(id: Long, thread: Long = 1, type: Int = SmsPackets.INBOX, read: Boolean = true, mms: Boolean = false, date: Long = id * 1000) =
        TextMessage(id, thread, "text $id", date, type, read, subId = 2, addresses = listOf("+4791234567"), mms = mms)

    @Test
    fun identityListsSmsOnlyWhenOn() {
        val off = Identity.self("0123456789abcdef0123456789abcdef", "Pixel", 1717)
        assertEquals(INCOMING, off.incoming)
        assertEquals(OUTGOING, off.outgoing)
        assertFalse(Types.SMS_MESSAGES in off.outgoing)

        val on = Identity.self("0123456789abcdef0123456789abcdef", "Pixel", 1717, sms = true)
        assertTrue(on.incoming.containsAll(SMS_INCOMING))
        assertTrue(on.outgoing.containsAll(SMS_OUTGOING))
        assertTrue(Types.SMS_REQUEST_CONVERSATION in on.incoming)
        assertTrue(Types.SMS_MESSAGES in on.outgoing)
        assertTrue(on.toPacket(withPort = true).serialize().length < MAX_IDENTITY_LINE)
    }

    @Test
    fun messagesPacket() {
        val m = TextMessage(7, 3, "Hi", 1790000000123, SmsPackets.SENT, read = true, subId = 1, addresses = listOf("+4791234567"))
        val p = Packet.parse(SmsPackets.messages(listOf(m), mapOf("+4791234567" to "Kari")).serialize())!!
        assertEquals(Types.SMS_MESSAGES, p.type)
        assertEquals(2, p.int("version"))
        assertFalse("only a thread answer has threadID", p.has("threadID"))
        val o = p.array("messages")!!.single() as JsonObject
        assertEquals(7L, o.long("_id"))
        assertEquals(3L, o.long("thread_id"))
        assertEquals("Hi", o.str("body"))
        assertEquals(1790000000123, o.long("date"))
        assertEquals(2L, o.long("type"))
        assertEquals(1L, o.long("read"))
        assertEquals(1L, o.long("sub_id"))
        assertEquals(1L, o.long("event"))
        val a = (o["addresses"] as JsonArray).single() as JsonObject
        assertEquals("+4791234567", a.str("address"))
        assertEquals("Kari", a.str("contactName"))
    }

    @Test
    fun threadAnswerAndGroupMessage() {
        val group = msg(1).copy(addresses = listOf("+4791234567", "+4798765432"), read = false)
        val p = Packet.parse(SmsPackets.messages(listOf(group), threadId = 1).serialize())!!
        assertEquals(1L, p.long("threadID"))
        val o = p.array("messages")!!.single() as JsonObject
        assertEquals("a message to more than 1 address is multi-target", 3L, o.long("event"))
        assertEquals(0L, o.long("read"))
        // Without a contact name, an address has no contactName.
        val first = (o["addresses"] as JsonArray).first() as JsonObject
        assertEquals(setOf("address"), first.keys)

        // An empty thread still names the thread, so that the computer stops waiting.
        val empty = Packet.parse(SmsPackets.messages(emptyList(), threadId = 9).serialize())!!
        assertEquals(9L, empty.long("threadID"))
        assertEquals(0, empty.array("messages")!!.size)
    }

    @Test
    fun sendRequest() {
        val v2 = Packet(
            Types.SMS_REQUEST,
            bodyOf(
                "version" to 2, "messageBody" to "On my way", "subID" to 1,
                "addresses" to listOf(mapOf("address" to " +4791234567 "), mapOf("address" to "+4791234567"), mapOf("address" to "")),
            ),
        )
        assertEquals(SmsSend(listOf("+4791234567"), "On my way", 1), SmsPackets.send(v2))

        // A request without a SIM uses the default SIM.
        val to = listOf(mapOf("address" to "12345"))
        assertEquals(SmsSend(listOf("12345"), "Hi", -1), SmsPackets.send(Packet(Types.SMS_REQUEST, bodyOf("addresses" to to, "messageBody" to "Hi"))))

        assertNull(SmsPackets.send(Packet(Types.SMS_REQUEST, bodyOf("addresses" to to, "messageBody" to "  "))))
        assertNull(SmsPackets.send(Packet(Types.SMS_REQUEST, bodyOf("messageBody" to "Hi"))))
        assertNull(SmsPackets.send(Packet(Types.SMS_REQUEST, bodyOf("addresses" to to))))
        // A request needs the list of addresses. A single phoneNumber is not enough.
        assertNull(SmsPackets.send(Packet(Types.SMS_REQUEST, bodyOf("phoneNumber" to "12345", "messageBody" to "Hi"))))
    }

    @Test
    fun sendLimitCountsCharacters() {
        assertFalse(SmsPackets.tooLong("a".repeat(SmsPackets.MAX_SEND)))
        assertTrue(SmsPackets.tooLong("a".repeat(SmsPackets.MAX_SEND + 1)))
        // An emoji takes 2 UTF-16 units, but it is 1 character, as in fluxd.
        assertFalse(SmsPackets.tooLong("\uD83D\uDE00".repeat(SmsPackets.MAX_SEND)))
        assertTrue(SmsPackets.tooLong("\uD83D\uDE00".repeat(SmsPackets.MAX_SEND + 1)))
    }

    @Test
    fun threadRequest() {
        val p = Packet(Types.SMS_REQUEST_CONVERSATION, bodyOf("threadID" to 4, "numberToRequest" to 100))
        assertEquals(ThreadRequest(4, 100), SmsPackets.thread(p))
        val none = Packet(Types.SMS_REQUEST_CONVERSATION, bodyOf("threadID" to "4"))
        assertEquals(ThreadRequest(4, SmsPackets.DEFAULT_THREAD), SmsPackets.thread(none))
        val big = Packet(Types.SMS_REQUEST_CONVERSATION, bodyOf("threadID" to 4, "numberToRequest" to 1_000_000))
        assertEquals(ThreadRequest(4, SmsPackets.MAX_THREAD), SmsPackets.thread(big))
        assertNull(SmsPackets.thread(Packet(Types.SMS_REQUEST_CONVERSATION, bodyOf("numberToRequest" to 5))))
    }

    @Test
    fun newestPerThread() {
        val n = NewestPerThread()
        n.offer(MessageRef(false, 1, 10, 1000))
        n.offer(MessageRef(false, 2, 10, 3000))
        n.offer(MessageRef(true, 1, 10, 2000))
        n.offer(MessageRef(true, 2, 20, 5000))
        n.offer(MessageRef(false, 3, 30, 4000))
        assertEquals(
            listOf(MessageRef(true, 2, 20, 5000), MessageRef(false, 3, 30, 4000), MessageRef(false, 2, 10, 3000)),
            n.result(10),
        )
        assertEquals(listOf(MessageRef(true, 2, 20, 5000)), n.result(1))
    }

    @Test
    fun changesSendSentAndReadMessagesAgain() {
        val c = SmsChanges()
        val sending = msg(1, type = SmsPackets.OUTBOX)
        val unread = msg(2, read = false)
        val old = msg(3)
        listOf(sending, unread, old).forEach(c::watch)
        assertEquals(listOf(1L, 2L), c.ids(mms = false))

        // Nothing changed yet.
        assertEquals(emptyList<TextMessage>(), c.changed(listOf(sending, unread)))

        // The message went out, and the user read the other on the phone.
        val sent = sending.copy(type = SmsPackets.SENT)
        val read = unread.copy(read = true)
        assertEquals(listOf(sent, read), c.changed(listOf(sent, read)))
        listOf(sent, read).forEach(c::watch)
        assertEquals("a sent or read message is done", emptyList<Long>(), c.ids(mms = false))
    }

    @Test
    fun changesForgetDeletedMessages() {
        val c = SmsChanges()
        c.watch(msg(1, read = false))
        c.watch(msg(1, read = false, mms = true))
        assertEquals(listOf(1L), c.ids(mms = true))
        assertEquals(emptyList<TextMessage>(), c.changed(listOf(msg(1, read = false))))
        assertEquals("the MMS is gone", emptyList<Long>(), c.ids(mms = true))
        assertEquals(listOf(1L), c.ids(mms = false))
    }

    @Test
    fun changesKeepTheNewestWhenFull() {
        val c = SmsChanges(capacity = 2)
        for (id in 1L..3L) c.watch(msg(id, read = false))
        assertEquals(listOf(2L, 3L), c.ids(mms = false))
    }

    @Test
    fun mmsAddresses() {
        val people = listOf("+47 912 34 567", "+4798765432")
        // A received message starts with the sender, then the other people.
        assertEquals(
            listOf("+4798765432", "+47 912 34 567"),
            SmsPackets.mmsAddresses(SmsPackets.INBOX, "+4798765432", listOf("+4790000000"), people),
        )
        // A sent message goes to the people in the thread.
        assertEquals(people, SmsPackets.mmsAddresses(SmsPackets.SENT, null, listOf("+4790000000"), people))
        // Without the thread table, the message gives the addresses.
        assertEquals(
            listOf("91234567", "+4798765432"),
            SmsPackets.mmsAddresses(SmsPackets.INBOX, "91234567", listOf("+4791234567", "+4798765432"), emptyList()),
        )
    }

    @Test
    fun samePhone() {
        assertTrue(SmsPackets.samePhone("+47 912 34 567", "91234567"))
        assertTrue(SmsPackets.samePhone("(912) 345-67", "91234567"))
        assertFalse(SmsPackets.samePhone("91234567", "91234568"))
        assertTrue(SmsPackets.samePhone("Kari@Example.com", "kari@example.com"))
        assertFalse(SmsPackets.samePhone("kari@example.com", "12345"))
    }

    @Test
    fun attachmentLabels() {
        assertEquals("[Image]", SmsPackets.attachmentLabel("image/jpeg"))
        assertEquals("[Video]", SmsPackets.attachmentLabel("video/mp4"))
        assertEquals("[Audio]", SmsPackets.attachmentLabel("audio/amr"))
        assertEquals("[Contact]", SmsPackets.attachmentLabel("text/x-vcard"))
        assertEquals("[Attachment]", SmsPackets.attachmentLabel("application/pdf"))
    }

    @Test
    fun aLongTextIsCut() {
        assertEquals("short", SmsPackets.clip("short"))
        val long = "a".repeat(SmsPackets.MAX_BODY + 10)
        assertEquals(SmsPackets.MAX_BODY + SmsPackets.CUT_MARK.length, SmsPackets.clip(long).length)
        assertTrue(SmsPackets.clip(long).endsWith(SmsPackets.CUT_MARK))
        // A cut does not split a character that takes 2 UTF-16 units.
        val emoji = "a".repeat(SmsPackets.MAX_BODY - 1) + "\uD83D\uDE00"
        assertEquals("a".repeat(SmsPackets.MAX_BODY - 1) + SmsPackets.CUT_MARK, SmsPackets.clip(emoji))
    }

    @Test
    fun largeAnswersSplitBelowTheBudget() {
        val list = (1L..10L).map { msg(it, date = 100 - it).copy(body = "x".repeat(1000)) }
        val budget = 3500
        val packets = SmsPackets.messagePackets(list, budget = budget)
        assertTrue(packets.size > 1)
        assertTrue(packets.all { it.serialize().length < budget + 200 })
        val ids = packets.flatMap { p -> p.array("messages")!!.map { (it as JsonObject).long("_id") } }
        assertEquals("a list with no thread keeps every message", list.map { it.id }, ids)

        val thread = SmsPackets.messagePackets(list, threadId = 1, budget = budget)
        assertEquals("the computer takes 1 answer to a thread request", 1, thread.size)
        val kept = thread.single().array("messages")!!.map { (it as JsonObject).long("_id") }
        assertEquals("the answer keeps the newest messages", list.take(kept.size).map { it.id }, kept)
        assertEquals(1L, thread.single().long("threadID"))

        val empty = SmsPackets.messagePackets(emptyList(), threadId = 5)
        assertEquals(1, empty.size)
        assertEquals(0, empty.single().array("messages")!!.size)
    }

    @Test
    fun onlyTheFirstPacketOfTheConversationsMarksIt() {
        val list = (1L..10L).map { msg(it, thread = it, date = 100 - it).copy(body = "x".repeat(1000)) }
        val packets = SmsPackets.messagePackets(list, budget = 3500, conversations = true)
        assertTrue(packets.size > 1)
        // The computer replaces its list with the first packet and adds the others.
        assertEquals(true, packets.first().bool("conversations"))
        assertTrue(packets.drop(1).none { it.has("conversations") })
        assertFalse(packets.first().has("threadID"))

        // An empty list still clears the list of the computer.
        val none = SmsPackets.messagePackets(emptyList(), conversations = true).single()
        assertEquals(true, none.bool("conversations"))
        assertEquals(0, none.array("messages")!!.size)

        // The new messages that the change watch sends have no mark.
        assertTrue(SmsPackets.messagePackets(list.take(1)).none { it.has("conversations") })
    }
}
