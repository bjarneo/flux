package org.omarchy.flux.core

/**
 * Debug builds only: sample chat data next to the sample computers of
 * [DebugDemo], so that the chat and the Omarchy panel render on an
 * emulator with no computer. All functions give nothing while the demo is
 * off. The samples take no network action.
 */
object DebugInbox {
    private val sampleShortcuts = ShortcutsState(
        shortcuts = listOf(
            Shortcut("menu", "SUPER ALT SPACE", "Omarchy menu"),
            Shortcut("apps", "SUPER SPACE", "Apps menu"),
            Shortcut("term", "SUPER RETURN", "Terminal"),
            Shortcut("browser", "SUPER SHIFT B", "Browser"),
            Shortcut("files", "SUPER SHIFT F", "File manager"),
            Shortcut("shot", "PRINT", "Screenshot"),
        ),
        workspaces = listOf(WorkspaceInfo(1, 2), WorkspaceInfo(2, 3), WorkspaceInfo(3, 1), WorkspaceInfo(5, 1)),
        active = 2,
        loaded = true,
        windows = listOf(
            WindowInfo("0x101", 1, "Chromium", "chromium", "omarchy.org · The Omarchy manual", focused = false),
            WindowInfo("0x102", 1, "Spotify", "spotify", "Marconi Union · Weightless", focused = false),
            WindowInfo("0x201", 2, "Alacritty", "Alacritty", "nvim ~/code/flux", focused = true),
            WindowInfo("0x202", 2, "Alacritty", "Alacritty", "herdr · billing", focused = false),
            WindowInfo("0x203", 2, "Chromium", "chromium", "Pull request #412 · basecamp/omarchy", focused = false),
            WindowInfo("0x301", 3, "Obsidian", "obsidian", "Flux notes", focused = false),
            WindowInfo("0x501", 5, "Signal", "signal", "Signal", focused = false),
        ),
    )

    /**
     * True while the debug page `<page>@connecting` shows. The sample
     * computer that is not reachable then shows as connecting.
     */
    @Volatile var connecting = false

    /** The state with the sample computer of [DebugDemo.PC] set up for the Omarchy panel. */
    fun decorate(state: UiState): UiState {
        if (!DebugDemo.on) return state
        return state.copy(
            connecting = state.connecting || connecting,
            devices = state.devices.map { d ->
                if (d.id == DebugDemo.PC) d.copy(shortcutsSupported = true, shortcuts = sampleShortcuts, agentSince = agentSince) else d
            },
        )
    }

    /** The time that the demo agents got their status, in the order of the design: done, working, then blocked. */
    private val agentSince: Map<String, Long>
        get() {
            val now = System.currentTimeMillis()
            return mapOf("w3:p1" to now - 17 * 60_000, "w1:p1" to now - 8 * 60_000, "w2:p1" to now - 4 * 60_000)
        }

    /** The sample entries of the chat log: a link, a photo, a clip from the computer, a file that comes in, and text. */
    fun sends(): List<SendEntry> {
        if (!DebugDemo.on) return emptyList()
        val now = System.currentTimeMillis()
        fun ago(min: Int) = now - min * 60_000L
        val pc = DebugDemo.PC
        return listOf(
            SendEntry(-11, pc, "omarchy-xps", SendKind.Link, "https://omarchy.org/manual", at = ago(49)),
            SendEntry(-12, pc, "omarchy-xps", SendKind.File, "holiday.jpg", at = ago(28), size = 2_400_000, done = 2_400_000),
            SendEntry(-13, pc, "omarchy-xps", SendKind.Clip, "git push origin ui-shell", incoming = true, at = ago(11)),
            SendEntry(
                -14, pc, "omarchy-xps", SendKind.File, "invoice-2026-09.pdf", incoming = true, at = ago(6),
                size = 3_200_000, done = 1_856_000, state = TransferState.Running,
            ),
            SendEntry(-15, pc, "omarchy-xps", SendKind.Text, "Dinner at 7, bring the kids", at = ago(1)),
        )
    }

    /** A sample sudo request from the sample computer. It is off when the demo has no blocked agent. */
    fun approval(): ApproveRequest? {
        if (!DebugDemo.on || !DebugDemo.blocked) return null
        return ApproveRequest(
            computerId = DebugDemo.PC,
            computerName = "omarchy-xps",
            id = "demo-approval",
            kind = ApproveRequest.Kind.Approve,
            host = "omarchy-xps",
            user = "dev",
            service = "sudo",
            tty = "pts/3",
            rhost = "",
            time = System.currentTimeMillis() / 1000,
            nonce = "0".repeat(64),
            timeoutSeconds = 60,
        )
    }
}
