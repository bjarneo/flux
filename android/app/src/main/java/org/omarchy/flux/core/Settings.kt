package org.omarchy.flux.core

import android.content.Context

/** The switches on the device home screen. */
class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    var shareNotifications: Boolean
        get() = prefs.getBoolean("shareNotifications", true)
        set(v) = prefs.edit().putBoolean("shareNotifications", v).apply()

    var syncClipboard: Boolean
        get() = prefs.getBoolean("syncClipboard", true)
        set(v) = prefs.edit().putBoolean("syncClipboard", v).apply()

    /** The time of the last local clipboard change, in milliseconds. */
    var clipboardTimestamp: Long
        get() = prefs.getLong("clipboardTimestamp", 0)
        set(v) = prefs.edit().putLong("clipboardTimestamp", v).apply()
}
