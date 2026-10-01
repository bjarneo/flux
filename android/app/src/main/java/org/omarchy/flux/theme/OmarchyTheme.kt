package org.omarchy.flux.theme

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put

/**
 * The active Omarchy theme of a computer, from a flux.theme packet. The
 * packet body is {"name", "mode": "dark" or "light", "colors": {key:
 * "#rrggbb"}, "border": {"colors": ["#rrggbbaa", ...], "angle": deg}}. The
 * color keys are the keys of colors.toml, for example background,
 * foreground, accent, muted, and red. Any key can be missing.
 */
data class OmarchyTheme(
    val name: String,
    /** True for the "dark" mode, false for "light", or null when the computer does not tell. */
    val dark: Boolean?,
    /** The colors by their colors.toml key, as 0xRRGGBB. */
    val colors: Map<String, Int>,
    /** The colors of the active Hyprland border, as 0xRRGGBB, or empty for none. */
    val border: List<Int> = emptyList(),
    /** The angle of the border gradient in degrees, or null for a corner-to-corner gradient. */
    val borderAngle: Float? = null,
) {
    operator fun get(key: String): Int? = colors[key]

    /** Returns the theme in the packet form, for example to keep it after a restart. */
    fun toJson(): JsonObject = buildJsonObject {
        put("name", name)
        dark?.let { put("mode", if (it) "dark" else "light") }
        put("colors", buildJsonObject { colors.forEach { (k, v) -> put(k, hex(v)) } })
        if (border.isNotEmpty() || borderAngle != null) {
            put(
                "border",
                buildJsonObject {
                    put("colors", buildJsonArray { border.forEach { add(JsonPrimitive(hex(it))) } })
                    borderAngle?.let { put("angle", it) }
                },
            )
        }
    }

    companion object {
        /** The most colors that Flux keeps from 1 theme. */
        const val MAX_COLORS = 64

        /** The most border colors that Flux keeps. Hyprland takes 10. */
        const val MAX_BORDER = 10

        /** The longest theme name that Flux keeps. */
        const val MAX_NAME = 64

        private val KEY = Regex("^[a-z][a-z0-9_]{0,31}$")
        private val HEX = Regex("^#?([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$")

        /**
         * Reads a theme from a packet body. It ignores a key or a color
         * that it cannot read. It returns null when the body has no
         * readable color.
         */
        fun parse(body: JsonObject): OmarchyTheme? {
            val colors = LinkedHashMap<String, Int>()
            (body["colors"] as? JsonObject)?.forEach { (key, value) ->
                if (colors.size >= MAX_COLORS || !KEY.matches(key)) return@forEach
                parseColor((value as? JsonPrimitive)?.contentOrNull)?.let { colors[key] = it }
            }
            val borderObj = body["border"] as? JsonObject
            val border = (borderObj?.get("colors") as? JsonArray)
                ?.mapNotNull { parseColor((it as? JsonPrimitive)?.contentOrNull) }
                ?.take(MAX_BORDER)
                .orEmpty()
            val angle = (borderObj?.get("angle") as? JsonPrimitive)
                ?.let { it.doubleOrNull ?: it.contentOrNull?.removeSuffix("deg")?.trim()?.toDoubleOrNull() }
                ?.takeIf { it.isFinite() }
                ?.let { (((it % 360) + 360) % 360).toFloat() }
            if (colors.isEmpty() && border.isEmpty()) return null
            val name = (body["name"] as? JsonPrimitive)?.contentOrNull?.trim()?.take(MAX_NAME).orEmpty()
            val dark = when ((body["mode"] as? JsonPrimitive)?.contentOrNull?.lowercase()) {
                "dark" -> true
                "light" -> false
                else -> null
            }
            return OmarchyTheme(name, dark, colors, border, angle)
        }

        /** Reads "#rrggbb" or "#rrggbbaa" as 0xRRGGBB. It drops the alpha. */
        fun parseColor(text: String?): Int? {
            val m = HEX.matchEntire(text?.trim() ?: return null) ?: return null
            return m.groupValues[1].toInt(16)
        }

        /** Writes 0xRRGGBB as "#rrggbb". */
        fun hex(rgb: Int): String = "#" + Integer.toHexString(opaque(rgb)).padStart(6, '0')
    }
}
