package org.omarchy.flux.ui

import android.os.Build
import android.view.MotionEvent
import android.view.Window
import androidx.activity.compose.LocalActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import org.omarchy.flux.protocol.groupKey

/**
 * Guards the pair sheet and the approval screen against windows of other
 * apps. An overlay can show a false code or a false request over the real
 * one, so that the user taps Pair or Approve.
 */
object Overlays {
    /** True when a window of another app covered the touch point of [ev], or a part of the window before Android 12. */
    fun obscured(ev: MotionEvent): Boolean = obscured(ev.flags, Build.VERSION.SDK_INT)

    /**
     * Decides from the [flags] of a touch on Android [sdk]. From Android 12,
     * [hide] removes the windows of other apps, so only a window over the
     * touch point counts. A window that the system keeps, such as the handle
     * of an edge panel, then covers only a part and does not block a tap.
     * Before Android 12, a window over any part of the window counts too.
     */
    internal fun obscured(flags: Int, sdk: Int): Boolean {
        val covered = if (sdk >= 31) {
            MotionEvent.FLAG_WINDOW_IS_OBSCURED
        } else {
            MotionEvent.FLAG_WINDOW_IS_OBSCURED or MotionEvent.FLAG_WINDOW_IS_PARTIALLY_OBSCURED
        }
        return flags and covered != 0
    }

    /** Android 12 and later: hides the windows that other apps draw over [window] while [hide] is true. */
    fun hide(window: Window, hide: Boolean) {
        if (Build.VERSION.SDK_INT >= 31) window.setHideOverlayWindows(hide)
    }
}

/** Hides the windows that other apps draw over the activity while this composable shows. */
@Composable
fun HideOverlays() {
    val activity = LocalActivity.current ?: return
    DisposableEffect(activity) {
        Overlays.hide(activity.window, true)
        onDispose { Overlays.hide(activity.window, false) }
    }
}

/**
 * The verification key of a pairing as the screen shows it: 16 hex digits
 * in 4 groups of 4, such as 5EE6 825F 974E D59A. The user compares all 16
 * digits with the computer. [groupKey] makes the groups, the same as in the
 * pair notification.
 */
object PairKey {
    /** Returns the key with a space between the groups. A key that is not ready gives 4 groups of dots. */
    fun display(key: String): String {
        val digits = key.filterNot { it.isWhitespace() }.uppercase()
        return if (digits.isEmpty()) List(4) { "…" }.joinToString(" ") else groupKey(digits)
    }

    /** Returns the groups of 4 digits, 1 for each box of the pair sheet. */
    fun groups(key: String): List<String> = display(key).split(" ")
}
