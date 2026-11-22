package org.omarchy.flux.ui

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WindowSizeTest {
    @Test
    fun aPhoneInPortraitIsNotWide() {
        assertFalse(isWideWindow(411.dp, 891.dp))
        assertFalse(isSplitWindow(411.dp, 891.dp))
    }

    @Test
    fun aTabletInPortraitHasThePhoneLayout() {
        assertFalse(isWideWindow(800.dp, 1280.dp))
        assertFalse(isSplitWindow(800.dp, 1280.dp))
    }

    @Test
    fun aTabletInLandscapeIsWideWithASecondPart() {
        assertTrue(isWideWindow(1280.dp, 800.dp))
        assertTrue(isSplitWindow(1280.dp, 800.dp))
    }

    @Test
    fun aPhoneInLandscapeIsWideWithNoSecondPart() {
        assertTrue(isWideWindow(891.dp, 411.dp))
        assertFalse(isSplitWindow(891.dp, 411.dp))
    }

    @Test
    fun aWindowNarrowerThan600DpIsNotWide() {
        assertFalse(isWideWindow(599.dp, 300.dp))
    }

    @Test
    fun theRowsTakeColumnsOnlyInAWideWindow() {
        assertEquals(1, adaptiveColumns(800.dp, wide = false, count = 4, gap = 8.dp))
        assertEquals(2, adaptiveColumns(800.dp, wide = true, count = 4, gap = 8.dp))
        assertEquals(1, adaptiveColumns(800.dp, wide = true, count = 1, gap = 8.dp))
        assertEquals(3, adaptiveColumns(1100.dp, wide = true, count = 5, gap = 8.dp))
        assertEquals(2, adaptiveColumns(1100.dp, wide = true, count = 2, gap = 8.dp))
    }
}
