package org.omarchy.flux.ui

import androidx.compose.ui.unit.dp
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
}
