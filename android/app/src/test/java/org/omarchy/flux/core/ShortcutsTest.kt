package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.OUTGOING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf

class ShortcutsTest {
    private val terminal = Shortcut("315", "SUPER RETURN", "Terminal")
    private val browser = Shortcut("317", "SUPER SHIFT RETURN", "Browser")
    private val close = Shortcut("68", "SUPER W", "Close window")

    @Test
    fun capabilityIsInBothLists() {
        assertTrue(Types.FLUX_SHORTCUTS in INCOMING)
        assertTrue(Types.FLUX_SHORTCUTS in OUTGOING)
    }

    @Test
    fun packets() {
        assertEquals(true, Shortcuts.request().bool("request"))
        assertTrue(Shortcuts.refresh().body.isEmpty())
        assertEquals("315", Shortcuts.run(terminal).string("run"))
        assertEquals("close", Shortcuts.action(Shortcuts.Action.Close).string("action"))
        val ws = Shortcuts.workspace(3)
        assertEquals("workspace", ws.string("action"))
        assertEquals(3, ws.int("workspace"))
        assertEquals("moveToWorkspace", Shortcuts.moveToWorkspace(10).string("action"))
        val swap = Shortcuts.swap(Shortcuts.Direction.Left)
        assertEquals("swap", swap.string("action"))
        assertEquals("l", swap.string("direction"))
        assertEquals("u", Shortcuts.focus(Shortcuts.Direction.Up).string("direction"))
    }

    @Test
    fun superAndADigitSelectsAWorkspace() {
        val sup = RemoteInput.Mods(meta = true)
        assertEquals(3, Shortcuts.forDigit("3", sup)!!.int("workspace"))
        assertEquals("workspace", Shortcuts.forDigit("3", sup)!!.string("action"))
        // 0 is workspace 10, as on the keyboard.
        assertEquals(10, Shortcuts.forDigit("0", sup)!!.int("workspace"))
        val move = Shortcuts.forDigit("5", sup.copy(shift = true))!!
        assertEquals("moveToWorkspace", move.string("action"))
        assertEquals(5, move.int("workspace"))
        assertNull(Shortcuts.forDigit("a", sup))
        assertNull(Shortcuts.forDigit("12", sup))
        assertNull(Shortcuts.forDigit("3", RemoteInput.Mods(ctrl = true)))
        assertNull(Shortcuts.forDigit("3", sup.copy(alt = true)))
    }

    @Test
    fun mergeKeepsTheListForAWorkspaceAnswer() {
        val first = Shortcuts.merge(
            null,
            Packet(
                Types.FLUX_SHORTCUTS,
                bodyOf(
                    "shortcuts" to listOf(mapOf("ref" to "315", "keys" to "SUPER RETURN", "description" to "Terminal")),
                    "workspaces" to listOf(mapOf("id" to 1, "windows" to 2), mapOf("id" to 3, "windows" to 0)),
                    "active" to 1,
                ),
            ),
        )
        assertTrue(first.loaded)
        assertEquals(listOf(terminal), first.shortcuts)
        assertEquals(listOf(WorkspaceInfo(1, 2), WorkspaceInfo(3, 0)), first.workspaces)
        assertEquals(1, first.active)

        val next = Shortcuts.merge(first, Packet(Types.FLUX_SHORTCUTS, bodyOf("workspaces" to listOf(mapOf("id" to 4, "windows" to 1)), "active" to 4)))
        assertEquals(listOf(terminal), next.shortcuts)
        assertEquals(4, next.active)

        val failed = Shortcuts.merge(next, Packet(Types.FLUX_SHORTCUTS, bodyOf("error" to "Remote input is off")))
        assertEquals("Remote input is off", failed.error)
        assertEquals(listOf(terminal), failed.shortcuts)
        assertNull(Shortcuts.merge(failed, Packet(Types.FLUX_SHORTCUTS, bodyOf("active" to 2))).error)
    }

    @Test
    fun pinsKeepTheirOrderAndSkipMissingShortcuts() {
        val all = listOf(close, terminal, browser)
        assertEquals(listOf(browser, terminal), Shortcuts.pinned(all, listOf("Browser", "Music", "Terminal")))
    }

    @Test
    fun searchMatchesEachWord() {
        val all = listOf(close, terminal, browser)
        assertEquals(all, Shortcuts.search(all, "  "))
        assertEquals(listOf(browser), Shortcuts.search(all, "brow"))
        assertEquals(listOf(browser), Shortcuts.search(all, "shift return"))
        assertEquals(listOf(close, browser), Shortcuts.search(all, "super w"))
    }
}
