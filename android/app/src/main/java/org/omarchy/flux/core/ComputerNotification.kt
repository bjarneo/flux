package org.omarchy.flux.core

import org.omarchy.flux.protocol.Packet

/** A notification that a computer sends to this phone, from a kdeconnect.notification packet. */
data class ComputerNotification(
    val key: String,
    val subText: String,
    val title: String,
    val text: String,
    val time: Long,
    val clearable: Boolean,
    val cancel: Boolean,
) {
    /** The ID of the Android notification. The same computer and ID replace the old notification. */
    val notificationId: Int get() = key.hashCode()

    companion object {
        /**
         * Reads the packet from the computer named [computer]. The app name
         * of the packet shows next to the computer name, when it is another
         * name. Returns null for a packet with no ID or no text.
         */
        fun from(p: Packet, deviceId: String, computer: String, now: Long): ComputerNotification? {
            val id = p.string("id")?.takeIf { it.isNotBlank() } ?: return null
            val cancel = p.bool("isCancel") == true
            val text = p.string("text").orEmpty().trim()
            val title = p.string("title").orEmpty().trim().ifEmpty { p.string("ticker").orEmpty().trim() }
            if (!cancel && title.isEmpty() && text.isEmpty()) return null
            val app = p.string("appName").orEmpty().trim()
            val sub = if (app.isEmpty() || app.equals(computer, ignoreCase = true)) computer else "$app · $computer"
            return ComputerNotification(
                key = "$deviceId:$id",
                subText = sub,
                title = title.ifEmpty { text },
                text = if (title.isEmpty()) "" else text,
                time = p.long("time")?.takeIf { it > 0 } ?: now,
                clearable = p.bool("isClearable") != false,
                cancel = cancel,
            )
        }
    }
}
