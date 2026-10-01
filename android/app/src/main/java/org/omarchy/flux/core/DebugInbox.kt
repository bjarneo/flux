package org.omarchy.flux.core

/**
 * Debug builds only: sample Inbox data next to the sample computers of
 * [DebugDemo], so that the Inbox and the Omarchy panel render on an
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
        workspaces = listOf(WorkspaceInfo(1, 2), WorkspaceInfo(2, 1), WorkspaceInfo(3, 3), WorkspaceInfo(5, 1)),
        active = 2,
        loaded = true,
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
                if (d.id == DebugDemo.PC) d.copy(shortcutsSupported = true, shortcuts = sampleShortcuts) else d
            },
        )
    }

    /** A sample sudo request from the sample computer. */
    fun approval(): ApproveRequest? {
        if (!DebugDemo.on) return null
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

    /** A sample transfer that runs and one that ended. */
    fun transfers(): List<Transfer> {
        if (!DebugDemo.on) return emptyList()
        val now = System.currentTimeMillis()
        return listOf(
            Transfer(-1, DebugDemo.PC, "omarchy-xps", "invoice-2026-09.pdf", incoming = true, state = TransferState.Running, at = now),
            Transfer(-2, DebugDemo.PC, "omarchy-xps", "holiday.jpg", incoming = false, state = TransferState.Done, at = now - 120_000, ended = now - 100_000),
        )
    }

    /** A sample clip from the sample computer. */
    fun clip(): ClipEvent? {
        if (!DebugDemo.on) return null
        return ClipEvent(listOf(DebugDemo.PC), "omarchy-xps", sent = false, preview = "git push origin ui-shell", at = System.currentTimeMillis() - 60_000)
    }
}
