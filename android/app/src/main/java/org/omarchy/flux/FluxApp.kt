package org.omarchy.flux

import android.app.Application
import android.content.ClipboardManager
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.core.Share
import org.omarchy.flux.stream.LiveStreams
import org.omarchy.flux.webcam.WebcamHost

class FluxApp : Application() {
    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener { Plugins.onLocalClipboard(FluxCore) }

    override fun onCreate() {
        super.onCreate()
        FluxCore.init(this)
        Android.createChannels(this)
        // A transfer that failed, or a photo that did not go out, can leave a copy in the cache.
        FluxCore.io.execute { Share.cleanCache(cacheDir) }
        // A webcam or mic stream keeps running while Flux is in the background.
        WebcamHost.start(this)
        LiveStreams.start(this)
        // Android 10 and later let an app read the clipboard only while it has
        // focus, so Flux watches the clipboard only while it is in front.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                FluxCore.foreground = true
                getSystemService(ClipboardManager::class.java)?.addPrimaryClipChangedListener(clipListener)
                // The user can change a permission or the network in the system settings.
                FluxCore.refresh()
            }

            override fun onStop(owner: LifecycleOwner) {
                FluxCore.foreground = false
                getSystemService(ClipboardManager::class.java)?.removePrimaryClipChangedListener(clipListener)
            }
        })
    }
}
