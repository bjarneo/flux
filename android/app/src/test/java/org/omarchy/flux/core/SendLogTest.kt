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
}
