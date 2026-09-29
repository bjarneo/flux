import Foundation

/// M4 calls + Focus packets: `kdeconnect.telephony` events and `flux.dnd`
/// state.
///
/// Sources of truth: `internal/core/telephony.go` (`callBody`, `caller`,
/// `handleTelephony`, `flexString`), `internal/core/dnd.go` (`dndGuard`,
/// `handleDnd`), Android `core/Calls.kt` (`CallTracker`, `CallPackets`),
/// `core/DndSync.kt` + `core/DndGuard.kt`, `service/CallMonitor.kt`.
///
/// Direction notes (do not "improve" the wire):
/// - Phone→desktop `kdeconnect.telephony` reports ringing/talking/missed
///   calls. The desktop pauses its players while the phone rings or talks
///   (`pause_media_on_call`) and notifies missed calls — no iOS work beyond
///   sending the events.
/// - `isCancel` ends the call: Go `flexString.bool` accepts boolean `true`,
///   number `1`, and the strings `"true"`/`"1"` (Android always sends a
///   boolean; tolerate all four like Go).
/// - The caller name is the contact name, else the number, else
///   `"Unknown caller"` (exact string, Go `caller` + Android `UNKNOWN`).
///   iOS provides no call number to third parties (`CXCall` carries none),
///   so the bridge always sends the fallback; the builder still takes a
///   number + name for vectors and any future source.
/// - `flux.dnd` carries `{"on": bool}` both ways. The phone sends its Focus
///   boolean on change only (guarded); desktop→phone arrivals render a
///   banner — iOS has no API to set Focus, so they are never applied.

// MARK: - Call tracking (port of Android CallTracker)

/// The phone line, as the system reports it.
public enum LineState: Sendable, Equatable {
    case idle
    case ringing
    case offHook
}

/// One `kdeconnect.telephony` event. `cancel` ends the event.
public struct CallEvent: Sendable, Equatable {
    public var event: String
    public var cancel: Bool

    public init(_ event: String, cancel: Bool = false) {
        self.event = event
        self.cancel = cancel
    }
}

/// Turns line states into telephony events, in the order KDE Connect sends
/// them (Android `CallTracker` parity):
/// idle→ringing = ringing; ringing/idle→offHook = talking (answered or
/// dialed); ringing→idle = missedCall + end of ringing; offHook→idle = end
/// of talking. Repeats of the same state send nothing.
public struct CallTracker: Sendable {
    public private(set) var state: LineState = .idle

    public init() {}

    public mutating func onState(_ next: LineState) -> [CallEvent] {
        let prev = state
        state = next
        if prev == next { return [] }
        switch next {
        case .ringing: return [CallEvent("ringing")]
        case .offHook: return [CallEvent("talking")]
        case .idle:
            if prev == .ringing {
                return [CallEvent("missedCall"), CallEvent("ringing", cancel: true)]
            }
            return [CallEvent("talking", cancel: true)]
        }
    }
}

// MARK: - Telephony packets

/// `kdeconnect.telephony` builders. Port of Android `CallPackets`.
public enum CallPackets {
    /// The contact name when the phone knows neither number nor name.
    public static let unknownCaller = "Unknown caller"

    /// The display name: contact name, else number, else `unknownCaller`.
    public static func caller(phoneNumber: String?, contactName: String?) -> String {
        let name = contactName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let number = phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !number.isEmpty { return number }
        return unknownCaller
    }

    /// Builds the packet for `event`. Without the contacts permission the
    /// name is nil and only the number goes out; with no number either the
    /// name is `unknownCaller` (Android `CallPackets.body` parity — empty
    /// strings are dropped, never sent blank).
    public static func packet(event: CallEvent, phoneNumber: String? = nil, contactName: String? = nil) -> Packet {
        let number = phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var name = contactName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty, number.isEmpty { name = unknownCaller }
        var body: [String: JSONValue] = ["event": .string(event.event)]
        if !number.isEmpty { body["phoneNumber"] = .string(number) }
        if !name.isEmpty { body["contactName"] = .string(name) }
        if event.cancel { body["isCancel"] = .bool(true) }
        return Packet(type: PacketType.telephony, body: body)
    }

    /// Reads `isCancel` the way Go `flexString.bool` does: boolean true,
    /// number 1, or the strings "true"/"1". Anything else (including
    /// `true` arriving as `"True"` with capitals — Go compares exact) is
    /// not a cancel.
    public static func isCancel(_ p: Packet) -> Bool {
        guard p.type == PacketType.telephony else { return false }
        switch p.body["isCancel"] {
        case .bool(let b): return b
        case .integer(let i): return i == 1
        case .double(let d): return d == 1
        case .string(let s): return s == "true" || s == "1"
        default: return false
        }
    }
}

// MARK: - Do Not Disturb (flux.dnd)

/// `flux.dnd` packets (`{"on": bool}`, both directions).
public enum DndMessage {
    public static func packet(on: Bool) -> Packet {
        Packet.of(PacketType.fluxDnd, ("on", on))
    }

    /// Parses an arrival. Nil for other types or a missing/non-boolean
    /// `on` (Go `handleDnd` drops those too).
    public static func parse(_ p: Packet) -> Bool? {
        guard p.type == PacketType.fluxDnd else { return nil }
        return p.bool("on")
    }
}

/// Keeps Do Not Disturb sync from echoing a change back to the side that
/// made it. Port of Go `dndGuard` + Android `DndGuard` (times in ms;
/// settle 3 s = Go `dndSettle`).
public struct DndGuard: Sendable {
    public static let settleMs: Int64 = 3_000

    private var known = false
    private var valid = false
    private var pending = false
    private var untilMs: Int64 = 0

    public init() {}

    /// Takes a state this phone reports at `nowMs`. True when it is a
    /// local change the computers must get; the first state only seeds.
    public mutating func local(on: Bool, nowMs: Int64) -> Bool {
        if pending {
            if on == known {
                pending = false
                return false
            }
            if nowMs < untilMs { return false }
            pending = false
        }
        if !valid {
            known = on
            valid = true
            return false
        }
        if on == known { return false }
        known = on
        return true
    }

    /// Takes a state from a computer at `nowMs`. True when the phone must
    /// apply it (iOS never applies — the bridge only uses this to swallow
    /// the echo of its own sends; see `FocusBridge`).
    public mutating func remote(on: Bool, nowMs: Int64) -> Bool {
        if valid, on == known { return false }
        known = on
        valid = true
        pending = true
        untilMs = nowMs + Self.settleMs
        return true
    }
}
