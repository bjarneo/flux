import Foundation

/// `kdeconnect.pair` packet helpers and timestamp rules.
///
/// Mirrors `internal/core/pairing.go` (Go daemon) and Android
/// `core/Device.kt` pairing flow:
///
/// - Outgoing request: `{"pair": true, "timestamp": <unix seconds>}`.
/// - Accept: `{"pair": true}` (no timestamp).
/// - Reject / cancel / unpair: `{"pair": false}`.
/// - Protocol v8 requires a timestamp on incoming requests; the clock skew
///   must be within ±30 minutes (`maxClockSkew` / `MAX_TIMESTAMP_DIFFERENCE_SECONDS`).
/// - Protocol <8 has no timestamp; the verification key omits it.
public enum Pairing {
    /// How long an outgoing request stays open (Go `pairTimeout`, Android `OUTGOING_TIMEOUT_SECONDS`).
    public static let outgoingTimeout: TimeInterval = 30
    /// How long an incoming request stays open (Android `INCOMING_TIMEOUT_SECONDS`).
    public static let incomingTimeout: TimeInterval = 25
    /// Largest accepted difference between the pair timestamp and the local
    /// clock (Go `maxClockSkew`, Android `MAX_TIMESTAMP_DIFFERENCE_SECONDS`).
    public static let maxClockSkew: TimeInterval = 30 * 60

    /// Builds an outgoing pairing request for `timestamp`.
    public static func request(timestamp: Int64) -> Packet {
        Packet.of(PacketType.pair, ("pair", true), ("timestamp", timestamp))
    }

    /// Builds the accept packet (no timestamp).
    public static func accept() -> Packet {
        Packet.of(PacketType.pair, ("pair", true))
    }

    /// Builds the reject / cancel / unpair packet.
    public static func reject() -> Packet {
        Packet.of(PacketType.pair, ("pair", false))
    }

    /// One parsed `kdeconnect.pair` packet.
    public enum Message: Sendable, Equatable {
        /// `{"pair": true, "timestamp": ts}` — timestamp nil when absent.
        case request(timestamp: Int64?)
        case accept
        case reject
    }

    /// Parses a `kdeconnect.pair` packet. Returns nil for other types.
    public static func parse(_ p: Packet) -> Message? {
        guard p.type == PacketType.pair else { return nil }
        guard p.bool("pair") == true else { return .reject }
        if p.has("timestamp"), let ts = p.long("timestamp") {
            return .request(timestamp: ts)
        }
        if p.has("timestamp") {
            return .request(timestamp: nil)
        }
        // `{"pair": true}` without timestamp: an accept. Note: a v8 request
        // without timestamp is refused later by `validTimestamp`.
        return .accept
    }

    /// Validates an incoming request timestamp.
    ///
    /// - v8+: timestamp is required and must be within ±`maxClockSkew` of `now`.
    /// - v7 and older: no timestamp; always valid.
    public static func validTimestamp(_ timestamp: Int64?, protocolVersion: Int, now: Date = Date()) -> Bool {
        guard protocolVersion >= 8 else { return true }
        guard let timestamp else { return false }
        let skew = now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(timestamp)))
        return abs(skew) <= maxClockSkew
    }

    /// Returns the verification-key timestamp: the pairing timestamp for
    /// protocol v8+, otherwise 0 (key omits the timestamp).
    public static func keyTimestamp(pairTimestamp: Int64, protocolVersion: Int) -> Int64 {
        protocolVersion >= 8 ? pairTimestamp : 0
    }
}
