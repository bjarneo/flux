import Foundation

/// The largest identity line that Flux sends or reads.
public let maxIdentityLine = 8192

/// Packet types that Flux uses.
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
    public static let runCommand = "kdeconnect.runcommand"
    public static let runCommandRequest = "kdeconnect.runcommand.request"
    public static let mpris = "kdeconnect.mpris"
    public static let mprisRequest = "kdeconnect.mpris.request"
    public static let sftp = "kdeconnect.sftp"
    public static let sftpRequest = "kdeconnect.sftp.request"
    /// Moves the pointer, clicks, scrolls, and types on the computer. This Mac
    /// sends it. docs/remote-input.md describes the body.
    public static let mousepadRequest = "kdeconnect.mousepad.request"

    /// Flux extension: this device opens a listener that the computer connects to.
    public static let fluxTunnel = "flux.tunnel"
    /// Flux extension: this device streams its camera to the computer as a virtual webcam.
    public static let fluxWebcam = "flux.webcam"
    /// Flux extension: the Do Not Disturb state, {"on": bool}, after a local change. Both sides send it.
    public static let fluxDnd = "flux.dnd"
    /// Flux extension: this device streams its microphone to the computer as a virtual source.
    public static let fluxMic = "flux.mic"
    /// Flux extension: the computer sends its herdr agents, and this device asks for their output and answers them. Both sides send it.
    public static let fluxHerdr = "flux.herdr"
    /// Flux extension: this device streams its screen to a window on the computer.
    public static let fluxScreen = "flux.screen"
    /// Flux extension: the computer tells whether it accepts remote input and
    /// whether it shows its screen, {"enabled": bool, "desktop": bool}.
    public static let fluxInput = "flux.input"
    /// Flux extension: the computer streams its screen to a window on this device.
    public static let fluxDesktop = "flux.desktop"
    /// Flux extension: the computer sends its Hyprland key bindings and
    /// workspaces, and runs them for this device. Both sides send it.
    public static let fluxShortcuts = "flux.shortcuts"
    /// Flux extension: the computer asks this device to approve sudo with a fingerprint.
    public static let fluxApprove = "flux.approve"
}

/// The body of a kdeconnect.identity packet.
public struct Identity: Sendable, Equatable {
    public var deviceId: String
    public var deviceName: String
    public var deviceType: String
    public var protocolVersion: Int
    public var incoming: [String]
    public var outgoing: [String]
    public var tcpPort: Int

    public init(deviceId: String, deviceName: String, deviceType: String, protocolVersion: Int, incoming: [String], outgoing: [String], tcpPort: Int = 0) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.protocolVersion = protocolVersion
        self.incoming = incoming
        self.outgoing = outgoing
        self.tcpPort = tcpPort
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

    public static func from(_ p: Packet) -> Identity? {
        guard p.type == PacketType.identity, let id = p.string("deviceId"), validDeviceId(id) else { return nil }
        return Identity(
            deviceId: id,
            deviceName: cleanName(p.string("deviceName") ?? "unnamed"),
            deviceType: p.string("deviceType") ?? "desktop",
            protocolVersion: p.int("protocolVersion") ?? 7,
            incoming: p.strings("incomingCapabilities"),
            outgoing: p.strings("outgoingCapabilities"),
            tcpPort: p.int("tcpPort") ?? 0
        )
    }
}

/// Reports whether the ID has the KDE Connect device ID format.
public func validDeviceId(_ id: String) -> Bool {
    guard (32...38).contains(id.count) else { return false }
    return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
}

private let invalidNameChars = Set("\"',;:.!?()[]<>")

/// Removes the characters that KDE Connect does not allow in a device name and
/// limits the name to 32 characters.
public func cleanName(_ name: String, fallback: String = "Mac") -> String {
    let cleaned = String(name.filter { !invalidNameChars.contains($0) }).trimmingCharacters(in: .whitespaces)
    let limited = String(cleaned.unicodeScalars.prefix(32).map(Character.init)).trimmingCharacters(in: .whitespaces)
    return limited.isEmpty ? fallback : limited
}
