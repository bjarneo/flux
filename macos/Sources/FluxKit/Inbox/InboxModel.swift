import Foundation

/// The link state of the paired computers in a scope: the number that are
/// online, and the computers that are not reachable. The Inbox keeps only
/// the agents that wait of a computer that is not reachable.
public struct InboxReach: Sendable, Equatable {
    public var online: Int
    public var offline: [DeviceSnapshot]

    public init(online: Int, offline: [DeviceSnapshot]) {
        self.online = online
        self.offline = offline
    }

    /// True when the scope has paired computers and none of them is online.
    public var noneOnline: Bool { online == 0 && !offline.isEmpty }
}

/// The computer for a Send or Control action.
public enum ActionTarget: Sendable, Equatable {
    /// The only computer that can take it.
    case one(DeviceSnapshot)
    /// The user picks 1 of these computers.
    case ask([DeviceSnapshot])
    /// No computer can take it now. The device is the computer in scope, or nil.
    case unavailable(DeviceSnapshot?)
}

/// The Inbox model: it collects the items of all computers that have a
/// state now. The chat puts them in time order, see `Chat.entries`. It is
/// a port of InboxModel.kt of the Android app.
public enum Inbox {
    /// How far from the end of the output the question can start, in lines.
    static let promptScanLines = 40

    /// Collects the Inbox items of all computers: the agents that wait, are
    /// done, or work, the open `approval`, and the pair requests. A computer
    /// that is not reachable adds only its last known agents that wait,
    /// because they still wait for the user. Each key shows once, because a
    /// computer can report 2 agents on 1 pane.
    public static func items(devices: [DeviceSnapshot], herdr: [String: HerdrState], approval: ApproveRequest?) -> [InboxItem] {
        var out: [InboxItem] = []
        for d in devices {
            if !d.paired {
                if d.pairState == .incoming { out.append(InboxItem(.pair(deviceId: d.id), computer: d.name)) }
                continue
            }
            guard let h = herdr[d.id], h.running else { continue }
            for a in h.agents where a.status == .blocked || (d.online && (a.status == .done || a.status == .working)) {
                out.append(InboxItem(.agent(deviceId: d.id, agent: a, control: h.control), computer: d.name))
            }
        }
        if let approval { out.append(InboxItem(.approval(approval), computer: approval.computerName)) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.key).inserted }
    }

    /// The items from the plugin models of `core`. `devices` is the device
    /// list that the app shows. SwiftUI tracks each model that it reads.
    @MainActor
    public static func items(core: FluxCore, devices: [DeviceSnapshot]) -> [InboxItem] {
        items(devices: devices,
              herdr: core.plugin(HerdrPlugin.self)?.model.states ?? [:],
              approval: core.plugin(ApprovePlugin.self)?.model.current)
    }

    /// The number of items that need the user.
    public static func needsYou(_ items: [InboxItem]) -> Int { items.filter { $0.kind.needsYou }.count }

    /// The items of the computer `scope`, or all items when `scope` is nil.
    /// An item with no computers shows in every scope.
    public static func inScope(_ items: [InboxItem], scope: String?) -> [InboxItem] {
        guard let scope else { return items }
        return items.filter { $0.deviceIds.isEmpty || $0.deviceIds.contains(scope) }
    }

    /// The link state of the paired computers in `scope`, or of all paired computers when `scope` is nil.
    public static func reach(scope: String?, devices: [DeviceSnapshot]) -> InboxReach {
        let paired = devices.filter { $0.paired && (scope == nil || $0.id == scope) }
        return InboxReach(online: paired.filter { $0.online }.count, offline: paired.filter { !$0.online })
    }

    /// Finds the computer for an action. A computer in `scope` is the
    /// target when it is online and `can` take the action. With all
    /// computers in scope, the only online computer that can take it is the
    /// target, and with more than 1 the user picks.
    public static func target(scope: String?, devices: [DeviceSnapshot],
                              can: (DeviceSnapshot) -> Bool = { _ in true }) -> ActionTarget {
        let paired = devices.filter { $0.paired }
        if let scope {
            guard let d = paired.first(where: { $0.id == scope }) else { return .unavailable(nil) }
            return d.online && can(d) ? .one(d) : .unavailable(d)
        }
        var ready: [DeviceSnapshot] = []
        for d in paired where d.online && can(d) { ready.append(d) }
        switch ready.count {
        case 0: return .unavailable(nil)
        case 1: return .one(ready[0])
        default: return .ask(ready)
        }
    }

    /// True when a paired computer in `scope` has a feature, also while it is not reachable.
    public static func hasFeature(scope: String?, devices: [DeviceSnapshot], can: (DeviceSnapshot) -> Bool) -> Bool {
        for d in devices where d.paired && (scope == nil || d.id == scope) && can(d) { return true }
        return false
    }

    // MARK: Prompt

    // Kotlin \s is [ \t\n\x0B\f\r]. ICU \s also takes Unicode spaces, so the class is written out.
    private static let firstChoice = try! NSRegularExpression(
        pattern: #"^[ \t\n\x0B\f\r]*([❯›>][ \t\n\x0B\f\r]*)?1[.)][ \t\n\x0B\f\r]+.+$"#)
    private static let ruleLine = try! NSRegularExpression(pattern: #"^[ \t\n\x0B\f\r─━═╌┄╍┈┉\-_]+$"#)

    /// True when the pattern matches the whole text.
    private static func whole(_ re: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range) else { return false }
        return m.range == range
    }

    /// Finds the question of an agent in its output lines: the lines above
    /// the first numbered choice, up to `maxLines` lines that are not
    /// empty. A rule line ends the question. Without choices, it gives the
    /// last lines that are not empty. The lines nearest the choices stay,
    /// because they hold the command that a choice approves. With
    /// `dropAsk`, the last line above the choices goes away when it ends
    /// with a question mark, because the choices ask the same question. The
    /// command then gets that line. The input is the plain text of each
    /// line: `HerdrOutput.lines.map(\.text)`.
    public static func agentPrompt(_ lines: [String], maxLines: Int = 4, dropAsk: Bool = false) -> String {
        let from = Swift.max(0, lines.count - promptScanLines)
        var choice: Int?
        var j = lines.count - 1
        while j >= from {
            if whole(firstChoice, lines[j]) {
                choice = j
                break
            }
            j -= 1
        }
        var out: [String] = []
        var i = (choice ?? lines.count) - 1
        var ask = dropAsk && choice != nil
        while i >= from && out.count < maxLines {
            let t = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            i -= 1
            if t.isEmpty { continue }
            if whole(ruleLine, t) { break }
            if ask {
                ask = false
                if t.hasSuffix("?") { continue }
            }
            out.insert(t, at: 0)
        }
        return out.joined(separator: "\n")
    }

    /// A short form of a clip for the Inbox: 1 line with single spaces, cut
    /// at `limit` characters. A cut text ends with "…".
    public static func clipPreview(_ text: String, max limit: Int = 160) -> String {
        // Kotlin \s, as in agentPrompt. A space at the ends is gone after the trim.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var t = ""
        var gap = false
        for s in trimmed.unicodeScalars {
            if isSpace(s) {
                gap = true
                continue
            }
            if gap && !t.isEmpty { t.append(" ") }
            gap = false
            t.unicodeScalars.append(s)
        }
        guard t.count > limit else { return t }
        return String(t.prefix(Swift.max(0, limit - 1))) + "…"
    }

    /// The characters of Kotlin \s: space, tab, line feed, vertical tab, form feed, and carriage return.
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t" || s == "\n" || s == "\u{0B}" || s == "\u{0C}" || s == "\r"
    }
}
