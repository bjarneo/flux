import FluxKit
import Foundation

/// Sample computers for App Review and screenshots. With the launch argument
/// `-FLUX_DEMO 1`, the app shows them in place of the real computers and
/// starts no discovery, listener, or link, see `AppModel`. The core does not
/// know the sample computers, so the actions on their screens reach no
/// computer. The Inbox shows sample items. With `-FLUX_THEME neon`, the
/// laptop has the sample theme of that name, see `SampleThemes`.
enum DemoMode {
    /// The defaults key that the launch argument sets.
    static let key = "FLUX_DEMO"

    /// True when the app started with `-FLUX_DEMO 1`.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// The defaults key of the sample theme of the laptop.
    static let themeKey = "FLUX_THEME"

    /// The name of the sample theme of the laptop, such as "neon", or nil
    /// for no theme. The tests set it.
    @MainActor static var themeName: String? = UserDefaults.standard.string(forKey: themeKey)

    /// The theme of the last name. The palette takes about 30 runs of the
    /// contrast guard, so the demo makes it once for each name.
    @MainActor private static var themeCache: (name: String, theme: ComputerTheme)?

    /// The text of an action that would reach a computer.
    static let sendsNothing = "The demo sends nothing to a computer."

    /// The theme of the laptop when the scope is all computers or the laptop.
    @MainActor
    static func theme(scope: String?) -> ComputerTheme? {
        let laptop = computers[0].id
        guard scope == nil || scope == laptop, let name = themeName, let theme = SampleThemes.named(name) else { return nil }
        if let cache = themeCache, cache.name == name { return cache.theme }
        let made = ComputerTheme(deviceId: laptop, theme: theme, palette: ThemePalette.of(theme))
        themeCache = (name: name, theme: made)
        return made
    }

    /// The question of the sample agent: the test vector of
    /// `Inbox.agentPrompt` with 3 choices.
    static let output = HerdrOutput(pane: "w2:p1", loading: false, lines: TermText.parse(promptLines.joined(separator: "\n")))

    private static let promptLines = [
        "● I added the migration.",
        String(repeating: "─", count: 40),
        " Bash command",
        "",
        "   bin/migrate --apply",
        "   Apply the pending migration",
        "",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and do not ask again",
        "   3. No",
    ]

    /// The sample transfer keeps 1 ID, so that its Inbox key stays the same.
    private static let transferId = UUID(uuidString: "6F1D5E0A-0D7C-4C1B-9E55-0000000000A1") ?? UUID()

    /// The sample Inbox: an agent that waits, an approval, a player, a
    /// clip, a received file, and an agent that is done. They go through
    /// `Inbox.items`, so that the order is the real order.
    static func inboxItems(now: Date) -> [InboxItem] {
        let laptop = computers[0].id
        let agents = [
            HerdrAgent(pane: "w2:p1", agent: "codex", status: .blocked, title: "Migrate the billing table", project: "billing"),
            HerdrAgent(pane: "w1:p1", agent: "claude", status: .done, title: "Add the export tests", project: "reports"),
        ]
        let herdr = [laptop: HerdrState(enabled: true, running: true, agents: agents, control: true)]
        var player = RemotePlayer(name: "spotify")
        player.title = "Focus mix"
        player.artist = "Lo-fi radio"
        player.playing = true
        var media = RemoteMedia()
        media.players = [player.name]
        media.current = player.name
        media.states = [player.name: player]
        let approval = ApproveMessage.parse(
            Packet(PacketType.fluxApprove, [
                "kind": "request", "id": "demo1", "host": "omarchy", "user": "alice", "service": "sudo", "tty": "pts/1",
                "time": Int64(now.timeIntervalSince1970), "nonce": String(repeating: "0", count: 64),
            ]),
            computerId: laptop, computerName: "omarchy")
        let clip = ClipEvent(deviceIds: [laptop], computer: "omarchy", sent: true, preview: "git push origin main", at: now)
        let transfer = FileTransfer(id: transferId, deviceId: laptop, name: "invoice-2026-09.pdf", incoming: true,
                                    size: 182_000, bytes: 182_000, state: .done, started: now, ended: now)
        return Inbox.items(devices: computers, herdr: herdr, media: [laptop: media], approval: approval,
                           transfers: [transfer], clip: clip, now: now, playedAt: [:])
    }

    /// The state of the core with the sample computers in place of the real
    /// ones. Flux shows as on, not searching, and with no link port.
    static func state(_ core: CoreState) -> CoreState {
        var state = core
        state.devices = computers
        state.enabled = true
        state.searching = false
        state.tcpPort = 0
        return state
    }

    /// A connected laptop with the features of fluxd, and a desktop that is
    /// not reachable.
    static let computers: [DeviceSnapshot] = [
        computer(id: "demo_laptop_00000000000000000001", name: "omarchy", type: "laptop", ip: "192.168.1.20", online: true),
        computer(id: "demo_desktop_0000000000000000002", name: "workstation", type: "desktop", ip: "192.168.1.31", online: false),
    ]

    /// The packet types that fluxd accepts, from `Incoming` in
    /// internal/proto/identity.go, without the ones that only Android uses.
    static let incoming = [
        PacketType.ping, PacketType.battery, PacketType.clipboard, PacketType.clipboardConnect,
        PacketType.share, PacketType.shareUpdate, PacketType.notification, PacketType.runCommandRequest,
        PacketType.mprisRequest, PacketType.sftpRequest,
        PacketType.fluxTunnel, PacketType.fluxWebcam, PacketType.fluxDnd, PacketType.fluxMic, PacketType.fluxScreen,
        PacketType.fluxApprove, PacketType.fluxHerdr, PacketType.fluxClipboardImage, PacketType.mousepadRequest,
        PacketType.fluxDesktop, PacketType.fluxShortcuts,
    ]

    /// The packet types that fluxd sends, from `Outgoing` in
    /// internal/proto/identity.go, without the ones that only Android uses.
    static let outgoing = [
        PacketType.ping, PacketType.battery, PacketType.clipboard, PacketType.clipboardConnect, PacketType.share,
        PacketType.notification, PacketType.notificationRequest, PacketType.notificationReply, PacketType.notificationAction,
        PacketType.findMyPhone, PacketType.runCommand, PacketType.mpris,
        PacketType.sftp, PacketType.fluxWebcam, PacketType.fluxDnd,
        PacketType.fluxMic, PacketType.fluxScreen, PacketType.fluxApprove, PacketType.fluxHerdr,
        PacketType.fluxClipboardImage, PacketType.fluxInput, PacketType.fluxDesktop, PacketType.fluxShortcuts,
        PacketType.fluxTheme,
    ]

    private static func computer(id: String, name: String, type: String, ip: String, online: Bool) -> DeviceSnapshot {
        DeviceSnapshot(id: id, name: name, type: type, ip: ip, isFlux: true, paired: true, online: online,
                       pairState: .paired, pairKey: "", incoming: incoming, outgoing: outgoing)
    }
}
