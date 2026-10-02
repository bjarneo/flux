package org.omarchy.flux.core

/** The pairing state of one device. */
enum class PairState { None, Requested, Incoming, Paired }

/**
 * The color theme of the app. [Computer], the default, follows the
 * Omarchy theme of the computer in scope. Without a theme from a computer,
 * it follows the phone like [System]. [System] follows the dark theme
 * setting of the phone. [Light] and [Dark] are Tokyo Night Day and Tokyo
 * Night.
 */
enum class ThemeMode(val key: String) {
    Computer("computer"),
    System("system"),
    Light("light"),
    Dark("dark");

    companion object {
        fun fromKey(key: String?): ThemeMode = entries.firstOrNull { it.key == key } ?: Computer
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
    val canGoNext: Boolean = true,
    val canGoPrevious: Boolean = true,
    /** The volume from 0 to 100, or null when the player takes no volume. */
    val volume: Int? = null,
    /** The https address of the album art, or empty when the player has none. See [albumArtUrl]. */
    val artUrl: String = "",
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
    /** The last new agent, new terminal, or close from this phone. */
    val herdrAction: HerdrAction? = null,
    /** True when the computer can take the touchpad and the keyboard of this phone. */
    val inputSupported: Boolean = false,
    /** True when remote input is on at the computer, or null before it tells. */
    val remoteInput: Boolean? = null,
    /** True when the computer can stream its screen to this phone. */
    val desktopSupported: Boolean = false,
    /** True when the remote desktop is on at the computer, or null before it tells. */
    val remoteDesktop: Boolean? = null,
    /** True when the computer runs its Hyprland key bindings for this phone. */
    val shortcutsSupported: Boolean = false,
    /** The key bindings and workspaces of the computer, or null before the first answer. */
    val shortcuts: ShortcutsState? = null,
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
    /**
     * Text messages are on. [smsAccess] is true when the phone allows them,
     * and [smsSupported] is true when the phone can send text messages.
     */
    val smsSync: Boolean = false,
    val smsAccess: Boolean = false,
    val smsSupported: Boolean = false,
    /** Notify when a herdr agent on a computer needs input. */
    val agentInputAlerts: Boolean = true,
    /** Notify when a herdr agent on a computer finishes. */
    val agentDoneAlerts: Boolean = true,
    val ringingFrom: String? = null,
    val browse: BrowseState? = null,
    val listeningUdp: Boolean = true,
    /** True while the phone looks for computers. See [FluxCore.scan]. */
    val scanning: Boolean = false,
    /**
     * True for [CONNECT_GRACE_MS] after the network starts or the phone
     * sends its identity again. A paired computer that is not online then
     * counts as connecting, not as not reachable.
     */
    val connecting: Boolean = false,
    /** False while the user has turned Flux off. */
    val enabled: Boolean = true,
    val theme: ThemeMode = ThemeMode.Computer,
    /**
     * The theme that [ThemeMode.Computer] draws. With a [themeScope], it is
     * the theme of that computer. Without a scope, it is the theme that
     * changed most recently. It is null when that computer, or each
     * computer, sent no theme.
     */
    val computerTheme: ComputerTheme? = null,
    /** The computer whose theme the app follows, or null for all computers. See [ComputerThemes.setScope]. */
    val themeScope: String? = null,
    /** The name of the theme of each computer that sent one, by device ID. */
    val computerThemes: Map<String, String> = emptyMap(),
)
