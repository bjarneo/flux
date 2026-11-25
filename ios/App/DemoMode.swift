import FluxKit
import Foundation

/// Sample computers for App Review and screenshots. With the launch argument
/// `-FLUX_DEMO 1`, the app shows them in place of the real computers and
/// starts no discovery, listener, or link, see `AppModel`. The core does not
/// know the sample computers, so the actions on their screens reach no
/// computer. Chats lists the sample agents, the sample approval, and the 2
/// computers, and the chat of the laptop shows sample entries. With
/// `-FLUX_THEME neon`, the laptop has the sample theme of that name, see
/// `SampleThemes`.
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
    /// choice, claude in api works, claude in web is done, and pi in web is
    /// idle. They match the sample agents of the Android app.
    static let herdr = HerdrState(enabled: true, running: true, agents: [
        HerdrAgent(pane: "w2:p1", agent: "codex", status: .blocked, title: "Run the database migration", project: "billing", workspace: "billing"),
        HerdrAgent(pane: "w1:p1", agent: "claude", status: .working, title: "Add rate limiting to /v1/upload", project: "api", workspace: "api"),
        HerdrAgent(pane: "w3:p1", agent: "claude", status: .done, title: "Fix the flaky login test", project: "web", workspace: "web"),
        HerdrAgent(pane: "w3:p2", agent: "pi", status: .idle, project: "web", workspace: "web"),
    ], control: true, review: true)

    /// The sample agents by device ID: only the laptop has agents.
    static var herdrStates: [String: HerdrState] { [computers[0].id: herdr] }

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
        // The idle agent did not start a task yet.
        "w3:p2": input,
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

    /// The time that the sample agents got their status, in the order of the
    /// chat design: the agent in web is done for 17 minutes, the agent in
    /// api works for 8 minutes, and the agent in billing waits for 4 minutes.
    static func since(pane: String, now: Date = Date()) -> Date? {
        switch pane {
        case "w3:p1": return now.addingTimeInterval(-17 * 60)
        case "w1:p1": return now.addingTimeInterval(-8 * 60)
        case "w2:p1": return now.addingTimeInterval(-4 * 60)
        default: return nil
        }
    }

    /// The sample IDs, so that each entry of the chat keeps its place.
    private static let linkId = UUID(uuidString: "6F1D5E0A-0D7C-4C1B-9E55-0000000000B1") ?? UUID()
    private static let photoId = UUID(uuidString: "6F1D5E0A-0D7C-4C1B-9E55-0000000000B2") ?? UUID()
    private static let fileId = UUID(uuidString: "6F1D5E0A-0D7C-4C1B-9E55-0000000000B3") ?? UUID()
    private static let textId = UUID(uuidString: "6F1D5E0A-0D7C-4C1B-9E55-0000000000B4") ?? UUID()

    /// The sample link that this iPhone sent 49 minutes ago, and the sample
    /// text that it sent 1 minute ago.
    static var sent: [SentItem] {
        let now = Date()
        return [
            SentItem(id: linkId, deviceId: computers[0].id, kind: .link, text: "https://omarchy.org/manual",
                     at: now.addingTimeInterval(-49 * 60)),
            SentItem(id: textId, deviceId: computers[0].id, kind: .text, text: "Dinner at 7, bring the kids",
                     at: now.addingTimeInterval(-60)),
        ]
    }

    /// The time that the sample desktop went offline: the last 09:12, today
    /// or yesterday. The laptop is online, so it has none.
    static func lastSeen(_ id: String, now: Date = Date()) -> Date? {
        guard id == computers[1].id, let today = Calendar.current.date(bySettingHour: 9, minute: 12, second: 0, of: now) else { return nil }
        return today > now ? Calendar.current.date(byAdding: .day, value: -1, to: today) : today
    }

    /// The sample files of the chat: a photo that went out 28 minutes ago,
    /// and a file that comes in since 6 minutes.
    static var sendTransfers: [FileTransfer] {
        let laptop = computers[0].id
        let now = Date()
        let sentAt = now.addingTimeInterval(-28 * 60)
        return [
            FileTransfer(id: fileId, deviceId: laptop, name: "invoice-2026-09.pdf", incoming: true, size: 3_200_000, bytes: 1_856_000,
                         started: now.addingTimeInterval(-6 * 60)),
            FileTransfer(id: photoId, deviceId: laptop, name: "holiday.jpg", incoming: false, size: 2_400_000, bytes: 2_400_000,
                         state: .done, started: sentAt, ended: sentAt),
        ]
    }

    /// The sample clip from the laptop, 11 minutes ago.
    static var clip: ClipEvent {
        ClipEvent.received(from: computers[0].id, computer: computers[0].name, text: "git push origin ui-shell",
                           at: Date().addingTimeInterval(-11 * 60))
    }

    /// The sample sudo request of the laptop, asked at `now`.
    static func approval(now: Date = Date()) -> ApproveRequest? {
        ApproveMessage.parse(
            Packet(PacketType.fluxApprove, [
                "kind": "request", "id": "demo1", "host": "omarchy", "user": "dev", "service": "sudo", "tty": "pts/3",
                "time": Int64(now.timeIntervalSince1970), "nonce": String(repeating: "0", count: 64),
            ]),
            computerId: computers[0].id, computerName: "omarchy")
    }

    /// The sample Inbox items: the sample agents that wait, work, or are
    /// done, and a sudo request. They go through `Inbox.items`, so that
    /// they are what a computer gives.
    static func inboxItems(now: Date = Date()) -> [InboxItem] {
        Inbox.items(devices: computers, herdr: herdrStates, approval: approval(now: now))
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
