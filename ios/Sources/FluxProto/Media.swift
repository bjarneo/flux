import Foundation

/// M4 media + commands packets: `kdeconnect.mpris` state,
/// `kdeconnect.mpris.request` control, `kdeconnect.runcommand` lists, and
/// `kdeconnect.runcommand.request` runs.
///
/// Sources of truth: `internal/core/media.go` (`PhoneMediaAction` verbs,
/// `handleDesktopMediaRequest` fields, `sendPlayerList`/`sendNowPlaying`
/// shapes), `internal/core/handlers.go` (`handleRunCommand`,
/// `sendCommandList`), Android `core/Plugins.kt` (`receiveMpris`,
/// `requestPlayers`, `mediaAction`, `seek`, `requestCommands`, `runCommand`,
/// `parseCommands`), and `cmd/flux/main.go` (`media` verb map).
///
/// Direction notes (do not "improve" the wire):
/// - Desktop→phone `kdeconnect.mpris` carries the desktop player state
///   (`playerList`, then `player` + metadata). The phone never publishes
///   its own state in v1 (no outgoing `mpris`, like Android).
/// - Phone→desktop `kdeconnect.mpris.request` controls desktop players
///   (`requestPlayerList`, `requestNowPlaying` + `requestVolume`, `action`,
///   `SetPosition`/`Seek`, `setVolume` — Go reads all of them).
/// - Desktop→phone `kdeconnect.mpris.request` is `flux media *`
///   (`PhoneMediaAction` → `d.send`, ungated): the phone acts on it through
///   `MPRemoteCommandCenter` (`NowPlayingBridge`). Only the six verbs Go
///   accepts are valid actions; anything else is unhandled.
/// - Desktop→phone `kdeconnect.runcommand` carries the list as a JSON
///   *string* (`sendCommandList` marshals the map to a string, in config
///   order — phones show that order, so the parse preserves it).
///   `canAddCommand` is false: commands are edited in `config.toml`.
/// - Phone→desktop `kdeconnect.runcommand.request` asks for the list
///   (`requestCommandList`) or runs one command (`key`). Phone-requests,
///   desktop-runs only — the phone never executes commands.

// MARK: - Media actions

/// The six verbs Go `PhoneMediaAction` accepts (wire strings, case-exact).
/// `flux media ACTION` maps `play-pause/play/pause/next/previous|prev/stop`
/// onto these (`cmd/flux/main.go`).
public enum MediaAction: String, Sendable, CaseIterable {
    case playPause = "PlayPause"
    case play = "Play"
    case pause = "Pause"
    case next = "Next"
    case previous = "Previous"
    case stop = "Stop"

    public static func isValid(_ s: String) -> Bool {
        MediaAction(rawValue: s) != nil
    }
}

// MARK: - Desktop player state (kdeconnect.mpris)

/// One desktop player's now-playing state, as `sendNowPlaying` sends it.
/// Only the fields Android `receiveMpris` keeps are required; volume +
/// capability flags ride along for the Media screen.
public struct MprisState: Sendable, Equatable {
    public var player: String
    public var title: String
    public var artist: String
    public var album: String
    public var playing: Bool
    /// Position / length in ms (`pos` / `length`).
    public var position: Int64
    public var length: Int64
    public var canSeek: Bool
    public var volume: Int?
    public var canPlay: Bool?
    public var canPause: Bool?
    public var canGoNext: Bool?
    public var canGoPrevious: Bool?
    public var albumArtUrl: String?

    public init(
        player: String, title: String = "", artist: String = "",
        album: String = "", playing: Bool = false,
        position: Int64 = 0, length: Int64 = 0, canSeek: Bool = false,
        volume: Int? = nil, canPlay: Bool? = nil, canPause: Bool? = nil,
        canGoNext: Bool? = nil, canGoPrevious: Bool? = nil,
        albumArtUrl: String? = nil
    ) {
        self.player = player
        self.title = title
        self.artist = artist
        self.album = album
        self.playing = playing
        self.position = position
        self.length = length
        self.canSeek = canSeek
        self.volume = volume
        self.canPlay = canPlay
        self.canPause = canPause
        self.canGoNext = canGoNext
        self.canGoPrevious = canGoPrevious
        self.albumArtUrl = albumArtUrl
    }
}

