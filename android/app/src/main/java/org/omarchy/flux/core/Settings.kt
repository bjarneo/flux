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

    /** False after the user turns Flux off. Flux then starts no service and uses no network. */
    var enabled: Boolean
        get() = prefs.getBoolean("enabled", true)
        // It is written at once, so that the state survives when the process stops next.
        set(v) {
            prefs.edit().putBoolean("enabled", v).commit()
        }

    /** Sends the calls of this phone to the computers. It needs the phone permission. */
    var callAlerts: Boolean
        get() = prefs.getBoolean("callAlerts", false)
        set(v) = prefs.edit().putBoolean("callAlerts", v).apply()

    /** Syncs Do Not Disturb with the computers. It needs notification policy access. */
    var syncDnd: Boolean
        get() = prefs.getBoolean("syncDnd", true)
        set(v) = prefs.edit().putBoolean("syncDnd", v).apply()

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
