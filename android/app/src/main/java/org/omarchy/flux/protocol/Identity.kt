package org.omarchy.flux.protocol

import org.omarchy.flux.BuildConfig

/** The largest identity line that Flux sends or reads. */
const val MAX_IDENTITY_LINE = 8192

/** Packet types that the Flux phone app uses. */
object Types {
    const val IDENTITY = "flux.identity"
    const val PAIR = "flux.pair"
    const val PING = "flux.ping"
    const val BATTERY = "flux.battery"
    const val CLIPBOARD = "flux.clipboard"
    const val CLIPBOARD_CONNECT = "flux.clipboard.connect"
    const val SHARE = "flux.share.request"
    const val SHARE_UPDATE = "flux.share.request.update"
    const val NOTIFICATION = "flux.notification"
    const val NOTIFICATION_REQUEST = "flux.notification.request"
    const val NOTIFICATION_REPLY = "flux.notification.reply"
    const val NOTIFICATION_ACTION = "flux.notification.action"
    const val FIND_MY_PHONE = "flux.findmyphone.request"
    const val RUN_COMMAND = "flux.runcommand"
    const val RUN_COMMAND_REQUEST = "flux.runcommand.request"
    const val MPRIS = "flux.mpris"
    const val MPRIS_REQUEST = "flux.mpris.request"
    const val SFTP = "flux.sftp"
    const val SFTP_REQUEST = "flux.sftp.request"
    const val TELEPHONY = "flux.telephony"
    const val SMS_MESSAGES = "flux.sms.messages"
    const val SMS_REQUEST = "flux.sms.request"
    const val SMS_REQUEST_CONVERSATIONS = "flux.sms.request_conversations"
    const val SMS_REQUEST_CONVERSATION = "flux.sms.request_conversation"
    const val MOUSEPAD_REQUEST = "flux.mousepad.request"

    /** This phone opens a listener that the computer connects to. */
    const val FLUX_TUNNEL = "flux.tunnel"

    /** This phone streams its camera to the computer as a virtual webcam. */
    const val FLUX_WEBCAM = "flux.webcam"

    /** The Do Not Disturb state, {"on": bool}, after a local change. Both sides send it. */
    const val FLUX_DND = "flux.dnd"

    /** This phone streams its microphone to the computer as a virtual source. */
    const val FLUX_MIC = "flux.mic"

    /** This phone streams its screen to a window on the computer. */
    const val FLUX_SCREEN = "flux.screen"

    /** The computer asks this phone to approve sudo with a fingerprint. */
    const val FLUX_APPROVE = "flux.approve"

    /** The computer sends its herdr agents, and this phone asks for their output. Both sides send it. */
    const val FLUX_HERDR = "flux.herdr"

    /** An image that one side copied, as the payload, with {"mime": "image/png"}. Both sides send it. */
    const val FLUX_CLIPBOARD_IMAGE = "flux.clipboard.image"

    /**
     * The computer tells whether it accepts remote input and
     * whether it shows its screen, {"enabled": bool, "desktop": bool}.
     */
    const val FLUX_INPUT = "flux.input"

    /** The computer streams its screen to this phone. */
    const val FLUX_DESKTOP = "flux.desktop"

    /** The computer sends its Hyprland key bindings and workspaces, and runs them for this phone. Both sides send it. */
    const val FLUX_SHORTCUTS = "flux.shortcuts"

    /**
     * The computer sends its active Omarchy theme, {"name", "mode", "colors":
     * {key: "#rrggbb"}, "border": {"colors": ["#rrggbbaa"], "angle": deg}},
     * when the phone connects and when the theme changes.
     */
    const val FLUX_THEME = "flux.theme"
}

/** Packet types that the phone accepts. */
val INCOMING = listOf(
    Types.PING, Types.BATTERY, Types.CLIPBOARD, Types.CLIPBOARD_CONNECT,
    Types.SHARE, Types.SHARE_UPDATE, Types.NOTIFICATION, Types.NOTIFICATION_REQUEST, Types.NOTIFICATION_REPLY,
    Types.NOTIFICATION_ACTION, Types.FIND_MY_PHONE, Types.RUN_COMMAND, Types.MPRIS,
    Types.SFTP, Types.FLUX_TUNNEL, Types.FLUX_WEBCAM, Types.FLUX_DND,
    Types.FLUX_MIC, Types.FLUX_SCREEN, Types.FLUX_APPROVE, Types.FLUX_HERDR, Types.FLUX_INPUT,
    Types.FLUX_DESKTOP, Types.FLUX_SHORTCUTS, Types.FLUX_THEME,
)