/// A parsed desktop→phone `kdeconnect.mpris` packet. `sendPlayerList`
/// sends a bare list (no `player`); `sendNowPlaying` sends a state, usually
/// beside a list. Either half may be absent, never both.
public struct MprisUpdate: Sendable, Equatable {
    public var players: [String]?
    public var state: MprisState?

    public init(players: [String]? = nil, state: MprisState? = nil) {
        self.players = players
        self.state = state
    }
}

/// `kdeconnect.mpris` + `kdeconnect.mpris.request` packets.
public enum MprisMessage {
    // MARK: Parse desktop state

    /// Parses a desktop→phone `kdeconnect.mpris` packet. Returns nil for
    /// other types, or a packet with neither `playerList` nor `player`
    /// (Android `receiveMpris` likewise needs one of them).
    public static func parse(_ p: Packet) -> MprisUpdate? {
        guard p.type == PacketType.mpris else { return nil }
        var update = MprisUpdate()
        if p.has("playerList") {
            update.players = p.strings("playerList")
        }
        guard let name = p.string("player"), !name.isEmpty else {
            return update.players == nil ? nil : update
        }
        update.state = MprisState(
            player: name,
            title: p.string("title") ?? "",
            artist: p.string("artist") ?? "",
            album: p.string("album") ?? "",
            playing: p.bool("isPlaying") ?? false,
            position: p.long("pos") ?? 0,
            length: p.long("length") ?? 0,
            canSeek: p.bool("canSeek") ?? false,
            volume: p.int("volume"),
            canPlay: p.bool("canPlay"),
            canPause: p.bool("canPause"),
            canGoNext: p.bool("canGoNext"),
            canGoPrevious: p.bool("canGoPrevious"),
            albumArtUrl: p.string("albumArtUrl")
        )
        return update
    }

    // MARK: Phone→desktop control (Media screen)

    /// Asks for the desktop player list (Android `requestPlayers`).
    public static func requestPlayerList() -> Packet {
        Packet.of(PacketType.mprisRequest, ("requestPlayerList", true))
    }

    /// Asks for one player's state + volume (Android `requestNowPlaying`).
    public static func requestNowPlaying(player: String) -> Packet {
        Packet.of(
            PacketType.mprisRequest,
            ("player", player),
            ("requestNowPlaying", true),
            ("requestVolume", true)
        )
    }

    /// Controls a desktop player (Android `mediaAction`). The verb must be
    /// a `MediaAction`; anything else is rejected by Go `PhoneMediaAction`.
    public static func action(player: String, action: String) -> Packet? {
        guard MediaAction.isValid(action) else { return nil }
        return Packet.of(PacketType.mprisRequest, ("player", player), ("action", action))
    }

    /// Seeks a desktop player (Android `seek` sends `SetPosition`).
    public static func seek(player: String, positionMs: Int64) -> Packet {
        Packet.of(PacketType.mprisRequest, ("player", player), ("SetPosition", positionMs))
    }

    /// Sets a desktop player's volume (Go `handleDesktopMediaRequest`
    /// reads `setVolume`; Android never sends it).
    public static func setVolume(player: String, volume: Int) -> Packet {
        Packet.of(PacketType.mprisRequest, ("player", player), ("setVolume", volume))
    }

    // MARK: Phone-as-player answers (flux media * role)

    /// Answers a desktop `requestPlayerList` with our players (v1: the
    /// single iPhone player, or empty when nothing plays). Shape mirrors
    /// Go `sendPlayerList`.
    public static func playerListPacket(_ players: [String]) -> Packet {
        var p = Packet(type: PacketType.mpris)
        p.body = [
            "playerList": .array(players.map { .string($0) }),
            "supportAlbumArtPayload": .bool(false),
        ]
        return p
    }

