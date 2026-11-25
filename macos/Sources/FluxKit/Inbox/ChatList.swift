import Foundation

/// The link to the computer of an agent row. `reachable` is false while the
/// computer is not reachable. The row then shows the last known agent, and
/// `since` is the time that this device last saw the computer, or nil.
public struct AgentLink: Sendable, Equatable {
    public var reachable: Bool
    public var since: Date?

    public init(reachable: Bool = true, since: Date? = nil) {
        self.reachable = reachable
        self.since = since
    }
}

/// 1 row of the Chats list. `id` stays the same while the row is the same,
/// so the list keeps its place. It is a port of ChatList.kt of the Android
/// app.
public enum ChatRow: Sendable, Equatable, Identifiable {
    /// A sudo, polkit, or enrollment request that waits for the fingerprint.
    /// The list shows it as a card with Deny and Approve.
    case approval(ApproveRequest, at: Date)
    /// A computer that is not paired and asks to pair.
    case pair(deviceId: String, computer: String, at: Date)
    /// A herdr agent: 1 chat. `at` is the start of its status. `control` is
    /// true when the computer takes replies. `link` tells whether the
    /// computer is reachable.
    case agent(deviceId: String, computer: String, agent: HerdrAgent, control: Bool, at: Date, link: AgentLink = AgentLink())
    /// A paired computer: 1 chat. `last` is the newest entry of its chat, or
    /// the newest entry that matches the search.
    case computer(DeviceSnapshot, last: ChatEntry?)

    public var id: String {
        switch self {
        case .approval(let r, _): return "approve|\(r.computerId)|\(r.id)"
        case .pair(let deviceId, _, _): return "pair|\(deviceId)"
        case .agent(let deviceId, _, let a, _, _, _): return "agent|\(deviceId)|\(a.pane)"
        case .computer(let d, _): return "computer|\(d.id)"
        }
    }

    /// The time of the row. A computer with no entry has the distant past.
    public var at: Date {
        switch self {
        case .approval(_, let at), .pair(_, _, let at), .agent(_, _, _, _, let at, _): return at
        case .computer(_, let last): return last?.at ?? .distantPast
        }
    }

    /// The key that `SeenClock` keeps for the row. An agent with a new status is new.
    var seenKey: String {
        if case .agent(_, _, let a, _, _, _) = self { return "\(id)|\(a.status.rawValue)" }
        return id
    }
}

/// The rows of the Chats list in 3 groups. `needs` holds the approvals,
/// the pair requests, and the agents that wait for input, the newest
/// first. `agents` holds the other agents: the agents that work, then the
/// agents that are done, then the idle agents. `computers` holds the
/// paired computers, the online computers first.
public struct ChatList: Sendable, Equatable {
    public var needs: [ChatRow]
    public var agents: [ChatRow]
    public var computers: [ChatRow]

    public init(needs: [ChatRow] = [], agents: [ChatRow] = [], computers: [ChatRow] = []) {
        self.needs = needs
        self.agents = agents
        self.computers = computers
    }

    public var isEmpty: Bool { needs.isEmpty && agents.isEmpty && computers.isEmpty }
}

extension ChatEntry {
    /// The text of the entry for the search: the link or the text, the file
    /// name, the clip, or the service of an answer. An event has none.
    public var text: String? {
        switch self {
        case .sent(let s): return s.text
        case .file(let t): return t.name
        case .clip(let c): return c.preview
        case .answer(let r): return r.request?.service ?? r.summary
        case .event: return nil
        }
    }

    /// The entry in 1 line for the list of chats, such as "You: Dinner at 7"
    /// or "invoice-0042.pdf".
    public var preview: String {
        let flat = (text ?? "").replacingOccurrences(of: "\n", with: " ")
        switch self {
        case .sent(let s): return s.kind == .clipImage ? "You: an image" : "You: \(flat)"
        case .file(let t):
            switch (t.incoming, t.state) {
            case (true, .running): return "Receiving \(flat)"
            case (true, _): return flat
            case (false, .running): return "You: sending \(flat)"
            case (false, .failed): return "You: not sent, \(flat)"
            case (false, .done): return "You: \(flat)"
            }
        case .clip(let c): return c.image ? "Clipboard: an image" : "Clipboard: \(flat)"
        case .answer(let r):
            switch r.outcome {
            case .approved, .enrolled: return "Approved \(flat)"
            case .denied: return "Denied \(flat)"
            default: return flat
            }
        case .event: return ""
        }
    }
}

