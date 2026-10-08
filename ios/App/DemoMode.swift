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

    /// The sample agents of the laptop: codex in billing waits for a
    /// choice, claude in api works, and claude in web is done. They match
    /// the sample agents of the Android app.
    static let herdr = HerdrState(enabled: true, running: true, agents: [
        HerdrAgent(pane: "w2:p1", agent: "codex", status: .blocked, title: "Run the database migration", project: "billing", workspace: "billing"),
        HerdrAgent(pane: "w1:p1", agent: "claude", status: .working, title: "Add rate limiting to /v1/upload", project: "api", workspace: "api"),
        HerdrAgent(pane: "w3:p1", agent: "claude", status: .done, title: "Fix the flaky login test", project: "web", workspace: "web"),
    ], control: true, review: true)

    /// The sample output of a demo agent in `pane`, or with `review` its
    /// sample diff in the format of fluxd.
    static func output(pane: String, review: Bool) -> HerdrOutput? {
        if review {
            return HerdrOutput(pane: pane, loading: false, lines: TermText.lines(diffs[pane] ?? "No changes in this repository."), view: "diff")
        }
        return samples[pane].map { HerdrOutput(pane: pane, loading: false, lines: TermText.lines($0)) }
    }

    private static let input = "╭────────────────────────────╮\n│ >                          │\n╰────────────────────────────╯\n  ? for shortcuts\n"

    private static let samples: [String: String] = [
        "w2:p1": [
            "● I added the migration in db/migrate/0042_add_invoice_status.sql.\n\n",
            "● Write(db/migrate/0042_add_invoice_status.sql)\n  ⎿  Wrote 18 lines to db/migrate/0042_add_invoice_status.sql\n\n",
            "● Update(app/models/invoice.rb)\n  ⎿  Updated app/models/invoice.rb with 24 additions and 7 removals\n\n",
            "● Bash(bin/migrate --dry-run)\n  ⎿  1 migration to apply: 0042_add_invoice_status\n\n",
            String(repeating: "─", count: 72) + "\n Bash command\n\n   bin/migrate --apply\n   Apply the pending migration\n\n",
            " Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, and do not ask again for bin/migrate commands\n",
            "   3. No, and tell Codex what to do differently (esc)\n",
        ].joined(),
        "w1:p1": [
            "● I'll put a token bucket in front of the upload handler, keyed by API key.\n\n",
            "● Write(src/middleware/rate_limit.ts)\n  ⎿  Wrote 61 lines to src/middleware/rate_limit.ts\n\n",
            "● Update(src/routes/upload.ts)\n  ⎿  Updated src/routes/upload.ts with 3 additions and 1 removal\n\n",
            "● Bash(npm test -- upload)\n  ⎿  Running 48 tests… 31 passed\n\n",
            "✻ Running tests… (2:14 · esc to interrupt)\n\n" + input,
        ].joined(),
        "w3:p1": [
            "● The login test waited on a fixed 2 s timeout. It now waits for the session cookie.\n\n",
            "● Update(tests/login.spec.ts)\n  ⎿  Updated tests/login.spec.ts with 4 additions and 2 removals\n\n",
            "● Bash(npm test -- login --repeat 20)\n  ⎿  20 passed\n\n",
            "● Done. The test passed 20 times in a row.\n\n✻ Worked for 6m 12s\n\n" + input,
        ].joined(),
    ]

    private static let diffs: [String: String] = [
        "w2:p1": [
            "Changed files\n M app/models/invoice.rb\n?? db/migrate/0042_add_invoice_status.sql\n\nWorking tree changes\n",
            "diff --git a/app/models/invoice.rb b/app/models/invoice.rb\nindex 3f2a1c0..9b8d7e1 100644\n--- a/app/models/invoice.rb\n+++ b/app/models/invoice.rb\n",
            "@@ -12,9 +12,26 @@ class Invoice\n   belongs_to :account\n-  def paid?\n-    paid_at.present?\n-  end\n",
            "+  STATUSES = %w[draft open paid void]\n+  validates :status, inclusion: STATUSES\n+  def paid? = status == \"paid\"\n",
            "\ndiff --git a/db/migrate/0042_add_invoice_status.sql b/db/migrate/0042_add_invoice_status.sql\nnew file\n",
            "+ALTER TABLE invoices\n+  ADD COLUMN status text NOT NULL\n+  DEFAULT 'draft';\n+CREATE INDEX invoices_status_idx\n+  ON invoices (status);\n+\n",
        ].joined(),
        "w1:p1": [
            "Changed files\n M src/routes/upload.ts\n?? src/middleware/rate_limit.ts\n\nWorking tree changes\n",
            "diff --git a/src/routes/upload.ts b/src/routes/upload.ts\nindex 1a2b3c4..5d6e7f8 100644\n--- a/src/routes/upload.ts\n+++ b/src/routes/upload.ts\n",
            "@@ -4,7 +4,9 @@\n-router.post(\"/v1/upload\", upload)\n+router.post(\"/v1/upload\",\n+  rateLimit({ perMinute: 30 }), upload)\n",
            "\ndiff --git a/src/middleware/rate_limit.ts b/src/middleware/rate_limit.ts\nnew file\n",
            "+export function rateLimit(opts: Limits) {\n+  const buckets = new Map<string, Bucket>()\n+  return (req, res, next) => {\n+\n",
        ].joined(),
        "w3:p1": [
            "Changed files\n M tests/login.spec.ts\n\nWorking tree changes\n",
            "diff --git a/tests/login.spec.ts b/tests/login.spec.ts\nindex 2b3c4d5..6e7f8a9 100644\n--- a/tests/login.spec.ts\n+++ b/tests/login.spec.ts\n",
            "@@ -21,8 +21,10 @@\n-  await page.waitForTimeout(2000)\n+  await expect.poll(() =>\n+    context.cookies()).toContainEqual(\n",
            "+      expect.objectContaining({ name: 'session' }))\n",
        ].joined(),
    ]

    /// The sample transfer keeps 1 ID, so that its Inbox key stays the same.
    private static let transferId = UUID(uuidString: "6F1D5E0A-0D7C-4C1B-9E55-0000000000A1") ?? UUID()

    /// The sample Inbox: an agent that waits, an approval, a player, a
    /// clip, a received file, an agent that is done, and an agent that works. They go through
    /// `Inbox.items`, so that the order is the real order.
    static func inboxItems(now: Date) -> [InboxItem] {
        let laptop = computers[0].id
        let herdr = [laptop: Self.herdr]
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
        PacketType.fluxStreamRequest,
    ]

    private static func computer(id: String, name: String, type: String, ip: String, online: Bool) -> DeviceSnapshot {
        DeviceSnapshot(id: id, name: name, type: type, ip: ip, isFlux: true, paired: true, online: online,
                       pairState: .paired, pairKey: "", incoming: incoming, outgoing: outgoing)
    }
}
