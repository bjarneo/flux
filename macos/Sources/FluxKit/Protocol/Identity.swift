import Foundation

/// The largest identity line that Flux sends or reads.
public let maxIdentityLine = 8192

/// Packet types that Flux uses.
public enum PacketType {
    public static let identity = "flux.identity"
    public static let pair = "flux.pair"
    public static let ping = "flux.ping"
    public static let battery = "flux.battery"
    public static let clipboard = "flux.clipboard"
    public static let clipboardConnect = "flux.clipboard.connect"
    public static let share = "flux.share.request"
    public static let shareUpdate = "flux.share.request.update"
    public static let notification = "flux.notification"
    public static let notificationRequest = "flux.notification.request"
    public static let notificationReply = "flux.notification.reply"
    public static let notificationAction = "flux.notification.action"
    public static let runCommand = "flux.runcommand"
    public static let runCommandRequest = "flux.runcommand.request"
    public static let mpris = "flux.mpris"
    public static let mprisRequest = "flux.mpris.request"
    public static let sftp = "flux.sftp"
    public static let sftpRequest = "flux.sftp.request"
    /// The computer asks this device to ring, so that the user finds it.
    public static let findMyPhone = "flux.findmyphone.request"
    /// Moves the pointer, clicks, scrolls, and types on the computer. This Mac
    /// sends it. docs/remote-input.md describes the body.
    public static let mousepadRequest = "flux.mousepad.request"

    /// This device opens a listener that the computer connects to.
    public static let fluxTunnel = "flux.tunnel"
    /// This device streams its camera to the computer as a virtual webcam.
    public static let fluxWebcam = "flux.webcam"
    /// The Do Not Disturb state, {"on": bool}, after a local change. Both sides send it.
    public static let fluxDnd = "flux.dnd"
    /// This device streams its microphone to the computer as a virtual source.
    public static let fluxMic = "flux.mic"
    /// The computer sends its herdr agents, and this device asks for their output and answers them. Both sides send it.
    public static let fluxHerdr = "flux.herdr"
    /// This device streams its screen to a window on the computer.
    public static let fluxScreen = "flux.screen"
    /// The computer tells whether it accepts remote input and
    /// whether it shows its screen, {"enabled": bool, "desktop": bool}.
    public static let fluxInput = "flux.input"
    /// The computer streams its screen to a window on this device.
    public static let fluxDesktop = "flux.desktop"
    /// The computer sends its Hyprland key bindings and
    /// workspaces, and runs them for this device. Both sides send it.
    public static let fluxShortcuts = "flux.shortcuts"
    /// The computer asks this device to approve sudo with a fingerprint.
    public static let fluxApprove = "flux.approve"
    /// An image that was copied, as the payload, with
    /// {"mime": type}. Both sides send it.
    public static let fluxClipboardImage = "flux.clipboard.image"
    /// The computer sends its active Omarchy theme. docs/omarchy.md,
    /// section "Theme packet", describes the body.
    public static let fluxTheme = "flux.theme"
    /// The computer asks this device to start its webcam or its
    /// microphone, {"kind": "webcam"} or {"kind": "mic"}. The packet only
    /// asks. The stream starts only after a tap of the user, see
    /// `StreamRequestPlugin`.
    public static let fluxStreamRequest = "flux.stream.request"
}

/// The body of a flux.identity packet.
public struct Identity: Sendable, Equatable {
    public var deviceId: String
    public var deviceName: String
    public var deviceType: String
    public var protocolVersion: Int
    public var incoming: [String]
    public var outgoing: [String]
    public var tcpPort: Int
    /// The Flux program of the device and its version: "macos" or "ios"
    /// and the app version for this device, "fluxd" for a computer. An
    /// earlier Flux sends neither.
    public var app: String
    public var appVersion: String

    public init(deviceId: String, deviceName: String, deviceType: String, protocolVersion: Int, incoming: [String], outgoing: [String], tcpPort: Int = 0, app: String = "", appVersion: String = "") {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.protocolVersion = protocolVersion
        self.incoming = incoming
        self.outgoing = outgoing
        self.tcpPort = tcpPort
        self.app = app
        self.appVersion = appVersion
    }

    /// Returns the identity packet. Only the UDP broadcast carries tcpPort.
    /// The plain-text line on a new TCP connection also names the device that
    /// it answers with target.
    public func packet(withPort: Bool = false, target: Identity? = nil) -> Packet {
        var body: [String: Any?] = [
            "deviceId": deviceId,
            "deviceName": deviceName,
            "deviceType": deviceType,
            "protocolVersion": protocolVersion,
            "incomingCapabilities": incoming,
            "outgoingCapabilities": outgoing,
        ]
        if withPort && tcpPort > 0 { body["tcpPort"] = tcpPort }
        if !app.isEmpty { body["app"] = app }
        if !appVersion.isEmpty { body["appVersion"] = appVersion }
        if let target {
            body["targetDeviceId"] = target.deviceId
            body["targetProtocolVersion"] = target.protocolVersion
        }
        return Packet(PacketType.identity, body)
    }

    /// True when the peer is an Omarchy computer that runs fluxd. fluxd is a
    /// desktop or laptop that accepts flux.tunnel. Flux for Android also
    /// accepts flux.tunnel, but it is a phone or tablet. The Mac is a remote
    /// for Omarchy, so it connects and pairs only with these peers.
    public var isFlux: Bool {
        (deviceType == "desktop" || deviceType == "laptop") && incoming.contains(PacketType.fluxTunnel)
    }

    /// Parses an identity packet. It returns nil for a packet without a
    /// valid device ID or without a protocol version.
    public static func from(_ p: Packet) -> Identity? {
        guard p.type == PacketType.identity, let id = p.string("deviceId"), validDeviceId(id),
              let version = p.int("protocolVersion") else { return nil }
        return Identity(
            deviceId: id,
            deviceName: cleanName(p.string("deviceName") ?? "unnamed"),
            deviceType: p.string("deviceType") ?? "desktop",
            protocolVersion: version,
            incoming: p.strings("incomingCapabilities"),
            outgoing: p.strings("outgoingCapabilities"),
            tcpPort: p.int("tcpPort") ?? 0,
            app: p.string("app") ?? "",
            appVersion: p.string("appVersion") ?? ""
        )
    }
}

/// Reports whether the ID has the Flux device ID format.
public func validDeviceId(_ id: String) -> Bool {
    guard (32...38).contains(id.count) else { return false }
    return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
}

private let invalidNameChars = Set("\"',;:.!?()[]<>")

/// Removes the characters that Flux does not allow in a device name and
/// limits the name to 32 characters.
public func cleanName(_ name: String, fallback: String = "Mac") -> String {
    let cleaned = String(name.filter { !invalidNameChars.contains($0) }).trimmingCharacters(in: .whitespaces)
    let limited = String(cleaned.unicodeScalars.prefix(32).map(Character.init)).trimmingCharacters(in: .whitespaces)
    return limited.isEmpty ? fallback : limited
}
