import Foundation
import FluxProto

/// Find-my-phone ring state. A request while ringing stops it, so the
/// desktop can silence a ring nobody can reach; a ring nobody stops ends
/// after 2 minutes. Mirrors Android `Ringer` (`MAX_RING_MS`, toggle in
/// `start`) and Go `handleFindMyPhone` (`time.AfterFunc(2*time.Minute)`).
public struct RingState: Sendable, Equatable {
    /// Longest a ring runs without a stop (ms).
    public static let maxRingMs: Int64 = 2 * 60 * 1000

    /// Who started the current ring, nil when silent.
    public var ringingFrom: String?
    /// When the current ring must stop (ms since epoch), nil when silent.
    public var stopAtMs: Int64?

    public init() {}

    public var ringing: Bool { ringingFrom != nil }

    /// Toggles the ring. Returns true when the phone now rings.
    public mutating func toggle(from: String, nowMs: Int64) -> Bool {
        if ringing {
            ringingFrom = nil
            stopAtMs = nil
            return false
        }
        ringingFrom = from
        stopAtMs = nowMs + Self.maxRingMs
        return true
    }

    /// Ends an expired ring. Returns the name that rang, nil when nothing
    /// changed. The caller stops the sound + clears the UI.
    public mutating func expire(nowMs: Int64) -> String? {
        guard let from = ringingFrom, let stopAt = stopAtMs, nowMs >= stopAt else { return nil }
        ringingFrom = nil
        stopAtMs = nil
        return from
    }
}
