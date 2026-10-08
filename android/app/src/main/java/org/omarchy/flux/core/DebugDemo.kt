package org.omarchy.flux.core

import android.os.SystemClock

/**
 * Debug builds only: sample computers, so that each screen renders on an
 * emulator with no computer. `adb shell am start -n
 * org.omarchy.flux/.ui.MainActivity --ez flux.debug.demo true` turns it on.
 * The sample computers take no network action.
 */
object DebugDemo {
    /** Sample agent output with terminal colors: an approval dialog of a coding agent. */
    private val demoOutput =
        "\u001b[38;2;215;119;87m●\u001b[0m I added the migration in \u001b[1mdb/migrate/0042_add_invoice_status.sql\u001b[0m.\n\n" +
            "\u001b[38;5;2m●\u001b[0m \u001b[1mWrite\u001b[0m(db/migrate/0042_add_invoice_status.sql)\n" +
            "  \u001b[38;5;8m⎿\u001b[0m  Wrote 18 lines to db/migrate/0042_add_invoice_status.sql\n\n" +
            "\u001b[38;5;2m●\u001b[0m \u001b[1mUpdate\u001b[0m(app/models/invoice.rb)\n" +
            "  \u001b[38;5;8m⎿\u001b[0m  Updated app/models/invoice.rb with 24 additions and 7 removals\n\n" +
            "\u001b[38;5;2m●\u001b[0m \u001b[1mBash\u001b[0m(bin/migrate --dry-run)\n" +
            "  \u001b[38;5;8m⎿\u001b[0m  1 migration to apply: \u001b[38;5;6m0042_add_invoice_status\u001b[0m\n\n" +
            "\u001b[38;5;4m" + "─".repeat(72) + "\u001b[0m\n" +
            " \u001b[1;38;5;4mBash command\u001b[0m\n\n" +
            "   bin/migrate --apply\n" +
            "   \u001b[38;5;8mApply the pending migration\u001b[0m\n\n" +
            " Do you want to proceed?\n" +
            " \u001b[38;5;4m❯ 1. Yes\u001b[0m\n" +
            "   2. Yes, and do not ask again for bin/migrate commands\n" +
            "   3. No, and tell Codex what to do differently \u001b[38;5;8m(esc)\u001b[0m\n"

    /** A box of an input, as an agent draws it under its output. */
    private const val INPUT_BOX = "\u001b[38;5;8m╭────────────────────────────╮\n│ >                          │\n╰────────────────────────────╯\u001b[0m\n  \u001b[38;5;8m? for shortcuts\u001b[0m\n"

    /** Sample output of the other demo agents, by pane: a working agent and a finished agent. */
    private val samples = mapOf(
        "w1:p1" to "\u001b[38;2;215;119;87m●\u001b[0m I'll put a token bucket in front of the upload handler, keyed by API key.\n\n" +
            "\u001b[38;5;2m●\u001b[0m \u001b[1mWrite\u001b[0m(src/middleware/rate_limit.ts)\n" +
            "  \u001b[38;5;8m⎿\u001b[0m  Wrote 61 lines to src/middleware/rate_limit.ts\n\n" +
            "\u001b[38;5;2m●\u001b[0m \u001b[1mUpdate\u001b[0m(src/routes/upload.ts)\n" +
            "  \u001b[38;5;8m⎿\u001b[0m  Updated src/routes/upload.ts with 3 additions and 1 removal\n\n" +
            "\u001b[38;5;4m●\u001b[0m \u001b[1mBash\u001b[0m(npm test -- upload)\n" +
            "  \u001b[38;5;8m⎿\u001b[0m  Running 48 tests… \u001b[38;5;2m31 passed\u001b[0m\n\n" +
            "\u001b[38;5;3m✻ Running tests… (2:14 · esc to interrupt)\u001b[0m\n\n" + INPUT_BOX,
        "w3:p1" to "\u001b[38;2;215;119;87m●\u001b[0m The login test waited on a fixed 2 s timeout. It now waits for the session cookie.\n\n" +
            "\u001b[38;5;2m●\u001b[0m \u001b[1mUpdate\u001b[0m(tests/login.spec.ts)\n" +
            "  \u001b[38;5;8m⎿\u001b[0m  Updated tests/login.spec.ts with 4 additions and 2 removals\n\n" +
            "\u001b[38;5;2m●\u001b[0m \u001b[1mBash\u001b[0m(npm test -- login --repeat 20)\n" +
            "  \u001b[38;5;8m⎿\u001b[0m  \u001b[38;5;2m20 passed\u001b[0m\n\n" +
            "\u001b[38;2;215;119;87m●\u001b[0m Done. The test passed 20 times in a row.\n\n" +
            "\u001b[38;5;8m✻ Worked for 6m 12s\u001b[0m\n\n" + INPUT_BOX,
    )

