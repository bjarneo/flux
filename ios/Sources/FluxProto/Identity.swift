import Foundation

/// The body of a `kdeconnect.identity` packet.
/// Mirrors `internal/proto/identity.go` and Android `protocol/Identity.kt`.
public struct Identity: Sendable, Equatable {
    public var deviceId: String
    public var deviceName: String
    public var deviceType: String
    public var protocolVersion: Int
    public var incoming: [String]
    public var outgoing: [String]
    public var tcpPort: Int
    public var targetDeviceId: String?
    /// Accepts number or numeric string on decode (Android sends a string).
    public var targetProtocolVersion: Int?

    public init(
        deviceId: String,
        deviceName: String,
        deviceType: String,
        protocolVersion: Int = FluxProto.protocolVersion,
        incoming: [String] = incomingCapabilities,
        outgoing: [String] = outgoingCapabilities,
        tcpPort: Int = 0,
        targetDeviceId: String? = nil,
        targetProtocolVersion: Int? = nil
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.protocolVersion = protocolVersion
        self.incoming = incoming
        self.outgoing = outgoing
        self.tcpPort = tcpPort
        self.targetDeviceId = targetDeviceId
        self.targetProtocolVersion = targetProtocolVersion
    }

    /// This phone's identity.
    public static func phone(deviceId: String, name: String, tcpPort: Int) -> Identity {
        Identity(deviceId: deviceId, deviceName: cleanName(name), deviceType: "phone", incoming: incomingCapabilities, outgoing: outgoingCapabilities, tcpPort: tcpPort)
    }

    /// Returns the identity packet. Only the UDP broadcast carries `tcpPort`.
    /// The plain-text line on a new TCP connection also names the device it
    /// answers with `target`.
    public func toPacket(withPort: Bool = false, target: Identity? = nil) -> Packet {
        var body: [String: JSONValue] = [
            "deviceId": .string(deviceId),
            "deviceName": .string(deviceName),
            "deviceType": .string(deviceType),
            "protocolVersion": .integer(Int64(protocolVersion)),
            "incomingCapabilities": .array(incoming.map { .string($0) }),
            "outgoingCapabilities": .array(outgoing.map { .string($0) }),
        ]
        if withPort, tcpPort > 0 { body["tcpPort"] = .integer(Int64(tcpPort)) }
        if let target {
            body["targetDeviceId"] = .string(target.deviceId)
            body["targetProtocolVersion"] = .integer(Int64(target.protocolVersion))
        }
        return Packet(type: PacketType.identity, body: body)
    }

    public static func from(_ p: Packet) -> Identity? {
        guard p.type == PacketType.identity else { return nil }
        guard let id = p.string("deviceId"), validDeviceId(id) else { return nil }
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

    /// True when the peer is a Flux desktop (`fluxd` accepts `flux.tunnel`).
    public var isFlux: Bool { incoming.contains(PacketType.fluxTunnel) }
}

// MARK: - Validation (byte-compatible with Go + Kotlin)

private let deviceIdPattern = "^[a-zA-Z0-9_-]{32,38}$"

/// Reports whether the ID has the KDE Connect device ID format.
public func validDeviceId(_ id: String) -> Bool {
    id.range(of: deviceIdPattern, options: .regularExpression) != nil
}

private let invalidNameChars = CharacterSet(charactersIn: "\"',;:.!?()[]<>")

/// Removes the characters KDE Connect forbids in a device name and limits
/// the name to 32 characters. Matches Go `CleanName` (runes) and Kotlin
/// `cleanName` (code points); Swift counts `Character` (grapheme clusters),
/// which agrees for all names without multi-scalar graphemes.
public func cleanName(_ name: String) -> String {
    let stripped = name.components(separatedBy: invalidNameChars).joined()
    var cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.count > 32 {
        cleaned = String(cleaned.prefix(32)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return cleaned.isEmpty ? "iPhone" : cleaned
}
