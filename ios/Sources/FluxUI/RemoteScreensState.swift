import Foundation
import FluxProto
import FluxStream

/// App-side store for the reverse-direction remote screens (#1 commands,
/// #2 media): per-computer command lists + media players/state, fed by the
/// `LinkRunner` media/command events and sent back over `LinkService.send`
/// (the D23 app-originated path: `RunCommandMessage` / `MprisMessage`
/// builders).
///
/// A plain value type: the app holds one in `@State` and passes slices
/// into `ContentView` → `CommandsScreen` / `MediaScreen` (state + closure
/// views, no backend). `Sendable` so session-thread events can hop to the
/// main actor before assignment.
public struct RemoteScreensState: Sendable, Equatable {
    /// Connected computers in arrival order (from `.paired`, minus
    /// `.closed`). Drives the Devices list; a computer with no entry in
    /// `commands` simply hasn't sent its list yet.
    public var computers: [String] = []
    /// Desktop command lists in desktop config order, keyed by device.
    /// Presence of the key (even with an empty list) means loaded.
    public var commands: [String: [RemoteCommand]] = [:]
    /// Desktop player lists, keyed by device.
    public var mediaPlayers: [String: [String]] = [:]
    /// Latest now-playing state per device, keyed by device.
    public var mediaState: [String: MprisState] = [:]
    /// Mic session status per device (`StreamSession` → `MicScreen`).
    public var micStatus: [String: StreamStatus] = [:]
    /// Webcam session status per device (`StreamSession` → `CameraScreen`
    /// webcam tab).
    public var webcamStatus: [String: StreamStatus] = [:]
    /// Screen-mirror session status per device (`StreamSession` →
    /// `MirrorScreen`).
    public var screenStatus: [String: StreamStatus] = [:]
    /// Browse-file state per device (`BrowseSession` → `BrowseScreen`).
    public var browseStates: [String: BrowseViewState] = [:]

    public init() {}

    // MARK: - Presence

    /// Records a ready session (fresh pair or pinned reconnect — both
    /// emit `.paired`). Idempotent: re-pairing never duplicates the row.
    public mutating func notePaired(_ device: String) {
        if !computers.contains(device) { computers.append(device) }
    }

    /// Records a closed session and drops that computer's cached remote
    /// state, so a reconnect starts unloaded (a fresh list/state arrives
    /// on demand via the screens' `onRefresh`).
    public mutating func noteClosed(_ device: String) {
        computers.removeAll { $0 == device }
        commands.removeValue(forKey: device)
        mediaPlayers.removeValue(forKey: device)
        mediaState.removeValue(forKey: device)
        micStatus.removeValue(forKey: device)
        webcamStatus.removeValue(forKey: device)
        screenStatus.removeValue(forKey: device)
        browseStates.removeValue(forKey: device)
    }

    // MARK: - Commands (#1)

    /// Stores a desktop command list (`commandListReceived`).
    public mutating func applyCommands(device: String, commands: [RemoteCommand]) {
        notePaired(device)
        self.commands[device] = commands
    }

    /// The list for `CommandsScreen` (`[]` when nothing arrived yet).
    public func commands(for device: String) -> [RemoteCommand] {
        commands[device] ?? []
    }

    /// True once a list arrived — even an empty one ("No commands yet"
    /// renders instead of the loading spinner).
    public func isCommandsLoaded(device: String) -> Bool {
        commands.keys.contains(device)
    }

    // MARK: - Media (#2)

    /// Stores a desktop player list (`mediaPlayersReceived`).
    public mutating func applyPlayers(device: String, players: [String]) {
        notePaired(device)
        mediaPlayers[device] = players
    }

    /// Stores a desktop now-playing state (`mediaStateReceived`).
    public mutating func applyMediaState(device: String, state: MprisState) {
        notePaired(device)
        mediaState[device] = state
    }

    /// The players for `MediaScreen` (`[]` when nothing arrived yet).
    public func players(for device: String) -> [String] {
        mediaPlayers[device] ?? []
    }

    /// The latest state for `MediaScreen` (nil = "Nothing is playing").
    public func mediaState(for device: String) -> MprisState? {
        mediaState[device]
    }

    // MARK: - Microphone (#3, D16)

    /// Stores a mic session status (`StreamSession.onStatus`).
    public mutating func applyMicStatus(device: String, status: StreamStatus) {
        notePaired(device)
        micStatus[device] = status
    }

    /// The status for `MicScreen` (idle when nothing started yet).
    public func micStatus(for device: String) -> StreamStatus {
        micStatus[device] ?? StreamStatus()
    }

    // MARK: - Webcam (#4, D16)

    /// Stores a webcam session status (`StreamSession.onStatus`).
    public mutating func applyWebcamStatus(device: String, status: StreamStatus) {
        notePaired(device)
        webcamStatus[device] = status
    }

    /// The status for the `CameraScreen` webcam tab (idle when nothing
    /// started yet).
    public func webcamStatus(for device: String) -> StreamStatus {
        webcamStatus[device] ?? StreamStatus()
    }

    // MARK: - Screen mirror (#5)

    /// Stores a mirror session status (`StreamSession.onStatus`).
    public mutating func applyScreenStatus(device: String, status: StreamStatus) {
        notePaired(device)
        screenStatus[device] = status
    }

    /// The status for `MirrorScreen` (idle when nothing started yet).
    public func screenStatus(for device: String) -> StreamStatus {
        screenStatus[device] ?? StreamStatus()
    }

    // MARK: - Browse files (#6, D1)

    /// Stores a browse-file state (`BrowseSession` events → `BrowseScreen`).
    public mutating func applyBrowse(device: String, state: BrowseViewState) {
        notePaired(device)
        browseStates[device] = state
    }

    /// Drops a browse-file state (screen closed or session ended — the
    /// next open asks the desktop for a new session, one tunnel each).
    public mutating func dropBrowse(device: String) {
        browseStates.removeValue(forKey: device)
    }

    /// The state for `BrowseScreen` (fresh loading state when never opened).
    public func browseState(for device: String) -> BrowseViewState {
        browseStates[device] ?? BrowseViewState()
    }
}

/// One browse root (display name + path), from the desktop `sftp` offer's
/// `pathNames`+`multiPaths` pairs (Android `BrowseState.roots` parity).
public struct BrowseRoot: Sendable, Equatable, Hashable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Browse-file screen state (Android `BrowseState` parity: loading, error,
/// roots, current path, entries). The app owns one per device in
/// `RemoteScreensState`; `BrowseScreen` renders it.
public struct BrowseViewState: Sendable, Equatable {
    public var loading: Bool
    public var error: String?
    public var roots: [BrowseRoot]
    public var path: String
    public var entries: [BrowseEntry]

    public init(
        loading: Bool = true, error: String? = nil,
        roots: [BrowseRoot] = [], path: String = "",
        entries: [BrowseEntry] = []
    ) {
        self.loading = loading
        self.error = error
        self.roots = roots
        self.path = path
        self.entries = entries
    }
}
