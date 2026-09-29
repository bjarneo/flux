import Foundation
import FluxProto
import FluxApprove

/// Why the router dropped a packet.
public enum IgnoredReason: Sendable, Equatable {
    /// Plugin packets from an unpaired device (Go `handlePacket` drops them).
    case unpaired
    /// A type outside the advertised `incomingCapabilities`.
    case unadvertised
    /// A known type with no M2 handler yet (identity refresh, M3+ payloads).
    case unhandled
    /// Clipboard sync is off (`auto_clipboard` defaults false on iOS).
    case syncDisabled
}

/// One routed packet: a UI/log event, or packets to send back
/// (today only the `battery.request` answer; M3 adds payload traffic).
public enum FeatureAction: Sendable, Equatable {
    case event(FeatureEvent)
    case send(Packet)
}

/// A decoded M2 packet for the UI/log layer. System bridges
/// (`FluxFeatures`) act on these: `UIPasteboard` writes, `UNNotification`
/// renders, file queueing (payload fetch itself lands in M3).
public enum FeatureEvent: Sendable, Equatable {
    case ping(message: String)
    case battery(BatteryState)
    /// The peer asked for our battery; the link answers via its provider.
    case batteryRequested
    /// Remote clipboard to apply (foreground `UIPasteboard` on device).
    case clipboard(String)
    /// A `clipboard.connect` older than the last local change: stored,
    /// never applied (Go + Android stale rule).
    case clipboardStale(String)
    case shareText(String, scan: Bool)
    case shareURL(String)
    /// A file announcement; bytes are fetched in M3.
    case shareFile(ShareFile)
    case shareUpdate(numberOfFiles: Int, totalPayloadSize: Int64)
    /// Find-my-phone toggled. The link schedules the 2-minute stop.
    case ringToggled(ringing: Bool, from: String)
    /// A desktop notification to render.
    case notification(ComputerNotification)
    /// A desktop cancel for a rendered notification.
    case notificationCancelled(key: String)
    /// `{"request": true}`: full-list request. Nothing to send back —
    /// there is no global mirror on iOS.
    case notificationSyncRequested
    /// A cancel/reply/action for a phone-originated notification. With no
    /// mirror there is nothing to dismiss or answer; logged and dropped.
    case notificationCancel(id: String)
    case notificationReplyDropped(replyId: String, message: String)
    case notificationActionDropped(key: String, action: String)
    /// A `flux.tunnel` answer. iOS never solicits tunnels (phone→desktop
    /// sends are classic; see `Transfers.swift` for the rule), so arrivals
    /// are logged by the link, never waited on.
    case tunnelReady(token: String, port: Int)
    case tunnelFailed(token: String, error: String)
    /// A desktop SFTP offer answering our `sftp.request`. The link opens
    /// the tunnel listener (or logs the refusal); the SSH session inside
    /// is M4+ (see `Transfers.swift`).
    case sftpOffer(SftpOffer)
    case sftpError(message: String)
    /// A desktop asking to browse this phone's files. Serving is deferred
    /// (plan §4.7): the link answers nothing and logs it.
    case sftpServeRequested
    /// The desktop player list changed (`kdeconnect.mpris` `playerList`).
    case mediaPlayersChanged(players: [String])
    /// One desktop player's now-playing state.
    case mediaState(MprisState)
    /// The desktop asked for our player list (`flux media` follow-ups and
    /// desktop queries). The link answers via its now-playing provider.
    case mediaPlayersRequested
    /// The desktop asked for one player's state.
    case mediaStateRequested(player: String)
    /// The desktop controls this phone's playback (`flux media *`). The
    /// app drives `NowPlayingBridge` from these; the harness logs them.
    case mediaActionRequested(player: String, action: String)
    case mediaSeekRequested(player: String, positionMs: Int64)
    case mediaVolumeRequested(player: String, volume: Int)
    /// The desktop wants album art for a URL. Answered with nothing: the
    /// phone publishes no state in v1, so this only ever logs.
    case mediaAlbumArtRequested(player: String, url: String)
    /// The desktop command list (`kdeconnect.runcommand`). Order is the
    /// desktop config order.
    case commandList(commands: [RemoteCommand], canAddCommand: Bool)
    /// Desktop Do Not Disturb changed. The phone renders a banner and
    /// never applies it (iOS cannot set Focus programmatically).
    case dndChanged(on: Bool)
    // MARK: - Streams (M5)
    /// The desktop reports the webcam live: frames reach `device` as `label`.
    case webcamLive(device: String, label: String)
    /// The desktop could not start the webcam.
    case webcamError(message: String)
    /// The user stopped the camera on the computer.
    case webcamStopped
    /// The computer changes webcam settings. `reset` restores the neutral
    /// image values first; `config` then sets the fields it names (the app
    /// merges it into `WebcamConfig` and restarts on frame-size changes).
    case webcamConfig(reset: Bool, config: [String: JSONValue]?)
    /// The desktop reports the mic live as `source`.
    case micLive(source: String)
    /// The desktop could not start the mic.
    case micError(message: String)
    /// The user stopped the microphone on the computer.
    case micStopped
    /// The desktop shows the mirror in `player`.
    case screenLive(player: String)
    /// The desktop could not show the mirror.
    case screenError(message: String)
    /// The user closed the mirror window or stopped it on the computer.
    case screenStopped
    // MARK: - Approval (M6)
    /// The desktop asks to approve a login or to enroll this phone. The
    /// router runs the one-at-a-time store first: held requests surface
    /// here for the prompt; refusals go straight back on the wire (`.send`).
    case approveRequested(ApproveRequest)
    /// The desktop cancelled the open request. The link clears it.
    case approveCancelled(id: String)
    case ignored(type: String, reason: IgnoredReason)
}

