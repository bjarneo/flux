import Foundation

// The texts about the link to a computer. This is a port of LinkNote.kt of
// the Android app. The thread of an agent and the rows of Chats show them,
// so that all apps use the same words.

/// The 3 link states of an agent thread.
public enum ThreadLink: Sendable, Equatable {
    case connected, connecting, unreachable
}

/// The note above the dock of an agent thread. `title` is the first line.
/// `detail` is the second line, or empty. For `.connected`, `detail` is the
/// age of the output, such as `now` or `3m`.
public struct ThreadNote: Sendable, Equatable {
    public var state: ThreadLink
    public var title: String
    public var detail: String

    public init(_ state: ThreadLink, _ title: String, _ detail: String) {
        self.state = state
        self.title = title
        self.detail = detail
    }
}

public enum LinkNote {
    /// `HH:MM` of a time, for tests and for a caller with no device format.
    public static func clock(_ at: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: at)
    }

    /// A time in the short format of this device, such as `14:02` or `2:02 PM`.
    public static func deviceClock(_ at: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: at)
    }

    /// The note of a thread, or nil when it has no note: the computer is
    /// connected and this device has no output yet. `outputAt` is the time
    /// of the last output, or nil when it is not known.
    public static func threadNote(online: Bool, connecting: Bool, name: String, outputAt: Date?, now: Date,
                                  time: (Date) -> String = deviceClock) -> ThreadNote? {
        if online {
            guard let outputAt else { return nil }
            return ThreadNote(.connected, "Output from \(time(outputAt))", age(now.timeIntervalSince(outputAt)))
        }
        if connecting { return ThreadNote(.connecting, "Connecting to \(name)", "") }
        return ThreadNote(.unreachable, "\(name) is not reachable.", outputAt.map { "This output is from \(time($0))." } ?? "")
    }

    /// The line of a row of a computer that is not reachable, or nil when
    /// the computer is `online`. `lastSeen` is nil when it is not known.
    public static func rowLine(online: Bool, lastSeen: Date?, time: (Date) -> String = deviceClock) -> String? {
        if online { return nil }
        return lastSeen.map { "Not reachable since \(time($0))" } ?? "Not reachable"
    }

    /// The age of an output: `now` under 1 minute, then `3m`, `2h`, or `4d`.
    public static func age(_ seconds: TimeInterval) -> String {
        let min = Int(max(0, seconds) / 60)
        switch min {
        case ..<1: return "now"
        case ..<60: return "\(min)m"
        case ..<(24 * 60): return "\(min / 60)h"
        default: return "\(min / (24 * 60))d"
        }
    }
}