/** Packet types that the phone sends. */
val OUTGOING = listOf(
    Types.PING, Types.BATTERY, Types.CLIPBOARD, Types.CLIPBOARD_CONNECT, Types.SHARE,
    Types.SHARE_UPDATE, Types.NOTIFICATION, Types.RUN_COMMAND_REQUEST, Types.MPRIS_REQUEST,
    Types.SFTP_REQUEST, Types.TELEPHONY, Types.FLUX_TUNNEL, Types.FLUX_WEBCAM, Types.FLUX_DND,
    Types.FLUX_MIC, Types.FLUX_SCREEN, Types.FLUX_APPROVE, Types.FLUX_HERDR, Types.FLUX_CLIPBOARD_IMAGE,
    Types.MOUSEPAD_REQUEST, Types.FLUX_DESKTOP, Types.FLUX_SHORTCUTS,
)

/**
 * The phone accepts clipboard images only while Sync clipboard is on, so
 * that a computer does not send an image that the phone drops.
 */
val CLIPBOARD_IMAGE_INCOMING = listOf(Types.FLUX_CLIPBOARD_IMAGE)

/**
 * The SMS packet types. The phone lists them only while text messages are
 * on and the phone allows SMS access, so that a computer shows its
 * Messages page only when the phone can answer.
 */
val SMS_INCOMING = listOf(Types.SMS_REQUEST, Types.SMS_REQUEST_CONVERSATIONS, Types.SMS_REQUEST_CONVERSATION)
val SMS_OUTGOING = listOf(Types.SMS_MESSAGES)

/** The body of a flux.identity packet. */
data class Identity(
    val deviceId: String,
    val deviceName: String,
    val deviceType: String,
    val protocolVersion: Int,
    val incoming: List<String>,
    val outgoing: List<String>,
    val tcpPort: Int = 0,
    /**
     * The Flux program of the device and its version: "android" and
     * BuildConfig.VERSION_NAME for this phone, "fluxd" for a computer. A
     * debug build is "android-debug", because a release APK with another
     * signing key cannot update it, so fluxd offers it no update. An
     * earlier Flux sends neither.
     */
    val app: String = "",
    val appVersion: String = "",
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
        if (app.isNotEmpty()) fields += "app" to app
        if (appVersion.isNotEmpty()) fields += "appVersion" to appVersion
        if (target != null) {
            fields += "targetDeviceId" to target.deviceId
            fields += "targetProtocolVersion" to target.protocolVersion
        }
        return Packet(Types.IDENTITY, bodyOf(*fields.toTypedArray()), id = System.currentTimeMillis())
    }

    companion object {
        /** Reads an identity packet. It returns null without a valid device ID or a protocol version. */
        fun from(p: Packet): Identity? {
            if (p.type != Types.IDENTITY) return null
            val id = p.string("deviceId") ?: return null
            if (!validDeviceId(id)) return null
            val version = p.int("protocolVersion") ?: return null
            return Identity(
                deviceId = id,
                deviceName = cleanName(p.string("deviceName") ?: "unnamed"),
                deviceType = p.string("deviceType") ?: "desktop",
                protocolVersion = version,
                incoming = p.strings("incomingCapabilities"),
                outgoing = p.strings("outgoingCapabilities"),
                tcpPort = p.int("tcpPort") ?: 0,
                app = p.string("app") ?: "",
                appVersion = p.string("appVersion") ?: "",
            )
        }

        /**
         * The identity of this phone. [sms] adds the SMS packet types, and
         * [clipboardImages] adds the incoming clipboard images.
         */
        fun self(deviceId: String, name: String, tcpPort: Int, sms: Boolean = false, clipboardImages: Boolean = false) = Identity(
            deviceId, cleanName(name), "phone", PROTOCOL_VERSION,
            INCOMING + (if (sms) SMS_INCOMING else emptyList()) + (if (clipboardImages) CLIPBOARD_IMAGE_INCOMING else emptyList()),
            if (sms) OUTGOING + SMS_OUTGOING else OUTGOING,
            tcpPort,
            app = if (BuildConfig.DEBUG) "android-debug" else "android",
            appVersion = BuildConfig.VERSION_NAME,
        )
    }
}

private val deviceIdRegex = Regex("^[a-zA-Z0-9_-]{32,38}$")
private val invalidNameChars = Regex("[\"',;:.!?()\\[\\]<>]")

/** Reports whether the ID has the Flux device ID format. */
fun validDeviceId(id: String): Boolean = deviceIdRegex.matches(id)

/**
 * Removes the characters that Flux does not allow in a device name and
 * limits the name to 32 characters.
 */
fun cleanName(name: String): String {
    val cleaned = invalidNameChars.replace(name, "").trim()
    val limited = if (cleaned.codePointCount(0, cleaned.length) > 32) {
        cleaned.substring(0, cleaned.offsetByCodePoints(0, 32))
    } else cleaned
    return limited.ifEmpty { "Android" }
}
