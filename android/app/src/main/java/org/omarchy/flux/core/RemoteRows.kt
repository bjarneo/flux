package org.omarchy.flux.core

/** The 3 groups of the Remote screen, in the order that they show. */
enum class RemoteGroup(val title: String) {
    See("See"),
    Use("Use"),
    Share("Share"),
}

/** The state of Play on phone for the row in Share. */
enum class SpeakerState { Off, Connecting, Live, Failed }

/** A row of the Remote screen. The order of the entries is the order on the screen. */
enum class RemoteTool(val group: RemoteGroup, val label: String) {
    Desktop(RemoteGroup.See, "Remote desktop"),
    Extend(RemoteGroup.See, "Extend screen"),
    Panel(RemoteGroup.Use, "Omarchy panel"),
    Touchpad(RemoteGroup.Use, "Touchpad and keyboard"),
    Commands(RemoteGroup.Use, "Commands"),
    Media(RemoteGroup.Use, "Media"),
    Webcam(RemoteGroup.Share, "Webcam"),
    Mic(RemoteGroup.Share, "Mic"),
    Mirror(RemoteGroup.Share, "Mirror"),
    Speaker(RemoteGroup.Share, "Play on phone"),
}

/**
 * A row of the Remote screen: the [label], the state [line] under it or
 * null, and whether the row takes a tap. A row that is not [enabled] shows
 * dimmed.
 */
data class RemoteRow(val tool: RemoteTool, val label: String, val line: String?, val enabled: Boolean) {
    val group: RemoteGroup get() = tool.group
}

/**
 * The rows of the Remote screen for the computers in [scope]. A row shows
 * when a paired computer in scope has the feature, also while it is not
 * reachable. Before the first pairing, all rows show. Commands, Media,
 * Webcam, Mic, and Mirror show for every computer.
 *
 * A row takes a tap when a computer in scope is reachable and has the
 * feature. [mirroring] is true while this phone mirrors its screen, and
 * Mirror then says Stop mirror. [speaker] is the state of Play on phone.
 */
fun remoteRows(
    devices: List<DeviceUi>,
    scope: String?,
    mirroring: Boolean = false,
    speaker: SpeakerState = SpeakerState.Off,
): List<RemoteRow> {
    val any = target(scope, devices)
    val one = (any as? Target.One)?.device
    val none = devices.none { it.paired }
    fun shows(can: (DeviceUi) -> Boolean) = none || hasFeature(scope, devices, can)
    fun canRun(can: (DeviceUi) -> Boolean) = target(scope, devices, can) !is Target.None
    val reachable = any !is Target.None
    val rows = ArrayList<RemoteRow>()
    fun add(tool: RemoteTool, line: String?, enabled: Boolean, label: String = tool.label) {
        rows += RemoteRow(tool, label, line, enabled)
    }
    if (shows { it.desktopSupported }) {
        val line = when {
            one == null -> null
            one.remoteDesktop != true -> "Off on ${one.name}"
            one.remoteInput != true -> "View only"
            else -> null
        }
        add(RemoteTool.Desktop, line, canRun { it.desktopSupported })
    }
    if (shows { it.extendSupported }) {
        val line = if (one != null && one.remoteDesktop != true) "Off on ${one.name}" else null
        add(RemoteTool.Extend, line, canRun { it.extendSupported })
    }
    if (shows { it.shortcutsSupported }) {
        val s = one?.shortcuts
        val line = if (s?.loaded == true && s.active > 0) {
            val n = s.workspaces.firstOrNull { it.id == s.active }?.windows ?: 0
            "Workspace ${s.active} · $n ${if (n == 1) "window" else "windows"}"
        } else {
            null
        }
        add(RemoteTool.Panel, line, canRun { it.shortcutsSupported })
    }
    if (shows { it.inputSupported }) {
        val line = if (one != null && one.remoteInput != true) "Off on ${one.name}" else null
        add(RemoteTool.Touchpad, line, canRun { it.inputSupported })
    }
    add(RemoteTool.Commands, null, reachable)
    // The Media row shows also while a player runs in the dock.
    add(RemoteTool.Media, null, reachable)
    add(RemoteTool.Webcam, null, reachable)
    add(RemoteTool.Mic, null, reachable)
    if (mirroring) add(RemoteTool.Mirror, null, true, label = "Stop mirror") else add(RemoteTool.Mirror, null, reachable)
    if (shows { it.speakerSupported }) {
        val line = when (speaker) {
            SpeakerState.Live -> "On. Tap to stop."
            SpeakerState.Connecting -> "Connecting. Tap to stop."
            SpeakerState.Failed -> "Failed. Tap to try again."
            SpeakerState.Off -> null
        }
        // A stream that runs stops with a tap, also when no computer is reachable.
        add(RemoteTool.Speaker, line, canRun { it.speakerSupported } || speaker == SpeakerState.Live || speaker == SpeakerState.Connecting)
    }
    return rows
}

/** The rows of [rows] for 1 group. */
fun List<RemoteRow>.inGroup(group: RemoteGroup): List<RemoteRow> = filter { it.group == group }

/**
 * The computer that the row under the header of Remote describes: the
 * computer in [scope], or the only paired computer. It is null when the
 * scope is all computers and more than 1 computer is paired.
 */
fun remoteComputer(devices: List<DeviceUi>, scope: String?): DeviceUi? {
    val paired = devices.filter { it.paired }
    return if (scope != null) paired.firstOrNull { it.id == scope } else paired.singleOrNull()
}
