package org.omarchy.flux.core

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.serialization.json.JsonObject
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.json
import org.omarchy.flux.theme.OmarchyTheme
import org.omarchy.flux.theme.PaletteSpec
import org.omarchy.flux.theme.nightModeOf
import org.omarchy.flux.theme.paletteOf
import java.util.concurrent.ConcurrentHashMap

/** The Omarchy theme of 1 computer, and its palette after the contrast guard. */
data class ComputerTheme(val deviceId: String, val theme: OmarchyTheme, val palette: PaletteSpec) {
    val name: String get() = theme.name
}

/**
 * The Omarchy themes of the computers. A computer sends flux.theme when
 * it connects and when its theme changes. Flux keeps the theme of each
 * computer while it runs, and the last theme in [Settings], so that the
 * next cold start draws it at once. [ThemeMode.Computer] follows the
 * computer in [scope]. Without a scope, or for a computer that sent no
 * theme, it follows the last theme.
 */
object ComputerThemes {
    private const val TAG = "FluxTheme"
    private val main = Handler(Looper.getMainLooper())
    private val themes = ConcurrentHashMap<String, ComputerTheme>()
    @Volatile private var last: ComputerTheme? = null
    @Volatile private var applied: ThemeMode? = null

    /** The computer whose theme the app follows, or null for all computers. */
    @Volatile var scope: String? = null
        private set

    /** Reads the last theme from [settings]. [FluxCore.init] calls it before the first state. */
    fun load(settings: Settings) {
        val from = settings.computerThemeFrom ?: return
        val body = settings.computerTheme?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() } ?: return
        val theme = OmarchyTheme.parse(body) ?: return
        val t = ComputerTheme(from, theme, paletteOf(theme))
        themes[from] = t
        last = t
    }

    /**
     * Takes a flux.theme packet from a paired computer. The core lock is
     * held, and the caller publishes the state.
     */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        val theme = OmarchyTheme.parse(p.body) ?: return
        val known = themes[d.id]?.takeIf { it.theme == theme }
        val t = known ?: ComputerTheme(d.id, theme, paletteOf(theme)).also { themes[d.id] = it }
        if (last != t) {
            last = t
            core.settings.computerTheme = theme.toJson().toString()
            core.settings.computerThemeFrom = d.id
        }
        if (known == null) Log.i(TAG, "${d.identity.deviceName} uses the theme ${theme.name.ifEmpty { "without a name" }}")
        applyNightMode(core.app, core.settings.theme)
    }

    /**
     * Forgets the theme of a computer that is no longer paired. When it
     * sent the last theme, the theme of another computer takes its place.
     */
    fun forget(core: FluxCore, id: String) {
        themes.remove(id) ?: return
        if (last?.deviceId == id) {
            val next = themes.values.firstOrNull()
            last = next
            core.settings.computerTheme = next?.theme?.toJson()?.toString()
            core.settings.computerThemeFrom = next?.deviceId
        }
        applyNightMode(core.app, core.settings.theme)
    }

    /**
     * Sets the computer whose theme the app follows, or null for all
     * computers. The scope chip calls it when the user picks a computer.
     */
    fun setScope(id: String?) {
        if (scope == id) return
        scope = id
        refresh()
    }

    /** Applies the night mode again and publishes the state, for example after a debug theme change. */
    fun refresh() {
        applyNightMode(FluxCore.app, FluxCore.settings.theme)
        FluxCore.publish()
    }

    /** The theme that [ThemeMode.Computer] follows now, or null when no computer has sent one. */
    fun current(): ComputerTheme? {
        val s = scope
        DebugTheme.current()?.let { if (s == null || s == it.deviceId) return it }
        return s?.let { themes[it] } ?: last
    }

    /** The name of the theme of each computer, by device ID. */
    fun names(): Map<String, String> {
        val names = themes.mapValues { it.value.name }
        return DebugTheme.current()?.let { names + (it.deviceId to it.name) } ?: names
    }

    /**
     * Sets the night mode of the app on Android 12 and later, so that the
     * system splash screen and the window background match the palette.
     * It calls the system only when the night mode changes.
     */
    fun applyNightMode(context: Context, mode: ThemeMode) {
        val night = nightModeOf(mode, current()?.palette)
        if (night == applied) return
        applied = night
        if (Looper.myLooper() == Looper.getMainLooper()) Android.setNightMode(context, night)
        else main.post { Android.setNightMode(context, night) }
    }
}
