package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.omarchy.flux.protocol.bodyOf

class MediaTest {
    @Test
    fun stateWithVolumeShowsTheVolume() {
        val s = mergePlayer(PlayerState("cliamp"), bodyOf("isPlaying" to true, "volume" to 50, "canGoNext" to true), 7)
        assertEquals(50, s.volume)
        assertEquals(7, s.updatedAt)
    }

    @Test
    fun stateWithoutVolumeClearsTheVolume() {
        val old = PlayerState("chromium", volume = 80)
        val s = mergePlayer(old, bodyOf("isPlaying" to false, "canGoNext" to false, "canGoPrevious" to false), 0)
        assertNull(s.volume)
        assertFalse(s.canGoNext)
        assertFalse(s.canGoPrevious)
    }

    @Test
    fun partialPacketKeepsTheOldFields() {
        val old = PlayerState("spotify", title = "Weightless", volume = 60, canGoNext = false)
        val s = mergePlayer(old, bodyOf("pos" to 1000), 0)
        assertEquals("Weightless", s.title)
        assertEquals(60, s.volume)
        assertFalse(s.canGoNext)
        assertEquals(1000L, s.position)
    }
}
