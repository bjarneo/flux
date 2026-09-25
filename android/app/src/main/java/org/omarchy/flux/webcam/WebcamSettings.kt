package org.omarchy.flux.webcam

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.omarchy.flux.protocol.json

/**
 * The webcam settings of this phone. The settings screen and the computer
 * both change them through [update]. Each change is saved, so the next
 * session starts with the same settings.
 */
object WebcamSettings {
    private const val PREFS = "flux.webcam"
    private const val KEY = "config"

    private val lock = Any()
    private var prefs: SharedPreferences? = null
    private val _config = MutableStateFlow(WebcamConfig())
    private val _caps = MutableStateFlow(WebcamCaps.LOOSE)

    val config: StateFlow<WebcamConfig> = _config
    val caps: StateFlow<WebcamCaps> = _caps

    /** Reads the saved settings. Later calls do nothing. */
    fun load(context: Context) {
        synchronized(lock) {
            if (prefs != null) return
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs = p
            val saved = p.getString(KEY, null)?.let { runCatching { json.parseToJsonElement(it).jsonObject }.getOrNull() }
            _config.value = WebcamConfig().merged(saved).clamped(_caps.value)
        }
    }

    /** Changes the settings. The result is clamped to the caps and saved. */
    fun update(change: (WebcamConfig) -> WebcamConfig) {
        synchronized(lock) {
            val current = _config.value
            val next = change(current).clamped(_caps.value)
            if (next == current) return
            _config.value = next
            prefs?.edit()?.putString(KEY, next.toJson().toString())?.apply()
        }
    }

    /** Applies a "config" message from the computer. */
    fun applyRemote(reset: Boolean, partial: JsonObject?) = update { c -> (if (reset) c.reset() else c).merged(partial) }

    /** Sets what the current camera supports, and clamps the settings to it. */
    fun setCaps(caps: WebcamCaps) {
        synchronized(lock) { _caps.value = caps }
        update { it }
    }
}
