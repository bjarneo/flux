import AppKit
import Carbon

/// A media player app on this Mac that Flux controls with Apple Events.
struct MacPlayer: Sendable {
    /// The player name that the computer shows.
    let name: String
    let bundleId: String
    /// The distributed notification that the app posts when playback changes.
    let notification: String
    /// Milliseconds per unit of the track duration.
    let durationScale: Double
    /// The track property that identifies the track.
    let trackId: String
    let art: Art

    enum Art {
        /// The raw data of the first artwork element of the track.
        case artwork
        /// The "artwork url" property of the track.
        case url
    }

    static let all = [
        MacPlayer(name: "Music", bundleId: "com.apple.Music", notification: "com.apple.Music.playerInfo",
                  durationScale: 1000, trackId: "persistent ID", art: .artwork),
        MacPlayer(name: "Spotify", bundleId: "com.spotify.client", notification: "com.spotify.client.PlaybackStateChanged",
                  durationScale: 1, trackId: "id", art: .url),
    ]
}

/// The now-playing state of a player on this Mac.
public struct MacPlayerState: Sendable, Equatable {
    public var name: String
    public var title = ""
    public var artist = ""
    public var album = ""
    public var playing = false
    /// The position and the length of the track in milliseconds.
    public var position: Int64 = 0
    public var length: Int64 = 0
    /// The volume from 0 to 100.
    public var volume = 0
    /// The key of the album art that the computer asks for, or "".
    public var artUrl = ""

    public init(name: String) { self.name = name }

    /// The kdeconnect.mpris packet with the now-playing state.
    public var packet: Packet {
        Packet(PacketType.mpris, [
            "player": name, "title": title, "artist": artist, "album": album,
            "nowPlaying": artist.isEmpty ? title : "\(artist) - \(title)",
            "isPlaying": playing, "pos": position, "length": length, "volume": volume,
            "canPlay": true, "canPause": true, "canGoNext": true, "canGoPrevious": true,
            "canSeek": length > 0, "albumArtUrl": artUrl,
        ])
    }

    /// Reports whether the state differs from an earlier state beyond the
    /// position that moved on by itself while the player played.
    public func differs(from old: MacPlayerState, elapsed: TimeInterval) -> Bool {
        var a = self, b = old
        let expected = old.playing ? old.position + Int64(elapsed * 1000) : old.position
        a.position = 0
        b.position = 0
        return a != b || abs(position - expected) > 2000
    }
}

/// Reads and controls the player apps. Every method runs on `queue`, the
/// only place where Flux sends Apple Events.
final class MacPlayers: @unchecked Sendable {
    let queue = DispatchQueue(label: "org.omarchy.flux.media")
    /// Called on the queue after the user allows or denies a player.
    var onPermission: (@Sendable (MacPlayer, Bool) -> Void)?

    private var terms: [String: ScriptingTerms] = [:]
    /// The process of each player that may receive Apple Events.
    private var allowed: [String: pid_t] = [:]
    private var asking: Set<String> = []
    private var reported: Set<String> = []

