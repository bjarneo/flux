package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SendLogTest {
    private fun file(id: Long, state: TransferState = TransferState.Done) =
        SendEntry(id, "pc", "omarchy-xps", SendKind.File, "f$id", size = 100, done = if (state == TransferState.Done) 100 else 0, state = state)

    @Test
    fun addDropsTheOldestFinishedEntries() {
        var list = listOf(file(1, TransferState.Running), file(2), file(3))
        list = addSend(list, file(4), max = 3)
        assertEquals("a running file stays", listOf(1L, 3L, 4L), list.map { it.id })
        list = addSend(list, file(5, TransferState.Running), max = 3)
        assertEquals(listOf(1L, 4L, 5L), list.map { it.id })
    }

    @Test
    fun progressEndAndResume() {
        var list = listOf(file(1, TransferState.Running).copy(size = 0))
        list = progressSend(list, 1, 0, size = 400)
        list = progressSend(list, 1, 100)
        assertEquals(0.25f, list[0].progress)
        list = endSend(list, 1, ok = false)
        assertEquals(TransferState.Failed, list[0].state)
        assertEquals("a failed file keeps the bytes that went through", 100L, list[0].done)
        assertEquals("an ended file takes no progress", 100L, progressSend(list, 1, 300)[0].done)
        list = resumeSend(list, 1, 200)
        assertEquals(TransferState.Running, list[0].state)
        list = endSend(list, 1, ok = true)
        assertEquals(400L, list[0].done)
        assertEquals(1f, list[0].progress)
    }

    @Test
    fun aReceivedFileKeepsItsLinkOnlyWhenItArrived() {
        val list = listOf(file(1, TransferState.Running).copy(incoming = true), file(2, TransferState.Running).copy(incoming = true))
        val done = endSend(endSend(list, 1, ok = true, uri = "content://downloads/1"), 2, ok = false, uri = "content://downloads/2")
        assertEquals("content://downloads/1", done[0].uri)
        assertEquals("a failed file has nothing to open", "", done[1].uri)
    }

    @Test
    fun aFileThatWentOutKeepsItsSource() {
        val list = listOf(file(1, TransferState.Running).copy(uri = "content://media/1"), file(2, TransferState.Running).copy(uri = "content://media/2"))
        val done = endSend(endSend(list, 1, ok = true), 2, ok = false)
        assertEquals("content://media/1", done[0].uri)
        assertEquals("a failed photo still shows", "content://media/2", done[1].uri)
    }

    @Test
    fun aClipFromAComputerTakesThePlaceOfTheLastOne() {
        val sent = SendEntry(1, "pc", "omarchy-xps", SendKind.Clip, "out")
        val first = SendEntry(2, "pc", "omarchy-xps", SendKind.Clip, "a", incoming = true)
        val image = SendEntry(3, "desk", "omarchy-desk", SendKind.ClipImage, "", incoming = true)
        var list = addClipIn(listOf(sent), first)
        list = addClipIn(list, image)
        assertEquals("the clipboard holds 1 clip, and a clip that went out stays", listOf(1L, 3L), list.map { it.id })
    }

    @Test
    fun gateLetsEachPercentThroughOnce() {
        val gate = ProgressGate(1_000)
        assertTrue(gate.pass(0))
        assertFalse(gate.pass(5))
        assertTrue(gate.pass(10))
        assertFalse(gate.pass(19))
        assertTrue(gate.pass(1_000))
        assertFalse("a file with no size never updates", ProgressGate(0).pass(10))
    }

    @Test
    fun logKeepsAShortText() {
        SendLog.replace(emptyList())
        SendLog.text("pc", "omarchy-xps", "  " + "x".repeat(SEND_TEXT_MAX + 50) + "  ")
        val e = SendLog.entries.value.single()
        assertEquals(SEND_TEXT_MAX, e.text.length)
        assertTrue(e.text.endsWith("…"))
        SendLog.clip("pc", "omarchy-xps", null, 42)
        assertEquals(SendKind.ClipImage, SendLog.entries.value.last().kind)
        assertEquals(42L, SendLog.entries.value.last().clipStamp)
        val id = SendLog.fileStarted("pc", "omarchy-xps", "a.pdf", -1, incoming = true)
        assertEquals(0L, SendLog.entries.value.last().size)
        assertTrue(SendLog.fileResumed(id, 0))
        assertFalse(SendLog.fileResumed(-99, 0))
        SendLog.replace(emptyList())
    }

    @Test
    fun logKeepsTheAnswersToApprovals() {
        SendLog.replace(emptyList())
        val r = ApproveRequest(
            computerId = "pc", computerName = "omarchy-xps", id = "r1", kind = ApproveRequest.Kind.Approve,
            host = "omarchy-xps", user = "dev", service = "sudo", tty = "pts/3", rhost = "", time = 0, nonce = "0".repeat(64), timeoutSeconds = 60,
        )
        SendLog.approval(r, approved = true)
        SendLog.approval(r, approved = false)
        val (yes, no) = SendLog.entries.value
        assertEquals(SendKind.Approved, yes.kind)
        assertEquals(SendKind.Denied, no.kind)
        assertEquals("sudo", yes.text)
        assertTrue("the answer shows on the side of the computer", yes.incoming)
        assertEquals(r, yes.approval)
        SendLog.replace(emptyList())
    }

    @Test
    fun clearRemovesOnlyTheEntriesOfOneComputer() {
        val list = listOf(file(1), file(2).copy(deviceId = "laptop"), file(3, TransferState.Running), file(4).copy(deviceId = "laptop"))
        val cleared = clearSends(list, "pc")
        assertEquals(listOf(2L, 4L), cleared.map { it.id })
        assertTrue(clearSends(cleared, "laptop").isEmpty())
        assertEquals("a computer without entries changes nothing", cleared, clearSends(cleared, "other"))
    }

    @Test
    fun removeTakesOutOneEntry() {
        assertEquals(listOf(1L, 3L), removeSend(listOf(file(1), file(2), file(3)), 2).map { it.id })
    }

    @Test
    fun theLogClearsOneComputer() {
        SendLog.replace(listOf(file(1), file(2).copy(deviceId = "laptop")))
        SendLog.clear("pc")
        assertEquals(listOf(2L), SendLog.entries.value.map { it.id })
        SendLog.replace(emptyList())
    }
}
