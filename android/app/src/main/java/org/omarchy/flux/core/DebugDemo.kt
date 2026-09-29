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

    const val PC = "demo-omarchy-xps"
    const val OFFLINE = "demo-omarchy-desk"
    const val NEW = "demo-framework"

    @Volatile var on = false

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
                    agents = listOf(
                        HerdrAgent("w1:p1", "claude", AgentStatus.Working, "Refactor the sync loop", "flux", "flux"),
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
                ),
                herdrOutput = HerdrOutput(
                    pane = "w2:p1",
                    loading = false,
                    lines = termLines(demoOutput),
                ),
            ),
            device(OFFLINE, "omarchy-desk", "desktop", "192.168.2.40", paired = true, online = false),
            device(NEW, "framework-13", "laptop", "192.168.2.77", paired = false, online = true),
        )
    }

    fun browse(): BrowseState = BrowseState(
        deviceId = PC,
        loading = false,
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

    private fun device(id: String, name: String, type: String, ip: String, paired: Boolean, online: Boolean) = DeviceUi(
        id = id, name = name, type = type, ip = ip, paired = paired, online = online,
        pairState = if (paired) PairState.Paired else PairState.None, pairKey = "", pairOutgoing = false,
        battery = null, charging = false, players = emptyList(), player = null,
        commands = emptyList(), commandsLoaded = false,
    )
}