    /// Answers a desktop `requestNowPlaying` with our state. Shape mirrors
    /// Go `sendNowPlaying` (minus capabilities the phone does not report).
    public static func statePacket(_ s: MprisState) -> Packet {
        var body: [String: JSONValue] = [
            "player": .string(s.player),
            "title": .string(s.title),
            "artist": .string(s.artist),
            "album": .string(s.album),
            "isPlaying": .bool(s.playing),
            "pos": .integer(s.position),
            "length": .integer(s.length),
            "canSeek": .bool(s.canSeek),
        ]
        if let url = s.albumArtUrl, !url.isEmpty { body["albumArtUrl"] = .string(url) }
        return Packet(type: PacketType.mpris, body: body)
    }
}

/// A parsed desktop→phone `kdeconnect.mpris.request` packet (`flux media`
/// + desktop follow-ups). Field names mirror Go
/// `handleDesktopMediaRequest` exactly (`Seek` *and* `SetPosition` are
/// capital-S; `setVolume` is lowercase).
public enum MprisRequest: Sendable, Equatable {
    case playerList
    case nowPlaying(player: String)
    case action(player: String, action: String)
    case seek(player: String, positionMs: Int64)
    case setVolume(player: String, volume: Int)
    /// The desktop wants album art for `url` (sent only after the phone
    /// publishes a state with that URL — never in v1, answered with
    /// nothing; see the deferred-work log).
    case albumArt(player: String, url: String)

    public static func parse(_ p: Packet) -> MprisRequest? {
        guard p.type == PacketType.mprisRequest else { return nil }
        if p.bool("requestPlayerList") == true { return .playerList }
        // Device finding 2026-09-27 (M4 hardware first): Go
        // `PhoneMediaAction` sends `"player": ""` when the phone
        // publishes no state (v1/D13: never — `dev.media` is nil), and
        // the strict non-empty guard dropped it as "no handler" (the
        // loopback always sends `"player": "Music"`, so it never saw
        // this). Accept the empty player: the event still surfaces on
        // the status line and `NowPlayingBridge.handle` no-ops on the
        // unknown player (logged, never sent anywhere).
        let player = p.string("player") ?? ""
        if let action = p.string("action"), !action.isEmpty {
            return .action(player: player, action: action)
        }
        if let pos = p.long("Seek") ?? p.long("SetPosition") {
            return .seek(player: player, positionMs: pos)
        }
        if let volume = p.int("setVolume") {
            return .setVolume(player: player, volume: volume)
        }
        if p.bool("requestNowPlaying") == true || p.bool("requestVolume") == true {
            return .nowPlaying(player: player)
        }
        if let url = p.string("albumArtUrl"), !url.isEmpty {
            return .albumArt(player: player, url: url)
        }
        return nil
    }
}

// MARK: - Run commands (kdeconnect.runcommand)

/// One desktop command the phone can run. Port of Android `RemoteCommand`.
public struct RemoteCommand: Sendable, Equatable {
    public var key: String
    public var name: String
    public var command: String

    public init(key: String, name: String, command: String) {
        self.key = key
        self.name = name
        self.command = command
    }
}

/// `kdeconnect.runcommand` (desktop→phone list) +
/// `kdeconnect.runcommand.request` (phone→desktop run) packets.
public enum RunCommandMessage {
    /// Parses the desktop command list. `commandList` is a JSON *string*
    /// (Go `sendCommandList`); a bare object is also accepted (Android
    /// `parseCommands` reads either). Order is the desktop config order —
    /// the string form preserves it, the object form cannot (JSON objects
    /// are unordered; best-effort there).
    public static func parseList(_ p: Packet) -> (commands: [RemoteCommand], canAddCommand: Bool)? {
        guard p.type == PacketType.runCommand else { return nil }
        guard let raw = p.body["commandList"] else { return nil }
        let entries: [(key: String, name: String, command: String)]
        switch raw {
        case .string(let s):
            entries = parseListString(s)
        case .object(let o):
            entries = o.map { (k, v) -> (String, String, String)? in
                guard case .object(let f) = v else { return nil }
                return (k, f["name"]?.string ?? k, f["command"]?.string ?? "")
            }.compactMap { $0 }
        default:
            return nil
        }
        return (entries.map { RemoteCommand(key: $0.key, name: $0.name, command: $0.command) },
                p.bool("canAddCommand") ?? false)
    }

