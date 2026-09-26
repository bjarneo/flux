import Foundation

/// The now-playing state of one player on the computer.
public struct RemotePlayer: Sendable, Equatable {
    public var name: String
    public var title = ""
    public var artist = ""
    public var album = ""
    public var playing = false
    /// The position and the length of the track in milliseconds.
    public var position: Int64 = 0
    public var length: Int64 = 0
    public var canSeek = false
    /// The volume from 0 to 100, or nil until the computer reports it.
    public var volume: Int?
    /// The album art that the player reports. Only http and https URLs load on this Mac.
    public var artUrl = ""
    /// The time of the position value, from `ProcessInfo.systemUptime`.
    public var updatedAt: TimeInterval = 0

    public init(name: String) { self.name = name }

    /// The position at the time `now`. It moves forward while the player plays.
    public func position(at now: TimeInterval) -> Int64 {
        guard playing else { return position }
        let moved = position + Int64(((now - updatedAt) * 1000).rounded())
        return min(max(moved, 0), max(length, 0))
    }

    /// The album art URL when this Mac can load it.
    public var artURL: URL? {
        guard let url = URL(string: artUrl), url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }
}

/// The players of one computer and the player that this Mac controls.
public struct RemoteMedia: Sendable, Equatable {
    public var players: [String] = []
    public var current: String?
    public var states: [String: RemotePlayer] = [:]

    public init() {}

    /// The state of the player that this Mac controls.
    public var player: RemotePlayer? { current.flatMap { states[$0] } }

    /// Merges a kdeconnect.mpris packet. It returns the player whose now
    /// playing state this Mac asks for next, if any.
    public mutating func apply(_ p: Packet, now: TimeInterval) -> String? {
        var request: String?
        if p.has("playerList") {
            players = p.body["playerList"]?.strings ?? []
            if current.map({ !players.contains($0) }) ?? true { current = players.first }
            states = states.filter { players.contains($0.key) }
            request = current
        }
        guard let name = p.body["player"]?.string else { return request }
        let b = p.body
        var s = states[name] ?? RemotePlayer(name: name)
        s.title = b["title"]?.string ?? s.title
        s.artist = b["artist"]?.string ?? s.artist
        s.album = b["album"]?.string ?? s.album
        s.playing = b["isPlaying"]?.bool ?? s.playing
        s.position = b["pos"]?.int64 ?? s.position
        s.length = b["length"]?.int64 ?? s.length
        s.canSeek = b["canSeek"]?.bool ?? s.canSeek
        s.volume = b["volume"]?.int ?? s.volume
        s.artUrl = b["albumArtUrl"]?.string ?? s.artUrl
        s.updatedAt = now
        states[name] = s
        if current == nil { current = name }
        if let cur = player, !cur.playing, s.playing { current = name }
        return request
    }

    /// The optimistic state after a PlayPause action, until the computer answers.
    public mutating func togglePlaying(now: TimeInterval) {
        guard let name = current, var s = states[name] else { return }
        if s.playing { s.position += Int64(((now - s.updatedAt) * 1000).rounded()) }
        s.playing.toggle()
        s.updatedAt = now
        states[name] = s
    }

    /// The optimistic state after a seek.
    public mutating func seek(to position: Int64, now: TimeInterval) {
        guard let name = current, var s = states[name] else { return }
        s.position = position
        s.updatedAt = now
        states[name] = s
    }

    /// The optimistic state after a volume change.
    public mutating func setVolume(_ volume: Int) {
        guard let name = current else { return }
        states[name]?.volume = volume
    }
}
