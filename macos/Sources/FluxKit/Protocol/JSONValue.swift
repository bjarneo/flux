import Foundation

/// A JSON value. Packet bodies use it so that unknown fields survive and
/// numbers keep their integer or floating form.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses JSON text. It returns nil for invalid JSON.
    public static func parse(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: any)
    }

    /// Converts a Foundation JSON object.
    init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                let d = n.doubleValue
                self = .double(d)
            } else {
                self = .int(n.int64Value)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.compactMap { JSONValue(any: $0) })
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, v) in o { if let j = JSONValue(any: v) { out[k] = j } }
            self = .object(out)
        default:
            return nil
        }
    }

    /// Converts a Swift value: nil, Bool, integers, floating point, String,
    /// arrays, dictionaries with String keys, or a JSONValue.
    public init(_ value: Any?) {
        switch value {
        case nil: self = .null
        case let j as JSONValue: self = j
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(Int64(i))
        case let i as Int32: self = .int(Int64(i))
        case let i as Int64: self = .int(i)
        case let i as UInt16: self = .int(Int64(i))
        case let i as UInt32: self = .int(Int64(i))
        case let d as Double: self = .double(d)
        case let f as Float: self = .double(Double(f))
        case let s as String: self = .string(s)
        case let a as [Any?]: self = .array(a.map { JSONValue($0) })
        case let o as [String: Any?]: self = .object(o.mapValues { JSONValue($0) })
        default: self = .string(String(describing: value!))
        }
    }

    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return NSNumber(value: i)
        case .double(let d): return NSNumber(value: d)
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }

    /// Returns compact JSON text.
    public func serialized() -> Data {
        (try? JSONSerialization.data(withJSONObject: foundation, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("null".utf8)
    }

    // MARK: Accessors that accept a number or a string for the same field.

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    public var int64: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.isFinite ? Int64(d) : nil
        case .string(let s): return Int64(s) ?? Double(s).flatMap { $0.isFinite ? Int64($0) : nil }
        default: return nil
        }
    }

    public var int: Int? { int64.flatMap { Int(exactly: $0) } }

    public var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true" ? true : s == "false" ? false : nil
        default: return nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var strings: [String] { array?.compactMap { $0.string } ?? [] }

    public subscript(key: String) -> JSONValue? { object?[key] }
}
