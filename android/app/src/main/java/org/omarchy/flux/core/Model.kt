package org.omarchy.flux.core

/** The pairing state of one device. */
enum class PairState { None, Requested, Incoming, Paired }

/** The color theme of the app. [System] follows the dark theme setting of the phone. */
enum class ThemeMode(val key: String) {
    System("system"),
    Light("light"),
    Dark("dark");

    companion object {
        fun fromKey(key: String?): ThemeMode = entries.firstOrNull { it.key == key } ?: System
    }
}

/** The now-playing state of one player on the PC. */
data class PlayerState(
    val name: String,
    val title: String = "",
    val artist: String = "",
    val album: String = "",
    val playing: Boolean = false,
    val position: Long = 0,
    val length: Long = 0,
    val canSeek: Boolean = false,
    /** The time of the position value, from SystemClock.elapsedRealtime. */
    val updatedAt: Long = 0,
)

/** A command that the PC publishes. */
data class RemoteCommand(val key: String, val name: String, val command: String)

/** One entry of a folder on the PC. */
data class BrowseEntry(val name: String, val path: String, val dir: Boolean, val size: Long)

/** The state of the Browse PC screen. */
data class BrowseState(
    val deviceId: String,
    val loading: Boolean = true,
    val error: String? = null,
    val roots: List<Pair<String, String>> = emptyList(),
    val path: String = "",
    val entries: List<BrowseEntry> = emptyList(),
)

/** A snapshot of one device for the UI. */
data class DeviceUi(
    val id: String,
    val name: String,
    val type: String,
    val ip: String,
    val isFlux: Boolean,
    val paired: Boolean,
    val online: Boolean,
    val pairState: PairState,
    val pairKey: String,
    /** True when this phone started the pairing and waits for the user to confirm. */
    val pairOutgoing: Boolean,
    val battery: Int?,
    val charging: Boolean,
    val players: List<String>,
    val player: PlayerState?,
    val commands: List<RemoteCommand>,
    val commandsLoaded: Boolean,
    /** True when the computer can send its herdr agents. */
    val herdrSupported: Boolean = false,
    /** The herdr agents, or null before the first agent list. */
    val herdr: HerdrState? = null,
    /** The output of the pane on the agent screen. */
    val herdrOutput: HerdrOutput? = null,
    /** The last reply from the agent screen. */
    val herdrReply: HerdrReply? = null,
)

/** A snapshot of the whole app for the UI. */
data class UiState(
    val phoneName: String = "",
    val onWifi: Boolean = false,
    val devices: List<DeviceUi> = emptyList(),
    val shareNotifications: Boolean = true,
    val syncClipboard: Boolean = true,
    val syncDnd: Boolean = true,
    /** Flux may read and set Do Not Disturb. */
    val dndAccess: Boolean = false,
    val sendScreenshots: Boolean = false,
    val sendPhotos: Boolean = false,
    /** Flux can see every new image. */
    val mediaAccess: Boolean = false,
    val notificationAccess: Boolean = false,
    /** Call alerts are on. [callAccess] is true when the phone allows them. */
    val callAlerts: Boolean = false,
    val callAccess: Boolean = false,
    /** Notify when a herdr agent on a computer needs input. */
    val agentInputAlerts: Boolean = true,
    /** Notify when a herdr agent on a computer finishes. */
    val agentDoneAlerts: Boolean = true,
    val ringingFrom: String? = null,
    val browse: BrowseState? = null,
    val listeningUdp: Boolean = true,
    /** False while the user has turned Flux off. */
    val enabled: Boolean = true,
    val theme: ThemeMode = ThemeMode.System,
)