/// The list of chats: 1 chat for each agent and each paired computer.
public enum Chats {
    /// The order of an agent in the Agents group: the agents that work first, then the agents that are done.
    private static func rank(_ s: AgentStatus) -> Int {
        switch s {
        case .working: return 0
        case .done: return 1
        default: return 2
        }
    }

    /// True when `query` is empty or when 1 of `fields` holds it, without case.
    private static func matches(_ query: String, _ fields: String?...) -> Bool {
        query.isEmpty || fields.contains { $0?.range(of: query, options: .caseInsensitive) != nil }
    }

    /// Builds the Chats list: 1 chat for each agent and each paired
    /// computer, and the `approval` and the pair requests on top. A computer
    /// that is not reachable keeps the last known agents. Their rows have
    /// `AgentLink.reachable` false, and `AgentLink.since` is `lastSeen` of the
    /// computer. An agent takes the start time of its status from `since`,
    /// by computer and pane, and an approval the time of its request. Any other row with no time takes the time that
    /// `seen` first saw it at `now`. `log` holds the chat entries of all
    /// computers, see `Chat.entries`, and gives each computer its newest
    /// entry. A `query` keeps only the rows that hold it: a computer also
    /// stays when an entry of its chat holds it, and that entry shows.
    public static func list(devices: [DeviceSnapshot], herdr: [String: HerdrState], approval: ApproveRequest?,
                            log: [ChatEntry], since: (_ deviceId: String, _ pane: String) -> Date?,
                            lastSeen: (_ deviceId: String) -> Date? = { _ in nil },
                            seen: inout SeenClock, now: Date, query: String = "") -> ChatList {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let paired = devices.filter(\.paired)
        var rows: [ChatRow] = []
        if let approval, paired.contains(where: { $0.id == approval.computerId }) {
            rows.append(.approval(approval, at: approval.time > 0 ? Date(timeIntervalSince1970: TimeInterval(approval.time)) : .distantPast))
        }
        for d in devices where !d.paired && d.pairState == .incoming {
            rows.append(.pair(deviceId: d.id, computer: d.name, at: .distantPast))
        }
        for d in paired {
            guard let h = herdr[d.id], h.running else { continue }
            let link = AgentLink(reachable: d.online, since: d.online ? nil : lastSeen(d.id))
            var panes = Set<String>()
            for a in h.agents where panes.insert(a.pane).inserted {
                rows.append(.agent(deviceId: d.id, computer: d.name, agent: a, control: h.control,
                                   at: since(d.id, a.pane) ?? .distantPast, link: link))
            }
        }
        let times = seen.update(rows.map(\.seenKey), now: now)
        let timed: [ChatRow] = rows.map { r in
            let first = times[r.seenKey] ?? now
            switch r {
            case .approval(let req, let at): return .approval(req, at: at == .distantPast ? first : at)
            case .pair(let id, let name, _): return .pair(deviceId: id, computer: name, at: first)
            case .agent(let id, let name, let a, let control, let at, let link):
                return .agent(deviceId: id, computer: name, agent: a, control: control, at: at == .distantPast ? first : at, link: link)
            case .computer: return r
            }
        }.filter { r in
            switch r {
            case .approval(let req, _): return matches(q, req.service, req.host, req.computerName, req.user)
            case .pair(_, let name, _): return matches(q, name)
            case .agent(_, let name, let a, _, _, _): return matches(q, a.title, a.agent, a.project, a.workspace, a.pane, name)
            case .computer: return true
            }
        }
        var list = ChatList()
        list.needs = timed.filter { r in
            if case .agent(_, _, let a, _, _, _) = r { return a.status == .blocked }
            return true
        }.sorted { $0.at > $1.at }
        list.agents = timed.filter { r in
            if case .agent(_, _, let a, _, _, _) = r { return a.status != .blocked }
            return false
        }.sorted { a, b in
            guard case .agent(_, _, let x, _, _, _) = a, case .agent(_, _, let y, _, _, _) = b else { return false }
            return rank(x.status) != rank(y.status) ? rank(x.status) < rank(y.status) : a.at > b.at
        }
        list.computers = paired.compactMap { d -> ChatRow? in
            let entries = log.filter { if case .event = $0 { return false }; return $0.shows(in: d.id) }
            let named = matches(q, d.name)
            let last = (named ? entries : entries.filter { matches(q, $0.text) }).max { $0.at < $1.at }
            if !q.isEmpty && last == nil && !named { return nil }
            return .computer(d, last: last)
        }.sorted { a, b in
            guard case .computer(let x, _) = a, case .computer(let y, _) = b else { return false }
            if x.online != y.online { return x.online }
            if a.at != b.at { return a.at > b.at }
            return x.name.lowercased() < y.name.lowercased()
        }
        return list
    }
}
