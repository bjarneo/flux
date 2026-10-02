package org.omarchy.flux.ui

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import androidx.activity.ComponentActivity
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.service.FluxService

/**
 * The clipboard sender: no UI. It takes window focus, so Flux may read the
 * clipboard, sends it to each connected paired computer, and finishes. The
 * Quick Settings tile and the service notification start it. It uses
 * Theme.Flux.Invisible, which draws nothing but keeps a focusable window.
 */
class ClipboardSendActivity : ComponentActivity() {
    private var done = false
    private val giveUp = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        FluxCore.init(this)
        FluxService.start(this)
        // The window never gets focus in rare cases, so finish anyway.
        giveUp.postDelayed({
            if (!done) {
                done = true
                toast(applicationContext, "Flux could not read the clipboard. Try again")
                finish()
            }
        }, GIVE_UP_MS)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        giveUp.removeCallbacksAndMessages(null)
        val app = applicationContext
        Plugins.sendClipboardToAll(FluxCore, manual = true) { toast(app, it) }
        finish()
    }

    override fun onDestroy() {
        giveUp.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    companion object {
        /** The read must not wait forever for window focus. */
        private const val GIVE_UP_MS = 2_000L

        private val main by lazy { Handler(Looper.getMainLooper()) }

        /**
         * Shows a system toast from any thread. The in-app snackbar shows
         * only in MainActivity, and this activity finishes before an image
         * transfer ends, so the toast uses the application context.
         */
        private fun toast(app: Context, message: String) {
            main.post { Toast.makeText(app, message, Toast.LENGTH_SHORT).show() }
        }
    }
}
