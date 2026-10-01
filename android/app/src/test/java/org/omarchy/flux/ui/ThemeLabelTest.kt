package org.omarchy.flux.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import org.omarchy.flux.core.ComputerTheme
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.PairState
import org.omarchy.flux.core.UiState
import org.omarchy.flux.theme.SampleThemes
import org.omarchy.flux.theme.paletteOf

class ThemeLabelTest {
    private fun computer(id: String, name: String) = DeviceUi(
        id = id, name = name, type = "laptop", ip = "", paired = true, online = true,
        pairState = PairState.Paired, pairKey = "", pairOutgoing = false, battery = null, charging = false,
        players = emptyList(), player = null, commands = emptyList(), commandsLoaded = false,
    )

    private val desk = computer("desk", "omarchy-desk")
    private val candy = ComputerTheme("desk", SampleThemes.cottonCandy, paletteOf(SampleThemes.cottonCandy))

    @Test
    fun theLineNamesTheThemeAndTheComputer() {
        val state = UiState(devices = listOf(desk), computerTheme = candy)
        assertEquals("cotton-candy from omarchy-desk", computerThemeLine(state, systemDark = true))
    }

    @Test
    fun aThemeWithoutANameNamesTheComputer() {
        val bare = SampleThemes.cottonCandy.copy(name = "")
        val state = UiState(devices = listOf(desk), computerTheme = ComputerTheme("desk", bare, paletteOf(bare)))
        assertEquals("The theme of omarchy-desk", computerThemeLine(state, systemDark = true))
    }

    @Test
    fun aComputerThatIsNotListedShowsOnlyTheTheme() {
        assertEquals("cotton-candy", computerThemeLine(UiState(computerTheme = candy), systemDark = true))
    }

    @Test
    fun withoutAComputerThemeTheLineNamesTheFallback() {
        assertEquals("Tokyo Night until a computer sends its theme", computerThemeLine(UiState(), systemDark = true))
        assertEquals("Tokyo Night Day until a computer sends its theme", computerThemeLine(UiState(), systemDark = false))
        val scoped = UiState(devices = listOf(desk), themeScope = "desk")
        assertEquals("Tokyo Night until omarchy-desk sends its theme", computerThemeLine(scoped, systemDark = true))
    }
}
