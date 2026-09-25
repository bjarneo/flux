package org.omarchy.flux.core

import android.os.SystemClock

/**
 * Debug builds only: sample computers, so that each screen renders on an
 * emulator with no computer. `adb shell am start -n
 * org.omarchy.flux/.ui.MainActivity --ez flux.debug.demo true` turns it on.
 * The sample computers take no network action.
 */
object DebugDemo {
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
        id = id, name = name, type = type, ip = ip, isFlux = true, paired = paired, online = online,
        pairState = if (paired) PairState.Paired else PairState.None, pairKey = "", pairOutgoing = false,
        battery = null, charging = false, players = emptyList(), player = null,
        commands = emptyList(), commandsLoaded = false,
    )
}