/// What the router needs per link. Mirrors the gates in Go `handlePacket`
/// (pairing) and `fluxd` capability intersection (advertisement).
public struct FeatureContext: Sendable {
    public var peerId: String
    public var peerName: String
    public var paired: Bool
    public var incoming: [String]
    /// Clipboard sync setting (`auto_clipboard`, false on iOS by default).
    public var clipboardSync: Bool
    /// Last local clipboard change (ms), for the connect stale rule.
    public var lastLocalClipMs: Int64
    public var nowMs: Int64
    /// Whether this phone holds an approval key for the peer (M6). The
    /// link fills it per `flux.approve` packet; approvals without a key
    /// get the enroll-again failure (Android `Approvals` parity).
    public var hasApproveKey: Bool

    public init(
        peerId: String, peerName: String, paired: Bool,
        incoming: [String] = incomingCapabilities,
        clipboardSync: Bool = false, lastLocalClipMs: Int64 = 0,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        hasApproveKey: Bool = false
    ) {
        self.peerId = peerId
        self.peerName = peerName
        self.paired = paired
        self.incoming = incoming
        self.clipboardSync = clipboardSync
        self.lastLocalClipMs = lastLocalClipMs
        self.nowMs = nowMs
        self.hasApproveKey = hasApproveKey
    }
}

/// M2 + M4 + M5 + M6 packet router: ping, battery, clipboard, share, notifications
/// (best-effort), find-my-phone, desktop media state, desktop media control
/// (`flux media *`), runcommand lists, `flux.dnd`, desktop stream
/// answers (`flux.webcam`/`flux.mic`/`flux.screen` live/error/stop/config),
/// and approval/enrollment requests (`flux.approve`). Mirrors Android
/// `core/Plugins.kt` `handle` + Go `internal/core/handlers.go`.
///
/// `pair` packets never reach the router (the link owns pairing).
/// The router holds the loop-prevention + ring state that must survive
/// across packets on one link (`lastRemoteClip`, `ring`).
public struct FeatureRouter: Sendable {
    /// Last text a peer put on the clipboard. The link does not send it
    /// back (Android `Plugins.lastRemoteClip`).
    public var lastRemoteClip: String?
    public var ring = RingState()
    /// Desktop players + the controlled one (Android `Device.players`,
    /// `currentPlayer`). `playingByPlayer` feeds the switch-to-playing
    /// rule in `receiveMpris`.
    public var mediaPlayers: [String] = []
    public var mediaCurrent: String?
    private var playingByPlayer: [String: Bool] = [:]
    /// The open approval/enrollment request (Android `Approvals._current`).
    /// One request at a time; the link clears it on answer/cancel/timeout.
    public var approvals = ApprovalsStore()

