package org.omarchy.flux.core

/** The pairing state of one device. */
enum class PairState { None, Requested, Incoming, Paired }

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
)

/** A snapshot of the whole app for the UI. */
data class UiState(
    val phoneName: String = "",
    val onWifi: Boolean = false,
    val devices: List<DeviceUi> = emptyList(),
    val shareNotifications: Boolean = true,
    val syncClipboard: Boolean = true,
    val notificationAccess: Boolean = false,
    /** Call alerts are on. [callAccess] is true when the phone allows them. */
    val callAlerts: Boolean = false,
    val callAccess: Boolean = false,
    val ringingFrom: String? = null,
    val browse: BrowseState? = null,
    val listeningUdp: Boolean = true,
)
