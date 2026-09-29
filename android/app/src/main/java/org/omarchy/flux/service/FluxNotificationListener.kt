package org.omarchy.flux.service

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.NotificationSync

/** Receives the phone notifications after the user grants notification access. */
class FluxNotificationListener : NotificationListenerService() {
    override fun onListenerConnected() {
        FluxCore.init(this)
        NotificationSync.listener = this
        FluxCore.refresh()
    }

    override fun onListenerDisconnected() {
        if (NotificationSync.listener === this) NotificationSync.listener = null
        // The user can take the notification access away.
        FluxCore.refresh()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        NotificationSync.onPosted(sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        NotificationSync.onRemoved(sbn)
    }
}