    public init() {}

    public mutating func route(_ p: Packet, ctx: FeatureContext) -> [FeatureAction] {
        guard ctx.paired else {
            return [.event(.ignored(type: p.type, reason: .unpaired))]
        }
        guard ctx.incoming.contains(p.type) else {
            return [.event(.ignored(type: p.type, reason: .unadvertised))]
        }
        switch p.type {
        case PacketType.ping:
            guard let m = PingMessage.message(p) else { return [.event(.ignored(type: p.type, reason: .unhandled))] }
            return [.event(.ping(message: m))]
        case PacketType.battery:
            guard let b = BatteryState.parse(p) else { return [.event(.ignored(type: p.type, reason: .unhandled))] }
            return [.event(.battery(b))]
        case PacketType.batteryRequest:
            return [.event(.batteryRequested)]
        case PacketType.clipboard, PacketType.clipboardConnect:
            return routeClipboard(p, ctx: ctx)
        case PacketType.share:
            return routeShare(p)
        case PacketType.shareUpdate:
            guard let u = ShareMessage.parseUpdate(p) else { return [.event(.ignored(type: p.type, reason: .unhandled))] }
            return [.event(.shareUpdate(numberOfFiles: u.numberOfFiles, totalPayloadSize: u.totalPayloadSize))]
        case PacketType.findMyPhone:
            guard FindMyPhone.isRingRequest(p) else { return [.event(.ignored(type: p.type, reason: .unhandled))] }
            let ringing = ring.toggle(from: ctx.peerName, nowMs: ctx.nowMs)
            return [.event(.ringToggled(ringing: ringing, from: ctx.peerName))]
        case PacketType.notification:
            guard let n = ComputerNotification.from(p, deviceId: ctx.peerId, computer: ctx.peerName, nowMs: ctx.nowMs) else {
                return [.event(.ignored(type: p.type, reason: .unhandled))]
            }
            if n.cancel { return [.event(.notificationCancelled(key: n.key))] }
            return [.event(.notification(n))]
        case PacketType.notificationRequest:
            return routeNotificationRequest(p)
        case PacketType.notificationReply:
            guard let id = p.string("requestReplyId") else { return [.event(.ignored(type: p.type, reason: .unhandled))] }
            return [.event(.notificationReplyDropped(replyId: id, message: p.string("message") ?? ""))]
        case PacketType.notificationAction:
            guard let key = p.string("key"), let action = p.string("action") else {
                return [.event(.ignored(type: p.type, reason: .unhandled))]
            }
            return [.event(.notificationActionDropped(key: key, action: action))]
        case PacketType.fluxTunnel:
            guard let t = TunnelPackets.parse(p) else {
                return [.event(.ignored(type: p.type, reason: .unhandled))]
            }
            if let error = t.error, !error.isEmpty {
                return [.event(.tunnelFailed(token: t.token, error: error))]
            }
            return [.event(.tunnelReady(token: t.token, port: t.port))]
        case PacketType.sftp:
            if let message = SftpOffer.errorMessage(p), !message.isEmpty {
                return [.event(.sftpError(message: message))]
            }
            guard let offer = SftpOffer.parse(p) else {
                return [.event(.ignored(type: p.type, reason: .unhandled))]
            }
            return [.event(.sftpOffer(offer))]
        case PacketType.sftpRequest:
            return [.event(.sftpServeRequested)]
        case PacketType.mpris:
            return routeMpris(p)
        case PacketType.mprisRequest:
            return routeMprisRequest(p)
        case PacketType.runCommand:
            guard let list = RunCommandMessage.parseList(p) else {
                return [.event(.ignored(type: p.type, reason: .unhandled))]
            }
            return [.event(.commandList(commands: list.commands, canAddCommand: list.canAddCommand))]
        case PacketType.fluxDnd:
            guard let on = DndMessage.parse(p) else {
                return [.event(.ignored(type: p.type, reason: .unhandled))]
            }
            return [.event(.dndChanged(on: on))]
        case PacketType.fluxWebcam:
            return routeWebcam(p)
        case PacketType.fluxMic:
            return routeMic(p)
        case PacketType.fluxScreen:
            return routeScreen(p)
        case PacketType.fluxApprove:
            return routeApprove(p, ctx: ctx)
        default:
            return [.event(.ignored(type: p.type, reason: .unhandled))]
        }
    }

