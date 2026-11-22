package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsGroupsTest {
    private val ctx = SettingsContext(atOnceSupported = true)

    private fun computer(herdr: Boolean) = DeviceUi(
        id = "pc", name = "pc", type = "laptop", ip = "", paired = true, online = true,
        pairState = PairState.Paired, pairKey = "", pairOutgoing = false,
        battery = null, charging = false, players = emptyList(), player = null,
        commands = emptyList(), commandsLoaded = false, herdrSupported = herdr,
    )

    private fun groups(state: UiState, c: SettingsContext = ctx) = settingsGroups(state, c).associateBy { it.group }

    @Test
    fun theGroupsComeInTheOrderOfTheDesign() {
        val titles = settingsGroups(UiState(), ctx).map { it.group.title }
        assertEquals(
            listOf("Send to the computers", "Alerts on this phone", "This phone on the computer", "Security", "Look and input"),
            titles,
        )
    }

    @Test
    fun eachGroupHoldsItsEntries() {
        val g = groups(UiState(smsSupported = true, devices = listOf(computer(true))))
        assertEquals(listOf("clipboard", "Screenshot", "Photo"), g.getValue(SettingsGroup.Send).keys)
        assertEquals(listOf("agentInput", "agentDone"), g.getValue(SettingsGroup.Alerts).keys)
        assertEquals(listOf("notifications", "sms", "calls", "dnd"), g.getValue(SettingsGroup.Phone).keys)
        assertEquals(listOf("atOnce", "ssh"), g.getValue(SettingsGroup.Security).keys)
        assertEquals(listOf("theme", "touchpad"), g.getValue(SettingsGroup.Look).keys)
    }

    @Test
    fun noSimHidesTextMessagesAndTheCount() {
        val state = UiState(smsSupported = false, smsSync = true, smsAccess = true, shareNotifications = true, notificationAccess = true)
        val phone = groups(state).getValue(SettingsGroup.Phone)
        assertEquals(listOf("notifications", "calls", "dnd"), phone.keys)
        assertEquals("1 of 3 on", phone.summary)
        val withSim = groups(state.copy(smsSupported = true)).getValue(SettingsGroup.Phone)
        assertEquals("2 of 4 on", withSim.summary)
    }

    @Test
    fun agentAlertsHideWithoutAComputerThatSendsAgents() {
        val none = groups(UiState(devices = listOf(computer(false)))).getValue(SettingsGroup.Alerts)
        assertTrue(none.keys.isEmpty())
        val some = groups(UiState(devices = listOf(computer(true)), agentInputAlerts = true, agentDoneAlerts = false)).getValue(SettingsGroup.Alerts)
        assertEquals("1 of 2 on", some.summary)
    }

    @Test
    fun aSwitchWithoutItsPermissionCountsAsOff() {
        val state = UiState(syncClipboard = true, sendScreenshots = true, sendPhotos = true, mediaAccess = false)
        assertEquals("1 of 3 on", groups(state).getValue(SettingsGroup.Send).summary)
        assertEquals("3 of 3 on", groups(state.copy(mediaAccess = true)).getValue(SettingsGroup.Send).summary)
    }

    @Test
    fun securityAndLookShowAStateLine() {
        val g = groups(UiState())
        assertEquals("Fingerprint check at once is off", g.getValue(SettingsGroup.Security).summary)
        assertEquals("Theme follows the computer", g.getValue(SettingsGroup.Look).summary)
        val on = groups(UiState(approveAtOnce = true, theme = ThemeMode.Dark))
        assertEquals("Fingerprint check at once is on", on.getValue(SettingsGroup.Security).summary)
        assertEquals("Theme is dark", on.getValue(SettingsGroup.Look).summary)
    }

    @Test
    fun theFingerprintCheckStaysOffWhereAndroidDoesNotSupportIt() {
        val g = groups(UiState(approveAtOnce = true), SettingsContext(atOnceSupported = false))
        assertEquals("Fingerprint check at once is off", g.getValue(SettingsGroup.Security).summary)
    }
}
