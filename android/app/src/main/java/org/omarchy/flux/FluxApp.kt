package org.omarchy.flux

import android.app.Application
import android.content.ClipboardManager
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins

class FluxApp : Application() {
    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener { Plugins.onLocalClipboard(FluxCore) }

    override fun onCreate() {
        super.onCreate()
        FluxCore.init(this)
        Android.createChannels(this)
        // Android 10 and later let an app read the clipboard only while it
        // has focus, so Flux watches the clipboard only in the foreground.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                FluxCore.foreground = true
                getSystemService(ClipboardManager::class.java)?.addPrimaryClipChangedListener(clipListener)
                FluxCore.publish()
            }

            override fun onStop(owner: LifecycleOwner) {
                FluxCore.foreground = false
                getSystemService(ClipboardManager::class.java)?.removePrimaryClipChangedListener(clipListener)
            }
        })
    }
}
