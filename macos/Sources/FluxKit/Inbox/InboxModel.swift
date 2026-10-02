import Foundation

/// The link state of the paired computers in a scope: the number that are
/// online, and the computers that are not reachable. The Inbox cannot show
/// the agents of a computer that is not reachable.
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

/// The Inbox model: it collects the items of all computers and ranks them.
/// It is a port of InboxModel.kt of the Android app.
public enum Inbox {
    /// How long a finished transfer, the last clip, and a paused player stay, in seconds.
    public static let keep: TimeInterval = 30 * 60

    /// How far from the end of the output the question can start, in lines.
    static let promptScanLines = 40

    /// Collects the Inbox items of all computers and ranks them. The order
    /// is the order of `InboxKind`. Inside a kind, the computers keep their
    /// order, running transfers come before the newest finished ones, and a
    /// player that plays comes before a paused one.
    ///
    /// A finished transfer and the clip stay for `keep` after they end. A
    /// paused player stays for `keep` after the time in `playedAt`, which
    /// maps a device ID to the last time that its player played. Each key
    /// shows once.
    public static func items(devices: [DeviceSnapshot], herdr: [String: HerdrState], media: [String: RemoteMedia],
                             approval: ApproveRequest?, transfers: [FileTransfer], clip: ClipEvent?,
                             now: Date, playedAt: [String: Date]) -> [InboxItem] {
        func recent(_ at: Date) -> Bool { now.timeIntervalSince(at) <= keep }
        var out: [InboxItem] = []
        for d in devices {
            if !d.paired {
                if d.pairState == .incoming { out.append(InboxItem(.pair(deviceId: d.id), computer: d.name)) }
                continue
            }
            guard d.online, let h = herdr[d.id], h.running else { continue }
            for a in h.agents where a.status == .blocked || a.status == .done || a.status == .working {
                out.append(InboxItem(.agent(deviceId: d.id, agent: a, control: h.control), computer: d.name))
            }
        }
        if let approval { out.append(InboxItem(.approval(approval), computer: approval.computerName)) }

        let names = Dictionary(devices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let shown = recentTransfers(transfers).filter { $0.state == .running || recent($0.ended ?? $0.started) }
        // Running first, then the newest start. The offset keeps the sort stable.
        let ranked = shown.enumerated().sorted { a, b in
            let ar = a.element.state == .running
            let br = b.element.state == .running
            if ar != br { return ar }
            if a.element.started != b.element.started { return a.element.started > b.element.started }
            return a.offset < b.offset
        }
        for entry in ranked {
            out.append(InboxItem(.transfer(entry.element), computer: names[entry.element.deviceId] ?? "a computer"))
        }

        if let clip, recent(clip.at) { out.append(InboxItem(.clip(clip), computer: clip.computer)) }

        var players: [(playing: Bool, offset: Int, item: InboxItem)] = []
        for (offset, d) in devices.enumerated() where d.paired && d.online {
            guard let p = media[d.id]?.player else { continue }
            let played = playedAt[d.id].map { recent($0) } ?? false
            guard p.playing || (!p.title.isEmpty && played) else { continue }
            players.append((playing: p.playing, offset: offset,
                            item: InboxItem(.media(deviceId: d.id, player: p), computer: d.name)))
        }
        players.sort { a, b in
            if a.playing != b.playing { return a.playing }
            return a.offset < b.offset
        }
        out += players.map { $0.item }

        // The sort is stable through the offset, so the order above stays
        // inside each kind. A computer can report 2 agents on 1 pane, and
        // the Inbox needs each key once.
        var seen = Set<String>()
        return out.enumerated()
            .sorted { a, b in
                let ak = a.element.kind.rawValue
                let bk = b.element.kind.rawValue
                return ak != bk ? ak < bk : a.offset < b.offset
            }
            .map { $0.element }
            .filter { seen.insert($0.key).inserted }
    }

    /// The items from the plugin models of `core`. `devices` is the device
    /// list that the app shows. SwiftUI tracks each model that it reads.
    @MainActor
    public static func items(core: FluxCore, devices: [DeviceSnapshot], now: Date, playedAt: [String: Date]) -> [InboxItem] {
        items(devices: devices,
              herdr: core.plugin(HerdrPlugin.self)?.model.states ?? [:],
              media: core.plugin(MprisPlugin.self)?.model.devices ?? [:],
              approval: core.plugin(ApprovePlugin.self)?.model.current,
              transfers: core.plugin(SharePlugin.self)?.model.transfers ?? [],
              clip: core.plugin(ClipboardPlugin.self)?.model.last,
              now: now, playedAt: playedAt)
    }

    /// All running transfers, and the newest finished ones up to `limit`
    /// in total. `transfers` is newest first, and the result keeps its order.
    public static func recentTransfers(_ transfers: [FileTransfer], limit: Int = 4) -> [FileTransfer] {
        let running = transfers.filter { $0.state == .running }
        let done = transfers.filter { $0.state != .running }.prefix(Swift.max(0, limit - running.count))
        let kept = Set(running.map { $0.id } + done.map { $0.id })
        return transfers.filter { kept.contains($0.id) }
    }

    /// Records `now` as the last play time of each paired, online computer
    /// whose player plays. It returns `playedAt` when no player plays.
    public static func notePlaying(_ playedAt: [String: Date], devices: [DeviceSnapshot],
                                   media: [String: RemoteMedia], now: Date) -> [String: Date] {
        let playing = devices.filter { $0.paired && $0.online && media[$0.id]?.player?.playing == true }
        if playing.isEmpty { return playedAt }
        var out = playedAt
        for d in playing { out[d.id] = now }
        return out
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
