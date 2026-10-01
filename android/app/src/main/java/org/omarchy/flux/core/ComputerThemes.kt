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
import org.omarchy.flux.theme.ThemeBook
import org.omarchy.flux.theme.nightModeOf

/** The Omarchy theme of 1 computer, and its palette after the contrast guard. */
data class ComputerTheme(val deviceId: String, val theme: OmarchyTheme, val palette: PaletteSpec) {
    val name: String get() = theme.name
}

/**
 * The Omarchy themes of the computers. A computer sends flux.theme when
 * it connects and when its theme changes. [ThemeBook] keeps the theme of
 * each computer and picks the theme to draw. [Settings] keeps the book, so
 * that the next cold start draws the theme at once. [ThemeMode.Computer]
 * follows the computer in [scope], or the last theme without a scope.
 */
object ComputerThemes {
    private const val TAG = "FluxTheme"
    private val main = Handler(Looper.getMainLooper())
    private val book = ThemeBook()

    /** The night mode that the app set last. Only the main thread uses it. */
    private var applied: ThemeMode? = null

    /** The computer whose theme the app follows, or null for all computers. */
    @Volatile var scope: String? = null
        private set

    /**
     * Reads the themes from [settings]. It keeps only the computers that
     * [paired] accepts. [FluxCore.init] calls it before the first state.
     */
    fun load(settings: Settings, paired: (String) -> Boolean) {
        val saved = settings.computerThemes?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
        book.load(saved, paired)
    }

    /**
     * Takes a flux.theme packet from a paired computer. The core lock is
     * held, and the caller publishes the state.
     */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        val theme = OmarchyTheme.parse(p.body) ?: return
        if (!book.put(d.id, theme)) return
        save(core.settings)
        Log.i(TAG, "${d.identity.deviceName} uses the theme ${theme.name.ifEmpty { "without a name" }}")
        applyNightMode(core.app)
    }

    /** Forgets the theme of a computer that is no longer paired. */
    fun forget(core: FluxCore, id: String) {
        if (!book.forget(id)) return
        save(core.settings)
        applyNightMode(core.app)
    }

    private fun save(settings: Settings) {
        settings.computerThemes = book.toJson().toString()
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
        applyNightMode(FluxCore.app)
        FluxCore.publish()
    }

    /**
     * The theme that [ThemeMode.Computer] follows now. It is null when the
     * computer in scope, or each computer without a scope, sent no theme.
     */
    fun current(): ComputerTheme? {
        val s = scope
        DebugTheme.current()?.let { if (s == null || s == it.deviceId) return it }
        return book.current(s)
    }

    /** The name of the theme of each computer, by device ID. */
    fun names(): Map<String, String> {
        val names = book.names()
        return DebugTheme.current()?.let { names + (it.deviceId to it.name) } ?: names
    }

    /**
     * Sets the night mode of the app on Android 12 and later, so that the
     * system splash screen and the window background match the palette.
     * The main thread reads the setting and the theme when it applies the
     * night mode, so that a late call cannot apply an old value. It calls
     * the system only when the night mode changes.
     */
    fun applyNightMode(context: Context) {
        if (Looper.myLooper() == Looper.getMainLooper()) applyNow(context) else main.post { applyNow(context) }
    }

    private fun applyNow(context: Context) {
        val night = nightModeOf(FluxCore.settings.theme, current()?.palette)
        if (night == applied) return
        applied = night
        Android.setNightMode(context, night)
    }
}
