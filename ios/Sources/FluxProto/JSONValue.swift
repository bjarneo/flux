import Foundation

/// A JSON value in a packet body. Packet bodies are arbitrary JSON objects;
/// this enum preserves them through a `Codable` round-trip.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .integer(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .integer(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// Convenience conversion from simple Swift values (mirrors Kotlin `toJson`).
    public static func make(_ v: Any?) -> JSONValue {
        switch v {
        case nil: return .null
        case let j as JSONValue: return j
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let i as Int: return .integer(Int64(i))
        case let i as Int64: return .integer(i)
        case let i as Int32: return .integer(Int64(i))
        case let d as Double: return .double(d)
        case let f as Float: return .double(Double(f))
        case let m as [String: Any?]: return .object(m.mapValues { make($0) })
        case let m as [String: Any]: return .object(m.mapValues { make($0) })
        case let a as [Any?]: return .array(a.map { make($0) })
        case let a as [Any]: return .array(a.map { make($0) })
        default: return .string(String(describing: v!))
        }
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s):
            switch s.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var int: Int? {
        switch self {
        case .integer(let i): return Int(i)
        case .double(let d): return Int(d)
        case .string(let s): return Int(s) ?? (Double(s).map(Int.init) ?? nil)
        default: return nil
        }
    }

    public var long: Int64? {
        switch self {
        case .integer(let i): return i
        case .double(let d): return Int64(d)
        case .string(let s): return Int64(s) ?? (Double(s).map(Int64.init) ?? nil)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }
}
