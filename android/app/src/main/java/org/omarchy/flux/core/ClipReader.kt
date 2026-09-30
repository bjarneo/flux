package org.omarchy.flux.core

import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import org.omarchy.flux.ui.ClipboardSendActivity

private const val TAG = "FluxClipReader"

/**
 * Reads the clipboard after the log reader sees a copy. Android lets only
 * the window with focus read the clipboard, so the reader takes focus for a
 * moment. It uses a 1x1 focusable overlay window when Flux may draw over
 * other apps, and the invisible activity when it may not. It runs on the
 * main thread.
 */
object ClipReader {
    private val main = Handler(Looper.getMainLooper())

    // The time of the last focus grab, and whether a grab waits.
    @Volatile private var lastGrab = 0L
    private var pending = false

    // The overlay window while it waits for focus.
    private var overlay: View? = null

    /**
     * Asks for a read after a copy signal. It merges the lines of 1 copy,
     * ignores the lines that a Flux write makes, and grabs focus at most
     * once each second. See [ClipGate.grabDelay].
     */
    fun request(context: Context) {
        val app = context.applicationContext
        val now = SystemClock.elapsedRealtime()
        val delay = ClipGate.grabDelay(now, pending, lastGrab, Plugins.selfWriteAt)
        if (delay == ClipGate.NO_GRAB) return
        pending = true
        main.postDelayed({ grab(app) }, delay)
    }

    private fun grab(app: Context) {
        pending = false
        lastGrab = SystemClock.elapsedRealtime()
        if (Android.canDrawOverlays(app)) grabWithOverlay(app) else startActivity(app)
    }

    /**
     * Adds a 1x1 focusable overlay. FLAG_ALT_FOCUSABLE_IM keeps the
     * keyboard, because the window is not an input target. On focus, Flux
     * reads the clip and removes the window. Without focus in time, it falls
     * back to the invisible activity.
     */
    private fun grabWithOverlay(app: Context) {
        if (overlay != null) return
        val wm = app.getSystemService(WindowManager::class.java) ?: return startActivity(app)
        val params = WindowManager.LayoutParams(
            1, 1,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            // Android 12 and later block a touch that passes through a window
            // of another app when the window is more than 80% opaque. Alpha
            // 0.5 lets the touch through, and the view draws nothing, so the
            // pixel stays clear. Keep the alpha above 0, because SurfaceFlinger
            // gives no input focus to a window with alpha 0. The pixel goes to
            // the top left corner, away from the content of the app below.
            alpha = 0.5f
            gravity = Gravity.TOP or Gravity.START
        }
        val view = object : View(app) {
            override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
                super.onWindowFocusChanged(hasWindowFocus)
                if (hasWindowFocus) onOverlayFocused(app)
            }
        }
        overlay = view
        val ok = runCatching { wm.addView(view, params) }.isSuccess
        if (!ok) {
            overlay = null
            startActivity(app)
            return
        }
        // A window that hides overlays, for example a banking app, stops the
        // focus. The activity fallback then reads the clip.
        main.postDelayed({ if (overlay === view) { removeOverlay(app); startActivity(app) } }, FOCUS_TIMEOUT_MS)
    }

    private fun onOverlayFocused(app: Context) {
        val view = overlay ?: return
        Plugins.onLocalClipboard(FluxCore)
        removeOverlay(app)
        // Keep the reference check tidy for a late focus callback.
        if (overlay === view) overlay = null
    }

    private fun removeOverlay(app: Context) {
        val view = overlay ?: return
        overlay = null
        val wm = app.getSystemService(WindowManager::class.java) ?: return
        runCatching { wm.removeView(view) }.onFailure { Log.w(TAG, "remove overlay failed", it) }
    }

    /**
     * Starts the invisible activity, which reads the clip in
     * onWindowFocusChanged. FLAG_ACTIVITY_NEW_TASK is necessary for the
     * SYSTEM_ALERT_WINDOW background-start rule.
     */
    private fun startActivity(app: Context) {
        if (!Android.canDrawOverlays(app)) {
            // Without the overlay permission, a background activity start is
            // refused. Nothing to do until the user sets up the sync.
            return
        }
        val intent = Intent(app, ClipboardSendActivity::class.java)
            .putExtra(ClipboardSendActivity.EXTRA_MANUAL, false)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TASK or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION,
            )
        runCatching { app.startActivity(intent) }.onFailure { Log.w(TAG, "clip activity start failed", it) }
    }

    /** How long the overlay waits for window focus before it falls back. */
    private const val FOCUS_TIMEOUT_MS = 800L
}
