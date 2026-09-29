package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationGateTest {
    private val laptop = "laptop"
    private val desktop = "desktop"
    private val key = "0|com.example.chat|1|null|10123"

    @Test
    fun aComputerActsOnlyOnWhatItGot() {
        val gate = NotificationGate()
        gate.record(laptop, key, setOf("Mark as read"))
        assertTrue(gate.knows(laptop, key))
        assertTrue(gate.allows(laptop, key, "Mark as read"))
        assertFalse("a button that the phone did not share", gate.allows(laptop, key, "Delete"))
        assertFalse("a key that the phone did not share", gate.knows(laptop, "0|org.omarchy.flux|1|null|10200"))
        assertFalse("a computer that did not get the key", gate.knows(desktop, key))
        assertFalse(gate.allows(desktop, key, "Mark as read"))
    }

    @Test
    fun anUpdateReplacesTheButtons() {
        val gate = NotificationGate()
        gate.record(laptop, key, setOf("Accept", "Decline"))
        gate.record(laptop, key, setOf("Archive"))
        assertFalse(gate.allows(laptop, key, "Accept"))
        assertTrue(gate.allows(laptop, key, "Archive"))
    }

    @Test
    fun aRemovedNotificationIsForgotten() {
        val gate = NotificationGate()
        gate.record(laptop, key, setOf("Reply"))
        gate.record(desktop, key, emptySet())
        gate.record(desktop, "other", emptySet())
        assertEquals(setOf(laptop, desktop), gate.forget(key).toSet())
        assertFalse(gate.knows(laptop, key))
        assertFalse(gate.knows(desktop, key))
        assertTrue(gate.knows(desktop, "other"))
        assertTrue("a second removal finds no computer", gate.forget(key).isEmpty())
    }

    @Test
    fun theSwitchAndAnUnpairClearTheGate() {
        val gate = NotificationGate()
        gate.record(laptop, key, setOf("Reply"))
        gate.record(desktop, key, setOf("Reply"))
        gate.forgetDevice(desktop)
        assertFalse(gate.knows(desktop, key))
        assertTrue(gate.knows(laptop, key))
        assertEquals(mapOf(laptop to setOf(key)), gate.keys())
        gate.clear()
        assertFalse(gate.knows(laptop, key))
        assertFalse(gate.allows(laptop, key, "Reply"))
    }

    @Test
    fun pickLeavesOutInputsAndLockedActions() {
        val actions = listOf(
            ActionFacts("Reply", freeFormReply = true, hasInputs = true, needsUnlock = false),
            ActionFacts("Quick answer", freeFormReply = false, hasInputs = true, needsUnlock = false),
            ActionFacts("Mark as read", freeFormReply = false, hasInputs = false, needsUnlock = false),
            ActionFacts("Approve", freeFormReply = false, hasInputs = false, needsUnlock = true),
            ActionFacts(null, freeFormReply = false, hasInputs = false, needsUnlock = false),
        )
        val picked = NotificationGate.pick(actions)
        assertEquals(0, picked.reply)
        assertEquals(listOf(2), picked.buttons)
    }

    @Test
    fun aReplyThatNeedsTheUnlockIsNotShared() {
        val picked = NotificationGate.pick(
            listOf(
                ActionFacts("Reply", freeFormReply = true, hasInputs = true, needsUnlock = true),
                ActionFacts("Mute", freeFormReply = false, hasInputs = false, needsUnlock = false),
            ),
        )
        assertNull(picked.reply)
        assertEquals(listOf(1), picked.buttons)
    }
}
