package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteRowsTest {
    private fun device(
        id: String = "a",
        online: Boolean = true,
        paired: Boolean = true,
        all: Boolean = true,
        remoteInput: Boolean? = true,
        remoteDesktop: Boolean? = true,
        player: PlayerState? = null,
        speaker: Boolean = all,
    ) = DeviceUi(
        id = id, name = "name-$id", type = "laptop", ip = "", paired = paired, online = online,
        pairState = PairState.Paired, pairKey = "", pairOutgoing = false, battery = null, charging = false,
        players = emptyList(), player = player, commands = emptyList(), commandsLoaded = false,
        inputSupported = all, remoteInput = remoteInput, desktopSupported = all, remoteDesktop = remoteDesktop,
        extendSupported = all, shortcutsSupported = all, speakerSupported = speaker,
    )

    private fun labels(rows: List<RemoteRow>, group: RemoteGroup) = rows.inGroup(group).map { it.label }

    @Test
    fun ac55GroupsAndOrder() {
        val rows = remoteRows(listOf(device()), null)
        assertEquals(listOf("Remote desktop", "Extend screen"), labels(rows, RemoteGroup.See))
        assertEquals(listOf("Omarchy panel", "Touchpad and keyboard", "Commands", "Media"), labels(rows, RemoteGroup.Use))
        assertEquals(listOf("Webcam", "Mic", "Mirror", "Play on phone"), labels(rows, RemoteGroup.Share))
        assertTrue(rows.all { it.enabled })
        // The groups come in the order See, Use, Share.
        assertEquals(rows.sortedBy { it.group.ordinal }, rows)
    }

    @Test
    fun ac56UnsupportedRowsDoNotShow() {
        val rows = remoteRows(listOf(device(all = false)), null).map { it.label }
        assertEquals(listOf("Commands", "Media", "Webcam", "Mic", "Mirror"), rows)
    }

    @Test
    fun ac56MirrorSaysStopMirrorWhileItRuns() {
        val rows = remoteRows(listOf(device()), null, mirroring = true)
        val mirror = rows.first { it.tool == RemoteTool.Mirror }
        assertEquals("Stop mirror", mirror.label)
        assertTrue(mirror.enabled)
    }

    @Test
    fun ac57MediaShowsWhileAPlayerRuns() {
        val player = PlayerState(name = "mpv", title = "Song", playing = true)
        val rows = remoteRows(listOf(device(player = player)), null)
        assertTrue(rows.any { it.tool == RemoteTool.Media && it.enabled })
        // It shows also with no player and with no feature at all.
        assertTrue(remoteRows(listOf(device(all = false)), null).any { it.tool == RemoteTool.Media })
    }

    @Test
    fun ac59StateLinesWhenInputIsOff() {
        val rows = remoteRows(listOf(device(remoteInput = false)), "a")
        assertEquals("Off on name-a", rows.first { it.tool == RemoteTool.Touchpad }.line)
        assertEquals("View only", rows.first { it.tool == RemoteTool.Desktop }.line)
    }

    @Test
    fun ac59StateLinesWhenTheDesktopIsOff() {
        val rows = remoteRows(listOf(device(remoteDesktop = false)), "a")
        assertEquals("Off on name-a", rows.first { it.tool == RemoteTool.Desktop }.line)
        assertEquals("Off on name-a", rows.first { it.tool == RemoteTool.Extend }.line)
        assertNull(rows.first { it.tool == RemoteTool.Touchpad }.line)
    }

    @Test
    fun ac60RowsAreDimWhileTheComputerIsNotReachable() {
        val rows = remoteRows(listOf(device(online = false)), "a")
        assertEquals(10, rows.size)
        assertTrue(rows.none { it.enabled })
    }

    @Test
    fun ac58PlayOnPhoneStartsAndStops() {
        val live = remoteRows(listOf(device()), null, speaker = SpeakerState.Live).first { it.tool == RemoteTool.Speaker }
        assertEquals("On. Tap to stop.", live.line)
        val off = remoteRows(listOf(device()), null).first { it.tool == RemoteTool.Speaker }
        assertNull(off.line)
        assertTrue(off.enabled)
        // A stream that runs stops with a tap, also when the computer drops.
        val dropped = remoteRows(listOf(device(online = false)), "a", speaker = SpeakerState.Live).first { it.tool == RemoteTool.Speaker }
        assertTrue(dropped.enabled)
    }

    @Test
    fun beforeThePairingAllRowsShowDimmed() {
        val rows = remoteRows(listOf(device(paired = false)), null)
        assertEquals(10, rows.size)
        assertFalse(rows.any { it.enabled })
    }

    @Test
    fun theComputerOfTheRow() {
        val a = device("a")
        val b = device("b")
        assertEquals("a", remoteComputer(listOf(a), null)?.id)
        assertNull(remoteComputer(listOf(a, b), null))
        assertEquals("b", remoteComputer(listOf(a, b), "b")?.id)
    }
}
