package org.omarchy.flux.protocol

/** The largest identity line that Flux sends or reads. */
const val MAX_IDENTITY_LINE = 8192

/** Packet types that the Flux phone app uses. */
object Types {
    const val IDENTITY = "kdeconnect.identity"
    const val PAIR = "kdeconnect.pair"
    const val PING = "kdeconnect.ping"
    const val BATTERY = "kdeconnect.battery"
    const val BATTERY_REQUEST = "kdeconnect.battery.request"
    const val CLIPBOARD = "kdeconnect.clipboard"
    const val CLIPBOARD_CONNECT = "kdeconnect.clipboard.connect"
    const val SHARE = "kdeconnect.share.request"
    const val SHARE_UPDATE = "kdeconnect.share.request.update"
    const val NOTIFICATION = "kdeconnect.notification"
    const val NOTIFICATION_REQUEST = "kdeconnect.notification.request"
    const val NOTIFICATION_REPLY = "kdeconnect.notification.reply"
    const val NOTIFICATION_ACTION = "kdeconnect.notification.action"
    const val FIND_MY_PHONE = "kdeconnect.findmyphone.request"
    const val RUN_COMMAND = "kdeconnect.runcommand"
    const val RUN_COMMAND_REQUEST = "kdeconnect.runcommand.request"
    const val MPRIS = "kdeconnect.mpris"
    const val MPRIS_REQUEST = "kdeconnect.mpris.request"
    const val SFTP = "kdeconnect.sftp"
    const val SFTP_REQUEST = "kdeconnect.sftp.request"

    /** Flux extension: this phone opens a listener that the computer connects to. */
    const val FLUX_TUNNEL = "flux.tunnel"

    /** Flux extension: this phone streams its camera to the computer as a virtual webcam. */
    const val FLUX_WEBCAM = "flux.webcam"

    /** Flux extension: this phone streams its microphone to the computer as a virtual source. */
    const val FLUX_MIC = "flux.mic"

    /** Flux extension: this phone streams its screen to a window on the computer. */
    const val FLUX_SCREEN = "flux.screen"
}

/** Packet types that the phone accepts. */
val INCOMING = listOf(
    Types.PING, Types.BATTERY, Types.BATTERY_REQUEST, Types.CLIPBOARD, Types.CLIPBOARD_CONNECT,
    Types.SHARE, Types.SHARE_UPDATE, Types.NOTIFICATION_REQUEST, Types.NOTIFICATION_REPLY,
    Types.NOTIFICATION_ACTION, Types.FIND_MY_PHONE, Types.RUN_COMMAND, Types.MPRIS,
    Types.SFTP, Types.FLUX_TUNNEL, Types.FLUX_WEBCAM,
    Types.FLUX_MIC, Types.FLUX_SCREEN,
)

/** Packet types that the phone sends. */
val OUTGOING = listOf(
    Types.PING, Types.BATTERY, Types.CLIPBOARD, Types.CLIPBOARD_CONNECT, Types.SHARE,
    Types.SHARE_UPDATE, Types.NOTIFICATION, Types.FIND_MY_PHONE, Types.RUN_COMMAND_REQUEST,
    Types.MPRIS_REQUEST, Types.SFTP_REQUEST, Types.FLUX_TUNNEL, Types.FLUX_WEBCAM,
    Types.FLUX_MIC, Types.FLUX_SCREEN,
)

/** The body of a kdeconnect.identity packet. */
data class Identity(
    val deviceId: String,
    val deviceName: String,
    val deviceType: String,
    val protocolVersion: Int,
    val incoming: List<String>,
    val outgoing: List<String>,
    val tcpPort: Int = 0,
) {
    /**
     * Returns the identity packet. Only the UDP broadcast carries [tcpPort].
     * The plain-text line on a new TCP connection also names the device that
     * it answers with [target].
     */
    fun toPacket(withPort: Boolean = false, target: Identity? = null): Packet {
        val fields = mutableListOf<Pair<String, Any?>>(
            "deviceId" to deviceId,
            "deviceName" to deviceName,
            "deviceType" to deviceType,
            "protocolVersion" to protocolVersion,
            "incomingCapabilities" to incoming,
            "outgoingCapabilities" to outgoing,
        )
        if (withPort && tcpPort > 0) fields += "tcpPort" to tcpPort
        if (target != null) {
            fields += "targetDeviceId" to target.deviceId
            fields += "targetProtocolVersion" to target.protocolVersion
        }
        return Packet(Types.IDENTITY, bodyOf(*fields.toTypedArray()), id = System.currentTimeMillis())
    }

    /** True when the peer is an Omarchy desktop that runs fluxd. fluxd accepts flux.tunnel. */
    val isFlux: Boolean get() = Types.FLUX_TUNNEL in incoming

    companion object {
        fun from(p: Packet): Identity? {
            if (p.type != Types.IDENTITY) return null
            val id = p.string("deviceId") ?: return null
            if (!validDeviceId(id)) return null
            return Identity(
                deviceId = id,
                deviceName = cleanName(p.string("deviceName") ?: "unnamed"),
                deviceType = p.string("deviceType") ?: "desktop",
                protocolVersion = p.int("protocolVersion") ?: 7,
                incoming = p.strings("incomingCapabilities"),
                outgoing = p.strings("outgoingCapabilities"),
                tcpPort = p.int("tcpPort") ?: 0,
            )
        }

        fun self(deviceId: String, name: String, tcpPort: Int) = Identity(
            deviceId, cleanName(name), "phone", PROTOCOL_VERSION, INCOMING, OUTGOING, tcpPort,
        )
    }
}

private val deviceIdRegex = Regex("^[a-zA-Z0-9_-]{32,38}$")
private val invalidNameChars = Regex("[\"',;:.!?()\\[\\]<>]")

/** Reports whether the ID has the KDE Connect device ID format. */
fun validDeviceId(id: String): Boolean = deviceIdRegex.matches(id)

/**
 * Removes the characters that KDE Connect does not allow in a device name and
 * limits the name to 32 characters.
 */
fun cleanName(name: String): String {
    val cleaned = invalidNameChars.replace(name, "").trim()
    val limited = if (cleaned.codePointCount(0, cleaned.length) > 32) {
        cleaned.substring(0, cleaned.offsetByCodePoints(0, 32))
    } else cleaned
    return limited.ifEmpty { "Android" }
}
