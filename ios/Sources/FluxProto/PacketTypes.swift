import Foundation

/// Packet types Flux uses. Mirrors `internal/proto/identity.go` and
/// Android `protocol/Identity.kt Types`.
public enum PacketType {
    public static let identity = "kdeconnect.identity"
    public static let pair = "kdeconnect.pair"
    public static let ping = "kdeconnect.ping"
    public static let battery = "kdeconnect.battery"
    public static let batteryRequest = "kdeconnect.battery.request"
    public static let clipboard = "kdeconnect.clipboard"
    public static let clipboardConnect = "kdeconnect.clipboard.connect"
    public static let share = "kdeconnect.share.request"
    public static let shareUpdate = "kdeconnect.share.request.update"
    public static let notification = "kdeconnect.notification"
    public static let notificationRequest = "kdeconnect.notification.request"
    public static let notificationReply = "kdeconnect.notification.reply"
    public static let notificationAction = "kdeconnect.notification.action"
    public static let findMyPhone = "kdeconnect.findmyphone.request"
    public static let runCommand = "kdeconnect.runcommand"
    public static let runCommandRequest = "kdeconnect.runcommand.request"
    public static let mpris = "kdeconnect.mpris"
    public static let mprisRequest = "kdeconnect.mpris.request"
    public static let sftp = "kdeconnect.sftp"
    public static let sftpRequest = "kdeconnect.sftp.request"
    public static let smsMessages = "kdeconnect.sms.messages"
    public static let smsRequest = "kdeconnect.sms.request"
    public static let smsConversations = "kdeconnect.sms.request_conversations"
    public static let smsConversation = "kdeconnect.sms.request_conversation"
    public static let connectivity = "kdeconnect.connectivity_report"
    public static let telephony = "kdeconnect.telephony"

    /// Flux extension: phone opens a listener the computer connects to.
    public static let fluxTunnel = "flux.tunnel"
    /// Flux extension: phone streams its camera as a virtual webcam.
    public static let fluxWebcam = "flux.webcam"
    /// Flux extension: Do Not Disturb state, `{"on": bool}`. Both sides send.
    public static let fluxDnd = "flux.dnd"
    /// Flux extension: phone streams its microphone as a virtual source.
    public static let fluxMic = "flux.mic"
    /// Flux extension: phone mirrors its screen to a desktop window.
    public static let fluxScreen = "flux.screen"
    /// Flux extension: computer asks the phone to approve sudo with biometrics.
    public static let fluxApprove = "flux.approve"
}

/// Packet types the iOS app accepts.
///
/// v1 proposal from `docs/ios-plan.md` §2.2: no `sms.messages` incoming
/// (iOS has no third-party SMS API). `sms.request` outgoing is also
/// omitted in v1; see `FluxFeatures` for the "Not supported on iOS" state.
///
/// M4 adds `mpris.request` incoming: `flux media *` sends it ungated
/// (Go `PhoneMediaAction` → `d.send`), and plan §4.6 requires desktop
/// pause/next to control iPhone playback (`NowPlayingBridge`). Android
/// does not advertise it (its `flux media` actions drop); iOS does.
public let incomingCapabilities: [String] = [
    PacketType.ping,
    PacketType.battery,
    PacketType.batteryRequest,
    PacketType.clipboard,
    PacketType.clipboardConnect,
    PacketType.share,
    PacketType.shareUpdate,
    PacketType.notification,
    PacketType.notificationRequest,
    PacketType.notificationReply,
    PacketType.notificationAction,
    PacketType.findMyPhone,
    PacketType.runCommand,
    PacketType.mpris,
    PacketType.mprisRequest,
    PacketType.sftp,
    PacketType.sftpRequest,
    PacketType.fluxTunnel,
    PacketType.fluxWebcam,
    PacketType.fluxDnd,
    PacketType.fluxMic,
    PacketType.fluxScreen,
    PacketType.fluxApprove,
]

/// Packet types the iOS app sends.
public let outgoingCapabilities: [String] = [
    PacketType.ping,
    PacketType.battery,
    PacketType.clipboard,
    PacketType.clipboardConnect,
    PacketType.share,
    PacketType.shareUpdate,
    PacketType.notification,
    PacketType.findMyPhone,
    PacketType.runCommandRequest,
    PacketType.mprisRequest,
    PacketType.sftpRequest,
    PacketType.telephony,
    PacketType.fluxTunnel,
    PacketType.fluxWebcam,
    PacketType.fluxDnd,
    PacketType.fluxMic,
    PacketType.fluxScreen,
    PacketType.fluxApprove,
]
