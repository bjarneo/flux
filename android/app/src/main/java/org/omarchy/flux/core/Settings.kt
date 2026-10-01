package org.omarchy.flux.core

import android.content.Context

/** The switches on the device home screen. */
class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val capture = context.getSharedPreferences("capture", Context.MODE_PRIVATE)

    var shareNotifications: Boolean
        get() = prefs.getBoolean("shareNotifications", true)
        set(v) = prefs.edit().putBoolean("shareNotifications", v).apply()

    var syncClipboard: Boolean
        get() = prefs.getBoolean("syncClipboard", true)
        set(v) = prefs.edit().putBoolean("syncClipboard", v).apply()

    /**
     * The automatic clipboard sync: Flux reads the system log for each copy
     * in another app. It is off until the user turns it on in the setup
     * sheet. While it is off, Flux starts no log reader, so Android shows no
     * log access dialog. It works only while [syncClipboard] is on. An
     * update from a version without the switch keeps the sync on, see
     * [ClipGate.keepsAutoSync].
     */
    var autoClipboard: Boolean
        get() = prefs.getBoolean("autoClipboard", false)
        set(v) = prefs.edit().putBoolean("autoClipboard", v).apply()

    /** True when the store holds [autoClipboard]. Without it, [FluxCore.init] sets the value once. */
    val hasAutoClipboard: Boolean
        get() = prefs.contains("autoClipboard")

    /** False after the user turns Flux off. Flux then starts no service and uses no network. */
    var enabled: Boolean
        get() = prefs.getBoolean("enabled", true)
        // It is written at once, so that the state survives when the process stops next.
        set(v) {
            prefs.edit().putBoolean("enabled", v).commit()
        }

    /** The descriptions of the shortcuts that the Omarchy panel pins, or null for the defaults. */
    var pinnedShortcuts: List<String>?
        get() = prefs.getString("pinnedShortcuts", null)?.split('\n')?.filter { it.isNotEmpty() }
        set(v) = prefs.edit().putString("pinnedShortcuts", v?.joinToString("\n")).apply()

    /** The color theme of the app. Without a choice, it is [ThemeMode.Computer]. */
    var theme: ThemeMode
        get() = ThemeMode.fromKey(prefs.getString("theme", null))
        set(v) = prefs.edit().putString("theme", v.key).apply()

    /**
     * The theme of each computer and the last theme, in the JSON form of
     * [org.omarchy.flux.theme.ThemeBook.toJson], or null. The next cold
     * start draws the theme at once.
     */
    var computerThemes: String?
        get() = prefs.getString("computerThemes", null)
        set(v) = prefs.edit().putString("computerThemes", v).apply()

    /** Sends the calls of this phone to the computers. It needs the phone permission. */
    var callAlerts: Boolean
        get() = prefs.getBoolean("callAlerts", false)
        set(v) = prefs.edit().putBoolean("callAlerts", v).apply()

    /** Offers the text messages of this phone to the computers. It needs SMS access. */
    var syncSms: Boolean
        get() = prefs.getBoolean("syncSms", false)
        set(v) = prefs.edit().putBoolean("syncSms", v).apply()

    /** Syncs Do Not Disturb with the computers. It needs notification policy access. */
    var syncDnd: Boolean
        get() = prefs.getBoolean("syncDnd", true)
        set(v) = prefs.edit().putBoolean("syncDnd", v).apply()

    /** Notifies when a herdr agent on a computer needs input. */
    var agentInputAlerts: Boolean
        get() = prefs.getBoolean("agentInputAlerts", true)
        set(v) = prefs.edit().putBoolean("agentInputAlerts", v).apply()

    /** Notifies when a herdr agent on a computer finishes its work. */
    var agentDoneAlerts: Boolean
        get() = prefs.getBoolean("agentDoneAlerts", true)
        set(v) = prefs.edit().putBoolean("agentDoneAlerts", v).apply()

    /** Sends each new screenshot to the computers. */
    var sendScreenshots: Boolean
        get() = prefs.getBoolean("sendScreenshots", false)
        set(v) = prefs.edit().putBoolean("sendScreenshots", v).apply()

    /** Sends each new camera photo to the computers. */
    var sendPhotos: Boolean
        get() = prefs.getBoolean("sendPhotos", false)
        set(v) = prefs.edit().putBoolean("sendPhotos", v).apply()

    /** The time of the last local clipboard change, in milliseconds. */
    var clipboardTimestamp: Long
        get() = prefs.getLong("clipboardTimestamp", 0)
        set(v) = prefs.edit().putLong("clipboardTimestamp", v).apply()

    /** What the capture watch has sent. It survives a restart. */
    var captureState: CaptureState
        get() {
            val from = buildMap {
                capture.getLong("fromScreenshot", -1).takeIf { it >= 0 }?.let { put(CaptureKind.Screenshot, it) }
                capture.getLong("fromPhoto", -1).takeIf { it >= 0 }?.let { put(CaptureKind.Photo, it) }
            }
            val sent = capture.getStringSet("sent", emptySet()).orEmpty().mapNotNull { it.toLongOrNull() }.toSet()
            return CaptureState(capture.getLong("baseline", 0), sent, from)
        }
        set(v) {
            capture.edit()
                .putLong("baseline", v.baseline)
                .putStringSet("sent", v.sent.map { it.toString() }.toSet())
                .putLong("fromScreenshot", v.from[CaptureKind.Screenshot] ?: -1)
                .putLong("fromPhoto", v.from[CaptureKind.Photo] ?: -1)
                .apply()
        }
}