    /// Asks for the desktop command list (Android `requestCommands`).
    public static func requestList() -> Packet {
        Packet.of(PacketType.runCommandRequest, ("requestCommandList", true))
    }

    /// Runs one desktop command by key (Android `runCommand`). An empty key
    /// builds nothing (Go `handleRunCommand` returns early on it).
    public static func run(key: String) -> Packet? {
        guard !key.isEmpty else { return nil }
        return Packet.of(PacketType.runCommandRequest, ("key", key))
    }

    // MARK: - Ordered list parsing

    /// Reads the top-level entries of a `{"id": {"name","command"}}`
    /// object string in order. Keys and string values honor JSON escapes;
    /// non-object values are dropped (Android `parseCommands` parity).
    /// Returns [] for malformed input (never throws — a bad list shows
    /// "No commands", not a crash).
    static func parseListString(_ s: String) -> [(key: String, name: String, command: String)] {
        var out: [(String, String, String)] = []
        let chars = Array(s)
        var i = chars.startIndex
        func skipWS() { while i < chars.endIndex, chars[i].isWhitespace { i += 1 } }
        /// Reads `"..."` at i (i points at the quote). Nil when absent.
        func readString() -> String? {
            guard i < chars.endIndex, chars[i] == "\"" else { return nil }
            i += 1
            var out = ""
            while i < chars.endIndex {
                let c = chars[i]
                if c == "\"" { i += 1; return out }
                if c == "\\", i + 1 < chars.endIndex {
                    let e = chars[i + 1]
                    switch e {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "u" where i + 5 < chars.endIndex:
                        let hex = String(chars[(i + 2)...(i + 5)])
                        if let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) {
                            out.append(Character(sc))
                        }
                        i += 6
                        continue
                    default: out.append(e)
                    }
                    i += 2
                    continue
                }
                out.append(c)
                i += 1
            }
            return nil
        }
        /// Skips one JSON value at i (objects/arrays nest, strings honor
        /// escapes). Records nothing.
        func skipValue() {
            skipWS()
            guard i < chars.endIndex else { return }
            switch chars[i] {
            case "\"": _ = readString()
            case "{", "[":
                let open = chars[i]
                let close: Character = open == "{" ? "}" : "]"
                i += 1
                var depth = 1
                var inStr = false
                while i < chars.endIndex, depth > 0 {
                    let c = chars[i]
                    if inStr {
                        if c == "\\" { i += 1 }
                        else if c == "\"" { inStr = false }
                    } else if c == "\"" {
                        inStr = true
                    } else if c == open {
                        depth += 1
                    } else if c == close {
                        depth -= 1
                    }
                    i += 1
                }
            default:
                while i < chars.endIndex, !",}]".contains(chars[i]) { i += 1 }
            }
        }
        skipWS()
        guard i < chars.endIndex, chars[i] == "{" else { return [] }
        i += 1
        while true {
            skipWS()
            guard i < chars.endIndex else { break }
            if chars[i] == "}" { break }
            guard let key = readString() else { break }
            skipWS()
            guard i < chars.endIndex, chars[i] == ":" else { break }
            i += 1
            skipWS()
            if i < chars.endIndex, chars[i] == "{" {
                // {"name": ..., "command": ...} — unknown fields skipped.
                i += 1
                var name: String?
                var command: String?
                while true {
                    skipWS()
                    guard i < chars.endIndex, chars[i] != "}" else { break }
                    guard let field = readString() else { break }
                    skipWS()
                    guard i < chars.endIndex, chars[i] == ":" else { break }
                    i += 1
                    skipWS()
                    if field == "name" || field == "command" {
                        let v = readString()
                        if field == "name" { name = v } else { command = v }
                        if v == nil { skipValue() }
                    } else {
                        skipValue()
                    }
                    skipWS()
                    if i < chars.endIndex, chars[i] == "," { i += 1 }
                }
                if i < chars.endIndex, chars[i] == "}" { i += 1 }
                out.append((key, name ?? key, command ?? ""))
            } else {
                skipValue()
            }
            skipWS()
            if i < chars.endIndex, chars[i] == "," { i += 1 }
        }
        return out
    }
}