    /// The running players that Flux may control. For a player that needs
    /// permission, macOS asks the user, and `onPermission` reports the answer.
    func available() -> [MacPlayer] {
        MacPlayer.all.filter { p in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleId).first(where: { !$0.isTerminated }),
                  let url = app.bundleURL else {
                allowed[p.bundleId] = nil
                return false
            }
            let pid = app.processIdentifier
            if allowed[p.bundleId] == pid { return true }
            let address = NSAppleEventDescriptor(processIdentifier: pid)
            let status = AppleEventTarget.permission(address, ask: false)
            switch Int(status) {
            case Int(noErr):
                do {
                    if terms[p.bundleId] == nil { terms[p.bundleId] = try ScriptingTerms(app: p.name, url: url) }
                } catch {
                    report(p, "\(p.name): no scripting terms: \(error)")
                    return false
                }
                allowed[p.bundleId] = pid
                reported.remove(p.bundleId)
                FluxLog.plugin.info("\(p.name, privacy: .public) accepts Apple Events from Flux")
                return true
            case errAEEventWouldRequireUserConsent:
                ask(p, address)
            case errAEEventNotPermitted:
                if !reported.contains(p.bundleId) { onPermission?(p, false) }
                report(p, AppleEventError(app: p.name, status: status).description)
            default:
                report(p, AppleEventError(app: p.name, status: status).description)
            }
            return false
        }
    }

    /// The state of the player, or nil when Flux cannot read it.
    func state(_ p: MacPlayer) -> MacPlayerState? {
        guard let t = target(p) else { return nil }
        var s = MacPlayerState(name: p.name)
        do {
            let playerState = try t.get(t.property("player state"))?.enumCodeValue
            s.playing = playerState == t.terms.enumerator("playing")
            s.volume = Int(try t.get(t.property("sound volume"))?.int32Value ?? 0)
            guard playerState != t.terms.enumerator("stopped") else { return s }
            let track = try t.property("current track")
            s.title = try t.get(t.property("name", of: track))?.stringValue ?? ""
            s.artist = try t.get(t.property("artist", of: track))?.stringValue ?? ""
            s.album = try t.get(t.property("album", of: track))?.stringValue ?? ""
            s.length = Int64((try t.get(t.property("duration", of: track))?.doubleValue ?? 0) * p.durationScale)
            s.position = Int64((try t.get(t.property("player position"))?.doubleValue ?? 0) * 1000)
            switch p.art {
            case .artwork:
                if let id = try t.get(t.property(p.trackId, of: track))?.stringValue, !id.isEmpty {
                    s.artUrl = "x-flux-art://\(p.bundleId)/\(id)"
                }
            case .url:
                s.artUrl = try t.get(t.property("artwork url", of: track))?.stringValue ?? ""
            }
            return s
        } catch let e as AppleEventError where e.status == errAENoSuchObject {
            // No current track.
            return s
        } catch {
            fail(p, error)
            return nil
        }
    }

    /// Runs PlayPause, Play, Pause, Next, Previous, or Stop.
    func perform(_ action: String, _ p: MacPlayer) {
        let names: [String]
        switch action {
        case "PlayPause": names = ["playpause"]
        case "Play": names = ["play"]
        case "Pause": names = ["pause"]
        case "Next": names = ["next track"]
        case "Previous": names = ["previous track"]
        // Spotify has no stop command.
        case "Stop": names = ["stop", "pause"]
        default:
            FluxLog.plugin.info("unknown media action \(action, privacy: .public)")
            return
        }
        guard let t = target(p) else { return }
        do {
            try t.command(names)
            FluxLog.plugin.info("\(p.name, privacy: .public): \(action, privacy: .public)")
        } catch {
            fail(p, error)
        }
    }

    /// Moves the current track to the position in milliseconds.
    func setPosition(_ ms: Int64, _ p: MacPlayer) {
        guard let t = target(p) else { return }
        do {
            try t.set(t.property("player position"), to: NSAppleEventDescriptor(double: Double(max(ms, 0)) / 1000))
        } catch {
            fail(p, error)
        }
    }

    /// Moves the position by an offset in microseconds.
    func seek(by offsetUs: Int64, _ p: MacPlayer) {
        guard let t = target(p) else { return }
        do {
            let seconds = try t.get(t.property("player position"))?.doubleValue ?? 0
            try t.set(t.property("player position"), to: NSAppleEventDescriptor(double: max(seconds + Double(offsetUs) / 1_000_000, 0)))
        } catch {
            fail(p, error)
        }
    }

    /// Sets the volume of the player, from 0 to 100.
    func setVolume(_ volume: Int, _ p: MacPlayer) {
        guard let t = target(p) else { return }
        do {
            try t.set(t.property("sound volume"), to: NSAppleEventDescriptor(int32: Int32(min(max(volume, 0), 100))))
        } catch {
            fail(p, error)
        }
    }

    /// The image data of the current track, for a player with artwork elements.
    func artwork(_ p: MacPlayer) -> Data? {
        guard p.art == .artwork, let t = target(p) else { return nil }
        do {
            let art = try t.element("artwork", 1, of: t.property("current track"))
            return try t.get(t.property("raw data", of: art), timeout: 10)?.data
        } catch let e as AppleEventError where e.status == errAENoSuchObject {
            return nil
        } catch {
            fail(p, error)
            return nil
        }
    }

    private func target(_ p: MacPlayer) -> AppleEventTarget? {
        guard let pid = allowed[p.bundleId], let terms = terms[p.bundleId] else { return nil }
        return AppleEventTarget(terms: terms, pid: pid)
    }

    /// Asks the user once, on another thread, because the question blocks.
    private func ask(_ p: MacPlayer, _ address: NSAppleEventDescriptor) {
        guard asking.insert(p.bundleId).inserted else { return }
        FluxLog.plugin.info("asking the user to let Flux control \(p.name, privacy: .public)")
        DispatchQueue.global().async { [self] in
            let status = AppleEventTarget.permission(address, ask: true)
            queue.async { [self] in
                asking.remove(p.bundleId)
                if status == noErr {
                    FluxLog.plugin.info("the user lets Flux control \(p.name, privacy: .public)")
                } else {
                    reported.insert(p.bundleId)
                    FluxLog.plugin.error("\(AppleEventError(app: p.name, status: status).description, privacy: .public)")
                }
                onPermission?(p, status == noErr)
            }
        }
    }

    private func fail(_ p: MacPlayer, _ error: Error) {
        if let e = error as? AppleEventError, Int(e.status) == errAEEventNotPermitted || Int(e.status) == procNotFound {
            // The user took the permission back, or the app quit.
            allowed[p.bundleId] = nil
        }
        FluxLog.plugin.error("\(String(describing: error), privacy: .public)")
    }

    /// Logs a problem with a player once, until the player works again.
    private func report(_ p: MacPlayer, _ message: String) {
        guard reported.insert(p.bundleId).inserted else { return }
        FluxLog.plugin.error("\(message, privacy: .public)")
    }
}