    /// Ends an expired ring. Returns the event when a ring just stopped.
    public mutating func expireRing(nowMs: Int64) -> FeatureEvent? {
        guard let from = ring.expire(nowMs: nowMs) else { return nil }
        return .ringToggled(ringing: false, from: from)
    }

    // MARK: - Clipboard

    private mutating func routeClipboard(_ p: Packet, ctx: FeatureContext) -> [FeatureAction] {
        guard let clip = ClipboardMessage.parse(p) else {
            return [.event(.ignored(type: p.type, reason: .unhandled))]
        }
        guard ctx.clipboardSync else {
            return [.event(.ignored(type: p.type, reason: .syncDisabled))]
        }
        if clip.isStale(againstLocalMs: ctx.lastLocalClipMs) {
            return [.event(.clipboardStale(clip.content))]
        }
        lastRemoteClip = clip.content
        return [.event(.clipboard(clip.content))]
    }

    // MARK: - Share

    private func routeShare(_ p: Packet) -> [FeatureAction] {
        switch ShareMessage.parse(p) {
        case .text(let text, let scan):
            return [.event(.shareText(text, scan: scan))]
        case .url(let url):
            return [.event(.shareURL(url))]
        case .file(let file):
            return [.event(.shareFile(file))]
        case .some(.none), nil:
            return [.event(.ignored(type: p.type, reason: .unhandled))]
        }
    }

    // MARK: - Notification requests

    private func routeNotificationRequest(_ p: Packet) -> [FeatureAction] {
        switch NotificationPackets.parseRequest(p) {
        case .requestAll:
            return [.event(.notificationSyncRequested)]
        case .cancel(let id):
            return [.event(.notificationCancel(id: id))]
        case .unknown, nil:
            return [.event(.ignored(type: p.type, reason: .unhandled))]
        }
    }

    // MARK: - Media (M4)

    /// Routes desktop player state. Mirrors Android `receiveMpris`: a new
    /// list re-seats the controlled player and asks for its state; a state
    /// update switches control to a player that started playing.
    private mutating func routeMpris(_ p: Packet) -> [FeatureAction] {
        guard let update = MprisMessage.parse(p) else {
            return [.event(.ignored(type: p.type, reason: .unhandled))]
        }
        var actions: [FeatureAction] = []
        if let players = update.players {
            mediaPlayers = players
            if let cur = mediaCurrent, players.contains(cur) {
                // Keep controlling the same player.
            } else {
                mediaCurrent = players.first
            }
            actions.append(.event(.mediaPlayersChanged(players: players)))
            if let cur = mediaCurrent {
                actions.append(.send(MprisMessage.requestNowPlaying(player: cur)))
            }
        }
        if let state = update.state {
            playingByPlayer[state.player] = state.playing
            if mediaCurrent == nil {
                mediaCurrent = state.player
            } else if let cur = mediaCurrent, cur != state.player,
                      playingByPlayer[cur] != true, state.playing {
                mediaCurrent = state.player
            }
            actions.append(.event(.mediaState(state)))
        }
        return actions
    }

