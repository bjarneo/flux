package org.omarchy.flux.ui

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.service.FluxService

/**
 * The clipboard sender: no UI. It takes window focus, so Flux may read the
 * clipboard, sends it to each connected paired computer, and finishes. The
 * Quick Settings tile, the service notification, and the automatic reader
 * start it. It uses Theme.Flux.Invisible, which draws nothing but keeps a
 * focusable window.
 */
class ClipboardSendActivity : ComponentActivity() {
    private var done = false
    private val giveUp = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        FluxCore.init(this)
        FluxService.start(this)
        // The window never gets focus in rare cases, so finish anyway.
        giveUp.postDelayed({ if (!done) { done = true; finish() } }, GIVE_UP_MS)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        giveUp.removeCallbacksAndMessages(null)
        val manual = intent?.getBooleanExtra(EXTRA_MANUAL, true) ?: true
        Plugins.sendClipboardToAll(FluxCore, manual = manual)
        finish()
    }

    override fun onDestroy() {
        giveUp.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    companion object {
        /** True for a user action, which shows a toast. False for the automatic reader. */
        const val EXTRA_MANUAL = "flux.clip.manual"

        /** The read must not wait forever for window focus. */
        private const val GIVE_UP_MS = 2_000L
    }
}
