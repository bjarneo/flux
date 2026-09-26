import AppKit
import NIOCore

/// A kdeconnect.mpris.request from the computer, which controls a player on this Mac.
public struct MprisRequest: Sendable, Equatable {
    public var requestPlayerList = false
    public var player = ""
    /// requestNowPlaying or requestVolume: the computer wants the state of the player.
    public var requestNowPlaying = false
    public var action: String?
    /// Seek: an offset in microseconds.
    public var seek: Int64?
    /// SetPosition: a position in milliseconds.
    public var setPosition: Int64?
    /// setVolume: a volume from 0 to 100.
    public var setVolume: Int?
    /// The album art that the computer wants as a payload.
    public var albumArtUrl: String?

    public init(_ p: Packet) {
        let b = p.body
        requestPlayerList = b["requestPlayerList"]?.bool ?? false
        player = b["player"]?.string ?? ""
        requestNowPlaying = b["requestNowPlaying"]?.bool == true || b["requestVolume"]?.bool == true
        action = b["action"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        seek = b["Seek"]?.int64
        setPosition = b["SetPosition"]?.int64
        setVolume = b["setVolume"]?.int
        albumArtUrl = b["albumArtUrl"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// True when the request changes the player.
    var changes: Bool { action != nil || seek != nil || setPosition != nil || setVolume != nil }
}

/// kdeconnect.mpris.request in, kdeconnect.mpris out: the computer controls
/// Music and Spotify on this Mac, like the players of a phone.
public final class MacMediaPlugin: FluxPlugin, @unchecked Sendable {
    private weak var core: FluxCore?
    private let players = MacPlayers()
    // The state that every computer got last. Guarded by players.queue.
    private var sentList: [String]?
    private var sent: [String: (state: MacPlayerState, at: TimeInterval)] = [:]
    private var timer: DispatchSourceTimer?

    public init() {}

    public let incoming = [PacketType.mprisRequest]
    public let outgoing = [PacketType.mpris]

    /// How often Flux checks for changes that the players do not announce,
    /// such as a seek in the app.
    private static let checkInterval: TimeInterval = 5
    /// The largest album art that Flux sends.
    private static let maxArt = 16 << 20

    public func attach(core: FluxCore) {
        self.core = core
        players.onPermission = { [weak self] player, allowed in
            if allowed {
                self?.refresh()
            } else {
                self?.core?.toast("Allow Flux to control \(player.name) in System Settings > Privacy & Security > Automation")
            }
        }
        let center = DistributedNotificationCenter.default()
        for p in MacPlayer.all {
            _ = center.addObserver(forName: Notification.Name(p.notification), object: nil, queue: nil) { [weak self] _ in
                self?.scheduleRefresh()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            _ = workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if MacPlayer.all.contains(where: { $0.bundleId == app?.bundleIdentifier }) { self?.scheduleRefresh() }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: players.queue)
        timer.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        players.queue.async { self.timer = timer }
    }

    public func handle(_ packet: Packet, from device: Device) {
        let request = MprisRequest(packet)
        let id = device.id
        let certificate = device.certificate
        players.queue.async { [self] in serve(request, deviceId: id, certificate: certificate) }
    }

    // MARK: Requests

    private func serve(_ r: MprisRequest, deviceId: String, certificate: [UInt8]?) {
        let available = players.available()
        if r.requestPlayerList {
            send(playerList(available.map(\.name)), to: [deviceId])
        }
        guard !r.player.isEmpty else { return }
        guard let player = available.first(where: { $0.name == r.player }) else {
            FluxLog.plugin.info("media request for \(r.player, privacy: .public), which does not run or is not allowed")
            return
        }
        if let action = r.action { players.perform(action, player) }
        if let offset = r.seek { players.seek(by: offset, player) }
        if let ms = r.setPosition { players.setPosition(ms, player) }
        if let volume = r.setVolume { players.setVolume(volume, player) }
        if r.requestNowPlaying, let s = players.state(player) { send(s.packet, to: [deviceId]) }
        if r.changes { refresh() }
        if let url = r.albumArtUrl { sendArt(player, url: url, to: deviceId, certificate: certificate) }
    }

    private func playerList(_ names: [String]) -> Packet {
        Packet(PacketType.mpris, ["playerList": names, "supportAlbumArtPayload": true])
    }

    // MARK: Changes

    private func scheduleRefresh() {
        players.queue.async { [weak self] in self?.refresh() }
    }

    /// Sends the player list and the player states that changed to every
    /// computer that controls media. Runs on players.queue.
    private func refresh() {
        let ids = controllers()
        guard !ids.isEmpty else {
            sentList = nil
            sent = [:]
            return
        }
        let available = players.available()
        let names = available.map(\.name)
        if names != sentList {
            sentList = names
            send(playerList(names), to: ids)
        }
        sent = sent.filter { names.contains($0.key) }
        let now = ProcessInfo.processInfo.systemUptime
        for p in available {
            guard let s = players.state(p) else { continue }
            if let last = sent[p.name], !s.differs(from: last.state, elapsed: now - last.at) { continue }
            sent[p.name] = (s, now)
            send(s.packet, to: ids)
        }
    }

    /// The connected computers that take player states.
    private func controllers() -> [String] {
        core?.state.devices.filter { $0.paired && $0.online && $0.accepts(PacketType.mpris) }.map(\.id) ?? []
    }

    private func send(_ p: Packet, to ids: [String]) {
        for id in ids { core?.send(p, to: id) }
    }

    // MARK: Album art

    /// Sends the art of the current track as a payload. Runs on players.queue.
    private func sendArt(_ player: MacPlayer, url: String, to deviceId: String, certificate: [UInt8]?) {
        guard let certificate, players.state(player)?.artUrl == url else { return }
        switch player.art {
        case .artwork:
            guard let data = players.artwork(player) else { return }
            transfer(data, player: player.name, url: url, to: deviceId, certificate: certificate)
        case .url:
            guard let remote = URL(string: url), remote.scheme == "https" else { return }
            Task { [self] in
                do {
                    let (data, _) = try await URLSession.shared.data(from: remote)
                    transfer(data, player: player.name, url: url, to: deviceId, certificate: certificate)
                } catch {
                    FluxLog.plugin.error("album art of \(player.name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Offers the data on a payload port. The computer connects and reads it.
    private func transfer(_ data: Data, player: String, url: String, to deviceId: String, certificate: [UInt8]) {
        guard let core, !data.isEmpty, data.count <= Self.maxArt else { return }
        Task {
            do {
                let server = try await PayloadServer.open(tls: core.tls, expected: certificate)
                let p = Packet(PacketType.mpris, ["player": player, "albumArtUrl": url, "transferringAlbumArt": true],
                               payloadSize: Int64(data.count), payloadPort: server.port)
                guard core.send(p, to: deviceId) else {
                    server.close()
                    return
                }
                let stream = try await server.accept(timeout: .seconds(20))
                try await stream.executeThenClose { _, outbound in
                    try await outbound.write(ByteBuffer(bytes: data))
                    outbound.finish()
                }
                FluxLog.plugin.info("sent album art of \(player, privacy: .public), \(data.count) bytes")
            } catch {
                FluxLog.plugin.error("album art of \(player, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}