    /// Routes desktop control of this phone's playback (`flux media *`) and
    /// desktop state queries.
    private func routeMprisRequest(_ p: Packet) -> [FeatureAction] {
        guard let req = MprisRequest.parse(p) else {
            return [.event(.ignored(type: p.type, reason: .unhandled))]
        }
        switch req {
        case .playerList:
            return [.event(.mediaPlayersRequested)]
        case .nowPlaying(let player):
            return [.event(.mediaStateRequested(player: player))]
        case .action(let player, let action):
            return [.event(.mediaActionRequested(player: player, action: action))]
        case .seek(let player, let positionMs):
            return [.event(.mediaSeekRequested(player: player, positionMs: positionMs))]
        case .setVolume(let player, let volume):
            return [.event(.mediaVolumeRequested(player: player, volume: volume))]
        case .albumArt(let player, let url):
            return [.event(.mediaAlbumArtRequested(player: player, url: url))]
        }
    }

    // MARK: - Streams (M5)

    /// Routes desktop answers to `flux.webcam` (live/error/stop/config).
    /// A `start` arriving phone-side is meaningless and stays unhandled
    /// (Go `handleWebcam` likewise only acts on known states).
    private func routeWebcam(_ p: Packet) -> [FeatureAction] {
        guard let reply = WebcamReply.parse(p) else {
            return [.event(.ignored(type: p.type, reason: .unhandled))]
        }
        switch reply {
        case .live(let device, let label):
            return [.event(.webcamLive(device: device, label: label))]
        case .failed(let message):
            return [.event(.webcamError(message: message))]
        case .stop:
            return [.event(.webcamStopped)]
        case .config(let partial, let reset):
            return [.event(.webcamConfig(reset: reset, config: partial))]
        }
    }

    /// Routes desktop answers to `flux.mic` (live/error/stop).
    private func routeMic(_ p: Packet) -> [FeatureAction] {
        guard let reply = MicReply.parse(p) else {
            return [.event(.ignored(type: p.type, reason: .unhandled))]
        }
        switch reply {
        case .live(let source):
            return [.event(.micLive(source: source))]
        case .failed(let message):
            return [.event(.micError(message: message))]
        case .stop:
            return [.event(.micStopped)]
        }
    }

    /// Routes desktop answers to `flux.screen` (live/error/stop).
    private func routeScreen(_ p: Packet) -> [FeatureAction] {
        guard let reply = ScreenReply.parse(p) else {
            return [.event(.ignored(type: p.type, reason: .unhandled))]
        }
        switch reply {
        case .live(let player):
            return [.event(.screenLive(player: player))]
        case .failed(let message):
            return [.event(.screenError(message: message))]
        case .stop:
            return [.event(.screenStopped)]
        }
    }

    // MARK: - Approval (M6)

    /// Routes desktop approval/enrollment/cancel packets through the
    /// one-at-a-time store (Android `Approvals.onPacket` + `receive`).
    /// Held requests surface as events for the prompt; refusals go back on
    /// the wire at once; id-less packets stay unhandled (nothing to answer).
    private mutating func routeApprove(_ p: Packet, ctx: FeatureContext) -> [FeatureAction] {
        if let id = ApproveMessage.cancelId(p) {
            return [.event(.approveCancelled(id: id))]
        }
        // Freshness compares the signed time against the phone clock at
        // receipt; expiry compares the same live clock against the deadline.
        // A frozen capture of ctx.nowMs would freeze both (expiry could
        // never fire), so the store always reads the live clock here.
        approvals.nowSeconds = { Int64(Date().timeIntervalSince1970) }
        approvals.hasKey = { [hasKey = ctx.hasApproveKey] _ in hasKey }
        guard let intake = approvals.receive(p, computerId: ctx.peerId, computerName: ctx.peerName) else {
            return [.event(.ignored(type: p.type, reason: .unhandled))]
        }
        switch intake {
        case .hold(let r):
            return [.event(.approveRequested(r))]
        case .reply(let pkt):
            return [.send(pkt)]
        }
    }

    /// Clears the open approval request with `id` (desktop cancel, local
    /// answer, or timeout). True when something closed.
    public mutating func approveClear(id: String) -> Bool {
        approvals.cancel(id: id)
    }

    /// Closes the open approval request when its timeout passed. Returns it
    /// so the link can emit the expiry (no packet goes back: `fluxd`
    /// already cancelled on its own timeout).
    public mutating func approveExpire() -> ApproveRequest? {
        approvals.expire()
    }
}
