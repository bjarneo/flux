import Foundation

/// One KDE Connect network packet. On the wire, a packet is one JSON object
/// followed by a newline. Mirrors `internal/proto/packet.go` and
/// Android `protocol/Packet.kt`.
public struct Packet: Sendable, Equatable {
    /// Millisecond timestamp. Accepts number or numeric string on decode.
    public var id: Int64
    public var type: String
    public var body: [String: JSONValue]
    public var payloadSize: Int64
    public var payloadPort: Int
    /// Flux extension: token of a tunnel payload. The computer cannot accept
    /// connections, so the phone listens and the computer connects.
    public var payloadTunnel: String?

    public init(
        type: String,
        body: [String: JSONValue] = [:],
        id: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        payloadSize: Int64 = 0,
        payloadPort: Int = 0,
        payloadTunnel: String? = nil
    ) {
        self.id = id
        self.type = type
        self.body = body
        self.payloadSize = payloadSize
        self.payloadPort = payloadPort
        self.payloadTunnel = payloadTunnel
    }

    /// Builds a packet from simple Swift values (mirrors Kotlin `Packet.of`).
    public static func of(_ type: String, id: Int64? = nil, _ fields: (String, Any?)...) -> Packet {
        var body: [String: JSONValue] = [:]
        for (k, v) in fields { body[k] = JSONValue.make(v) }
        return Packet(type: type, body: body, id: id ?? Int64(Date().timeIntervalSince1970 * 1000))
    }

    public var hasPayload: Bool {
        payloadSize != 0 && (payloadPort > 0 || payloadTunnel != nil)
    }

    // MARK: - Body helpers (mirror Kotlin Packet.string/bool/int/long/double)

    public func string(_ key: String) -> String? { body[key]?.string }
    public func bool(_ key: String) -> Bool? { body[key]?.bool }
    public func int(_ key: String) -> Int? { body[key]?.int }
    public func long(_ key: String) -> Int64? { body[key]?.long }
    public func double(_ key: String) -> Double? { body[key]?.double }
    public func has(_ key: String) -> Bool { body[key] != nil }

    public func obj(_ key: String) -> [String: JSONValue]? {
        if case .object(let o) = body[key] { return o }
        return nil
    }

    public func array(_ key: String) -> [JSONValue]? {
        if case .array(let a) = body[key] { return a }
        return nil
    }

    public func strings(_ key: String) -> [String] {
        array(key)?.compactMap(\.string) ?? []
    }

    // MARK: - Wire format

    /// Returns the packet as one line with a trailing newline.
    public func serialize() throws -> Data {
        var dict: [String: JSONValue] = [
            "id": .integer(id),
            "type": .string(type),
            "body": .object(body),
        ]
        if payloadSize != 0, payloadPort > 0 {
            dict["payloadSize"] = .integer(payloadSize)
            dict["payloadTransferInfo"] = .object(["port": .integer(Int64(payloadPort))])
        } else if payloadSize != 0, let tunnel = payloadTunnel {
            dict["payloadSize"] = .integer(payloadSize)
            dict["payloadTransferInfo"] = .object(["tunnel": .string(tunnel)])
        }
        let data = try JSONEncoder().encode(JSONValue.object(dict))
        return data + Data([0x0A])
    }

    /// Parses one packet line. Returns nil for a line that is not a packet.
    public static func parse(_ line: Data) -> Packet? {
        // Enforce the 16 MiB cap like Go `readLine`.
        guard line.count <= FluxProto.maxPacketSize else { return nil }
        let trimmed = line.trimmingNewlines()
        guard !trimmed.isEmpty,
              let value = try? JSONDecoder().decode(JSONValue.self, from: trimmed),
              case .object(let obj) = value,
              case .string(let type) = obj["type"]
        else { return nil }

        let id: Int64 = {
            switch obj["id"] {
            case .integer(let i): return i
            case .double(let d): return Int64(d)
            case .string(let s):
                if let i = Int64(s) { return i }
                if let d = Double(s) { return Int64(d) }
                return 0
            default: return 0
            }
        }()
        let body: [String: JSONValue] = {
            if case .object(let o) = obj["body"] { return o }
            return [:]
        }()
        let size: Int64 = {
            switch obj["payloadSize"] {
            case .integer(let i): return i
            case .double(let d): return Int64(d)
            default: return 0
            }
        }()
        var port = 0
        var tunnel: String?
        if case .object(let info) = obj["payloadTransferInfo"] {
            switch info["port"] {
            case .integer(let i): port = Int(i)
            case .string(let s): port = Int(s) ?? 0
            case .double(let d): port = Int(d)
            default: break
            }
            if case .string(let t) = info["tunnel"], !t.isEmpty { tunnel = t }
        }
        if port > 0 { tunnel = nil }
        return Packet(type: type, body: body, id: id, payloadSize: size, payloadPort: port, payloadTunnel: tunnel)
    }

    public static func parse(_ line: String) -> Packet? {
        parse(Data(line.utf8))
    }
}

private extension Data {
    func trimmingNewlines() -> Data {
        var d = self
        while let last = d.last, last == 0x0A || last == 0x0D { d.removeLast() }
        while let first = d.first, first == 0x0A || first == 0x0D || first == 0x20 || first == 0x09 { d.removeFirst() }
        return d
    }
}
