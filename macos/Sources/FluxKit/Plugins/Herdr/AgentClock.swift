import Foundation

/// Keeps the time that each agent of 1 computer got its status, as this
/// device saw it. The first state after a connection only sets the start
/// values, so the time of a status that started before is not known. An
/// unknown status keeps the last known status and its time.
public struct AgentClock: Sendable {
    /// The status of each pane and the time that it started, or nil when the time is not known.
    private var since: [String: (status: AgentStatus, at: Date?)] = [:]
    private var fresh = true

    public init() {}

    /// Makes the next state set the start values. Call it when the computer connects.
    public mutating func restart() { fresh = true }

    /// Takes a new agent list at the time `now` and returns the start time
    /// of the status of each agent by pane. An agent whose start time is
    /// not known is not in the result.
    @discardableResult
    public mutating func update(_ agents: [HerdrAgent], now: Date) -> [String: Date] {
        var seen = Set<String>()
        for a in agents {
            seen.insert(a.pane)
            if a.status == .unknown { continue }
            let prev = since[a.pane]
            if prev?.status == a.status { continue }
            since[a.pane] = (a.status, prev == nil && fresh ? nil : now)
        }
        since = since.filter { seen.contains($0.key) }
        fresh = false
        return times
    }

    /// The start time of the status of each agent whose start time is known, by pane.
    public var times: [String: Date] { since.compactMapValues { $0.at } }
}

/// The time at the end of an agent row: "3m" for an agent that waits,
/// "2:14" for an agent that works, and "done" for a finished agent. A time
/// that this device did not see is empty.
public enum AgentTime {
    public static func when(_ status: AgentStatus, since: Date?, now: Date) -> String {
        if status == .done { return "done" }
        guard let since else { return "" }
        let sec = max(0, Int(now.timeIntervalSince(since)))
        switch status {
        case .working:
            return sec >= 3600
                ? String(format: "%d:%02d:%02d", sec / 3600, (sec / 60) % 60, sec % 60)
                : String(format: "%d:%02d", sec / 60, sec % 60)
        case .blocked, .idle:
            if sec < 60 { return "now" }
            if sec < 3600 { return "\(sec / 60)m" }
            return "\(sec / 3600)h"
        default:
            return ""
        }
    }
}

/// How long ago a time was: "just now", "3 min ago", "2 h ago", "1 day
/// ago", or "4 days ago".
public enum AgoText {
    public static func text(_ at: Date, now: Date) -> String {
        let min = Int(now.timeIntervalSince(at) / 60)
        if min < 1 { return "just now" }
        if min < 60 { return "\(min) min ago" }
        if min < 24 * 60 { return "\(min / 60) h ago" }
        if min < 2 * 24 * 60 { return "1 day ago" }
        return "\(min / (24 * 60)) days ago"
    }
}
