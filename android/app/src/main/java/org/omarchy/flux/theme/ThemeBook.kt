package org.omarchy.flux.theme

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import org.omarchy.flux.core.ComputerTheme

/**
 * The Omarchy themes of the computers, and the rules that pick the theme
 * that the Computer setting draws. It uses no Android class, so the unit
 * tests run it on the JVM. Each call is synchronized.
 *
 * A computer sends its theme on each connect, so a theme that comes again
 * changes nothing. The last theme is the theme that changed most recently.
 * Without a scope, the app draws the last theme. A reconnect, or the first
 * theme of a newly paired computer, does not change the last theme.
 */
class ThemeBook(private val palette: (OmarchyTheme) -> PaletteSpec = ::paletteOf) {
    /** The theme of each computer, in the order of change. The last entry changed most recently. */
    private val themes = LinkedHashMap<String, ComputerTheme>()

    /** The computer whose theme the app draws without a scope, or null. */
    var lastId: String? = null
        @Synchronized get
        private set

    /**
     * Takes the theme that the computer [id] sent. The theme becomes the
     * last theme when no last theme exists, when this computer sent the
     * last theme, or when the theme on this computer changed. Returns true
     * when the book changed and must be saved.
     */
    @Synchronized
    fun put(id: String, theme: OmarchyTheme): Boolean {
        val old = themes[id]
        if (old?.theme == theme) {
            if (lastId != null) return false
            lastId = id
            return true
        }
        themes.remove(id)
        themes[id] = ComputerTheme(id, theme, palette(theme))
        if (lastId == null || lastId == id || old != null) lastId = id
        return true
    }

    /**
     * Forgets the theme of a computer that is no longer paired. When it was
     * the last theme, the remaining theme that changed most recently takes
     * its place. Returns true when the book changed and must be saved.
     */
    @Synchronized
    fun forget(id: String): Boolean {
        themes.remove(id) ?: return false
        if (lastId == id) lastId = themes.keys.lastOrNull()
        return true
    }

    /**
     * The theme to draw. With a [scope], it is the theme of that computer,
     * or null when that computer sent no theme. Without a scope, it is the
     * last theme.
     */
    @Synchronized
    fun current(scope: String?): ComputerTheme? = themes[scope ?: lastId ?: return null]

    /** The theme of the computer [id], or null. */
    @Synchronized
    fun theme(id: String): ComputerTheme? = themes[id]

    /** The name of the theme of each computer, by device ID. */
    @Synchronized
    fun names(): Map<String, String> = themes.mapValues { it.value.name }

    /** Returns the book in the form that [load] reads. */
    @Synchronized
    fun toJson(): JsonObject = buildJsonObject {
        lastId?.let { put("last", it) }
        put(
            "computers",
            buildJsonArray {
                for ((id, t) in themes) add(buildJsonObject {
                    put("id", id)
                    put("theme", t.theme.toJson())
                })
            },
        )
    }

    /**
     * Restores the book from [saved], the form of [toJson]. It keeps only
     * the computers that [keep] accepts, for example the paired computers.
     * It ignores an entry that it cannot read.
     */
    @Synchronized
    fun load(saved: JsonObject?, keep: (String) -> Boolean = { true }) {
        themes.clear()
        lastId = null
        if (saved == null) return
        (saved["computers"] as? JsonArray)?.forEach { e ->
            val o = e as? JsonObject ?: return@forEach
            val id = (o["id"] as? JsonPrimitive)?.contentOrNull ?: return@forEach
            if (!keep(id)) return@forEach
            val theme = (o["theme"] as? JsonObject)?.let(OmarchyTheme::parse) ?: return@forEach
            themes.remove(id)
            themes[id] = ComputerTheme(id, theme, palette(theme))
        }
        val last = (saved["last"] as? JsonPrimitive)?.contentOrNull
        lastId = last?.takeIf { it in themes } ?: themes.keys.lastOrNull()
    }
}
