import Foundation

/// The protocol version that Flux speaks.
public let protocolVersion = 8

/// One Flux network packet. On the wire, a packet is one JSON object
/// followed by a newline.
public struct Packet: Sendable, Equatable {
    public var type: String
    public var body: [String: JSONValue]
    public var id: Int64
    public var payloadSize: Int64
    public var payloadPort: Int
    /// The token of a tunnel payload. This device listens, and the computer
    /// connects.
    public var payloadTunnel: String?

    public init(
        _ type: String,
        _ body: [String: Any?] = [:],
        id: Int64 = Packet.now(),
        payloadSize: Int64 = 0,
        payloadPort: Int = 0,
        payloadTunnel: String? = nil
    ) {
        self.type = type
        self.body = body.mapValues { JSONValue($0) }
        self.id = id
        self.payloadSize = payloadSize
        self.payloadPort = payloadPort
        self.payloadTunnel = payloadTunnel
    }

    public init(type: String, json body: [String: JSONValue], id: Int64 = Packet.now(), payloadSize: Int64 = 0, payloadPort: Int = 0, payloadTunnel: String? = nil) {
        self.type = type
        self.body = body
        self.id = id
        self.payloadSize = payloadSize
        self.payloadPort = payloadPort
        self.payloadTunnel = payloadTunnel
    }

    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    public var hasPayload: Bool { payloadSize != 0 && (payloadPort > 0 || payloadTunnel != nil) }

    /// Returns the packet as one line with a trailing newline.
    public func serialize() -> Data {
        var obj: [String: JSONValue] = ["id": .int(id), "type": .string(type), "body": .object(body)]
        if payloadSize != 0 && payloadPort > 0 {
            obj["payloadSize"] = .int(payloadSize)
            obj["payloadTransferInfo"] = .object(["port": .int(Int64(payloadPort))])
        } else if payloadSize != 0, let tunnel = payloadTunnel {
            obj["payloadSize"] = .int(payloadSize)
            obj["payloadTransferInfo"] = .object(["tunnel": .string(tunnel)])
        }
        var data = JSONValue.object(obj).serialized()
        data.append(0x0A)
        return data
    }

    /// Parses one packet line. It returns nil for a line that is not a packet.
    public static func parse(_ line: Data) -> Packet? {
        guard case .object(let obj)? = JSONValue.parse(line), case .string(let type)? = obj["type"], !type.isEmpty else { return nil }
        let id = obj["id"]?.int64 ?? 0
        let body = obj["body"]?.object ?? [:]
        let size = obj["payloadSize"]?.int64 ?? 0
        let info = obj["payloadTransferInfo"]?.object
        let port = info?["port"]?.int ?? 0
        let tunnel = info?["tunnel"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return Packet(type: type, json: body, id: id, payloadSize: size, payloadPort: port, payloadTunnel: port > 0 ? nil : tunnel)
    }

    public static func parse(_ line: String) -> Packet? { parse(Data(line.utf8)) }

    public func string(_ key: String) -> String? {
        if case .string(let s)? = body[key] { return s }
        return nil
    }
    public func bool(_ key: String) -> Bool? { body[key]?.bool }
    public func int(_ key: String) -> Int? { body[key]?.int }
    public func long(_ key: String) -> Int64? { body[key]?.int64 }
    public func double(_ key: String) -> Double? { body[key]?.double }
    public func has(_ key: String) -> Bool { body[key] != nil }
    public func object(_ key: String) -> [String: JSONValue]? { body[key]?.object }
    public func array(_ key: String) -> [JSONValue]? { body[key]?.array }
    public func strings(_ key: String) -> [String] { body[key]?.strings ?? [] }
}