    /** Sample review diffs of the demo agents, by pane, in the format of fluxd. */
    private val diffs = mapOf(
        "w2:p1" to "Changed files\n M app/models/invoice.rb\n?? db/migrate/0042_add_invoice_status.sql\n\nWorking tree changes\n" +
            "diff --git a/app/models/invoice.rb b/app/models/invoice.rb\nindex 3f2a1c0..9b8d7e1 100644\n--- a/app/models/invoice.rb\n+++ b/app/models/invoice.rb\n" +
            "@@ -12,9 +12,26 @@ class Invoice\n   belongs_to :account\n-  def paid?\n-    paid_at.present?\n-  end\n" +
            "+  STATUSES = %w[draft open paid void]\n+  validates :status, inclusion: STATUSES\n+  def paid? = status == \"paid\"\n" +
            "\ndiff --git a/db/migrate/0042_add_invoice_status.sql b/db/migrate/0042_add_invoice_status.sql\nnew file\n" +
            "+ALTER TABLE invoices\n+  ADD COLUMN status text NOT NULL\n+  DEFAULT 'draft';\n+CREATE INDEX invoices_status_idx\n+  ON invoices (status);\n+\n",
        "w1:p1" to "Changed files\n M src/routes/upload.ts\n?? src/middleware/rate_limit.ts\n\nWorking tree changes\n" +
            "diff --git a/src/routes/upload.ts b/src/routes/upload.ts\nindex 1a2b3c4..5d6e7f8 100644\n--- a/src/routes/upload.ts\n+++ b/src/routes/upload.ts\n" +
            "@@ -4,7 +4,9 @@\n-router.post(\"/v1/upload\", upload)\n+router.post(\"/v1/upload\",\n+  rateLimit({ perMinute: 30 }), upload)\n" +
            "\ndiff --git a/src/middleware/rate_limit.ts b/src/middleware/rate_limit.ts\nnew file\n" +
            "+export function rateLimit(opts: Limits) {\n+  const buckets = new Map<string, Bucket>()\n+  return (req, res, next) => {\n+\n",
        "w3:p1" to "Changed files\n M tests/login.spec.ts\n\nWorking tree changes\n" +
            "diff --git a/tests/login.spec.ts b/tests/login.spec.ts\nindex 2b3c4d5..6e7f8a9 100644\n--- a/tests/login.spec.ts\n+++ b/tests/login.spec.ts\n" +
            "@@ -21,8 +21,10 @@\n-  await page.waitForTimeout(2000)\n+  await expect.poll(() =>\n+    context.cookies()).toContainEqual(\n" +
            "+      expect.objectContaining({ name: 'session' }))\n",
    )

    /** The sample output of a demo agent in [pane], or null. */
    fun output(pane: String): HerdrOutput? = samples[pane]?.let { HerdrOutput(pane, loading = false, lines = termLines(it)) }

    /** The sample review diff of a demo agent in [pane], or the text of a repository with no changes. */
    fun review(pane: String): HerdrOutput =
        HerdrOutput(pane, loading = false, lines = termLines(diffs[pane] ?: "No changes in this repository."), view = "diff")

    const val PC = "demo-omarchy-xps"
    const val OFFLINE = "demo-omarchy-desk"
    const val NEW = "demo-framework"

    @Volatile var on = false

    /** Debug-only ANSI sample for reproducible agent-output screenshots. */
    @Volatile var agentOutput: String? = null

    /** Debug-only ANSI sample for reproducible terminal screenshots. */
    @Volatile var terminalSample: String? = null

    /** Debug-only terminal grid of [terminalSample], such as "120x40". */
    @Volatile var terminalGrid: String? = null

    fun isDemo(id: String?) = id != null && id.startsWith("demo-")

