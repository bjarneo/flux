package org.omarchy.flux.core

/**
 * The key of each entry of Settings. The keys of the switches match the
 * keys of the sync switches in the UI, so that a refused permission shows
 * its notice under the right switch.
 */
object SettingKey {
    const val CLIPBOARD = "clipboard"
    const val SCREENSHOTS = "Screenshot"
    const val PHOTOS = "Photo"
    const val AGENT_INPUT = "agentInput"
    const val AGENT_DONE = "agentDone"
    const val NOTIFICATIONS = "notifications"
    const val SMS = "sms"
    const val CALLS = "calls"
    const val DND = "dnd"
    const val AT_ONCE = "atOnce"
    const val SSH = "ssh"
    const val THEME = "theme"
    const val TOUCHPAD = "touchpad"
}

/** The 5 groups of Settings, in the order that the screen shows them. */
enum class SettingsGroup(val title: String, val keys: List<String>) {
    Send(
        "Send to the computers",
        listOf(SettingKey.CLIPBOARD, SettingKey.SCREENSHOTS, SettingKey.PHOTOS),
    ),
    Alerts(
        "Alerts on this phone",
        listOf(SettingKey.AGENT_INPUT, SettingKey.AGENT_DONE),
    ),
    Phone(
        "This phone on the computer",
        listOf(SettingKey.NOTIFICATIONS, SettingKey.SMS, SettingKey.CALLS, SettingKey.DND),
    ),
    Security(
        "Security",
        listOf(SettingKey.AT_ONCE, SettingKey.SSH),
    ),
    Look(
        "Look and input",
        listOf(SettingKey.THEME, SettingKey.TOUCHPAD),
    ),
}

/** 1 group of Settings as the screen shows it: the entries that show on this phone, and the summary line. */
data class GroupModel(val group: SettingsGroup, val keys: List<String>, val summary: String)

/** The state of this phone that the groups read, apart from [UiState]. */
data class SettingsContext(
    /** True when Android shows the fingerprint check at once. It is false on Android 10 and 11. */
    val atOnceSupported: Boolean,
)

/**
 * True when a paired computer sends herdr agents. Only then the agent
 * alerts show.
 */
fun hasAgents(state: UiState) = state.devices.any { it.paired && it.herdrSupported }

/**
 * The keys of the switches of [group] that show on this phone. Text
 * messages hide without a SIM slot, and the agent alerts hide until a
 * computer sends agents. The other entries always show.
 */
fun shownKeys(group: SettingsGroup, state: UiState): List<String> = group.keys.filter { key ->
    when (key) {
        SettingKey.SMS -> state.smsSupported
        SettingKey.AGENT_INPUT, SettingKey.AGENT_DONE -> hasAgents(state)
        else -> true
    }
}

/**
 * Whether the switch [key] is on. A switch that needs an Android permission
 * counts as on only with it.
 */
fun switchOn(key: String, state: UiState): Boolean = when (key) {
    SettingKey.CLIPBOARD -> state.syncClipboard
    SettingKey.SCREENSHOTS -> state.sendScreenshots && state.mediaAccess
    SettingKey.PHOTOS -> state.sendPhotos && state.mediaAccess
    SettingKey.AGENT_INPUT -> state.agentInputAlerts
    SettingKey.AGENT_DONE -> state.agentDoneAlerts
    SettingKey.NOTIFICATIONS -> state.shareNotifications && state.notificationAccess
    SettingKey.SMS -> state.smsSync && state.smsAccess
    SettingKey.CALLS -> state.callAlerts && state.callAccess
    SettingKey.DND -> state.syncDnd && state.dndAccess
    else -> false
}

/** The groups that hold switches only. Their summary counts the switches that are on. */
private val SwitchGroups = setOf(SettingsGroup.Send, SettingsGroup.Alerts, SettingsGroup.Phone)

/** The summary line of [group], for example `2 of 3 on` or `Fingerprint check at once is off`. */
fun groupSummary(group: SettingsGroup, state: UiState, context: SettingsContext): String {
    if (group in SwitchGroups) {
        val shown = shownKeys(group, state)
        if (shown.isEmpty()) return "No computer sends agents"
        return "${shown.count { switchOn(it, state) }} of ${shown.size} on"
    }
    return when (group) {
        SettingsGroup.Security ->
            "Fingerprint check at once is ${if (context.atOnceSupported && state.approveAtOnce) "on" else "off"}"
        else -> when (state.theme) {
            ThemeMode.Computer -> "Theme follows the computer"
            ThemeMode.System -> "Theme follows this phone"
            ThemeMode.Light -> "Theme is light"
            ThemeMode.Dark -> "Theme is dark"
        }
    }
}

/** The groups in order, each with the entries that show on this phone and its summary. */
fun settingsGroups(state: UiState, context: SettingsContext): List<GroupModel> =
    SettingsGroup.entries.map { GroupModel(it, shownKeys(it, state), groupSummary(it, state, context)) }
