package org.omarchy.flux

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.ClipWatch
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Share

class FluxApp : Application() {
    override fun onCreate() {
        super.onCreate()
        FluxCore.init(this)
        Android.createChannels(this)
        // A transfer that failed, or a photo that did not go out, can leave a copy in the cache.
        FluxCore.io.execute { Share.cleanCache(cacheDir) }
        // Android 10 and later let an app read the clipboard only while it has
        // focus, so Flux watches the clipboard in the foreground. With the
        // automatic sync armed, ClipWatch keeps the listener for the life of
        // the process, because ClipboardService writes no line without it.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                FluxCore.foreground = true
                ClipWatch.setForeground(this@FluxApp, true)
                // The user can change a permission or the network in the system settings.
                FluxCore.refresh()
            }

            override fun onStop(owner: LifecycleOwner) {
                FluxCore.foreground = false
                ClipWatch.setForeground(this@FluxApp, false)
            }
        })
    }
}