    fun devices(): List<DeviceUi> {
        if (!on) return emptyList()
        return listOf(
            device(PC, "omarchy-xps", "laptop", "192.168.2.122", paired = true, online = true).copy(
                battery = 82,
                charging = true,
                players = listOf("Spotify", "Firefox"),
                player = PlayerState(
                    name = "Spotify", title = "Weightless", artist = "Marconi Union", album = "Weightless",
                    playing = true, position = 192_000, length = 489_000, canSeek = true,
                    updatedAt = SystemClock.elapsedRealtime(),
                ),
                commands = listOf(
                    RemoteCommand("lock", "Lock screen", "omarchy-system-lock"),
                    RemoteCommand("shot", "Screenshot", "omarchy-capture-screenshot fullscreen save"),
                    RemoteCommand("sleep", "Suspend", "systemctl suspend"),
                ),
                commandsLoaded = true,
                herdrSupported = true,
                inputSupported = true,
                remoteInput = true,
                desktopSupported = true,
                remoteDesktop = true,
                herdr = HerdrState(
                    enabled = true,
                    running = true,
                    control = true,
                    review = true,
                    agents = listOf(
                        HerdrAgent("w1:p1", "claude", AgentStatus.Working, "Add rate limiting to /v1/upload", "api", "api"),
                        HerdrAgent("w2:p1", "codex", AgentStatus.Blocked, "Run the database migration", "billing", "billing"),
                        HerdrAgent("w3:p1", "claude", AgentStatus.Done, "Fix the flaky login test", "web", "web"),
                        HerdrAgent("w3:p2", "pi", AgentStatus.Idle, "", "web", "web"),
                    ),
                    terminals = true,
                    panes = listOf(
                        HerdrTerminal("w1:p2", "user@desk:~/Code/flux", "flux", "flux"),
                        HerdrTerminal("w3:p3", "npm run dev", "web", "web"),
                    ),
                    workspaces = listOf(
                        HerdrWorkspace("w1", "flux", "~/Code/flux"),
                        HerdrWorkspace("w2", "billing", "~/Code/billing"),
                        HerdrWorkspace("w3", "web", "~/Code/web"),
                    ),
                    kinds = listOf("claude", "codex", "opencode"),
                    bridge = listOf("observe", "control", "scroll", "mouse"),
                ),
                herdrOutput = HerdrOutput(
                    pane = "w2:p1",
                    loading = false,
                    lines = termLines(agentOutput ?: demoOutput),
                ),
            ),
            device(OFFLINE, "omarchy-desk", "desktop", "192.168.2.40", paired = true, online = false),
            device(NEW, "framework-13", "laptop", "192.168.2.77", paired = false, online = true),
        )
    }

    fun browse(): BrowseState = BrowseState(
        deviceId = PC,
        loading = false,
        canSearch = true,
        roots = listOf("Home" to "/home/user/", "Downloads" to "/home/user/Downloads/"),
        path = "/home/user/",
        entries = listOf(
            BrowseEntry("Documents", "/home/user/Documents", dir = true, size = 0),
            BrowseEntry("Downloads", "/home/user/Downloads", dir = true, size = 0),
            BrowseEntry("Pictures", "/home/user/Pictures", dir = true, size = 0),
            BrowseEntry("boarding-pass.pdf", "/home/user/boarding-pass.pdf", dir = false, size = 220_000),
            BrowseEntry("holiday.jpg", "/home/user/holiday.jpg", dir = false, size = 4_200_000),
            BrowseEntry("notes.md", "/home/user/notes.md", dir = false, size = 3_400),
            BrowseEntry("talk.mp4", "/home/user/talk.mp4", dir = false, size = 182_000_000),
        ),
    )

    /** The files of the demo computer below the home folder, for the demo search. */
    private val demoFiles = browse().entries + listOf(
        BrowseEntry("invoice-2026-09.pdf", "/home/user/Documents/invoice-2026-09.pdf", dir = false, size = 84_000),
        BrowseEntry("invoices", "/home/user/Documents/invoices", dir = true, size = 0),
        BrowseEntry("invoice-2026-08.pdf", "/home/user/Documents/invoices/invoice-2026-08.pdf", dir = false, size = 79_000),
        BrowseEntry("lease.pdf", "/home/user/Documents/lease.pdf", dir = false, size = 1_300_000),
        BrowseEntry("flux-android.apk", "/home/user/Downloads/flux-android.apk", dir = false, size = 118_000_000),
        BrowseEntry("holiday-beach.jpg", "/home/user/Pictures/holiday-beach.jpg", dir = false, size = 3_900_000),
    )

    /** Searches the demo computer as fluxd does: each word in the name, in [path] and its subfolders. */
    fun search(query: String, path: String): BrowseSearch {
        val from = path.trimEnd('/')
        val results = demoFiles
            .filter { from.isEmpty() || it.path.startsWith("$from/") }
            .filter { Browse.matches(it.name, query) }
            .sortedBy { it.path.count { c -> c == '/' } }
        return BrowseSearch(0, query.trim(), path, loading = false, results = results)
    }

    private fun device(id: String, name: String, type: String, ip: String, paired: Boolean, online: Boolean) = DeviceUi(
        id = id, name = name, type = type, ip = ip, paired = paired, online = online,
        pairState = if (paired) PairState.Paired else PairState.None, pairKey = "", pairOutgoing = false,
        battery = null, charging = false, players = emptyList(), player = null,
        commands = emptyList(), commandsLoaded = false,
    )
}
