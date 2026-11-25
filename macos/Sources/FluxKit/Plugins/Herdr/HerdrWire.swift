import Foundation

/// The status of a herdr agent. `blocked` waits for an approval or an
/// answer. `idle` and `done` are both ready for input. The order of the
/// cases is the sort order of the agent list.
public enum AgentStatus: String, CaseIterable, Sendable {
    case blocked, done, working, idle, unknown

    /// Returns the status for a wire value. An unknown value gives `unknown`.
    public init(wire: String?) { self = AgentStatus(rawValue: wire ?? "") ?? .unknown }

    /// True when the agent is ready for input.
    public var ready: Bool { self == .done || self == .idle }

    var order: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
}

/// One coding agent in a herdr pane on a computer. `pane` is the herdr pane
/// ID, for example w5:p1. A pane of a named session has the session name
/// before its ID, for example omarchy/w5:p1. `session` is the name of its
/// herdr session.
public struct HerdrAgent: Sendable, Hashable, Identifiable {
    public var pane: String
    public var agent: String
    public var status: AgentStatus
    public var title: String
    public var project: String
    public var workspace: String
    public var session: String

    public init(pane: String, agent: String, status: AgentStatus, title: String = "", project: String = "", workspace: String = "",
                session: String = HerdrSession.defaultName) {
        self.pane = pane
        self.agent = agent
        self.status = status
        self.title = title
        self.project = project
        self.workspace = workspace
        self.session = session
    }

    public var id: String { pane }
}

/// A herdr pane without an agent: a terminal. `title` is the terminal
/// title, which a shell often sets to the command.
public struct HerdrTerminal: Sendable, Hashable, Identifiable {
    public var pane: String
    public var title: String
    public var project: String
    public var workspace: String
    public var session: String

    public init(pane: String, title: String = "", project: String = "", workspace: String = "", session: String = HerdrSession.defaultName) {
        self.pane = pane
        self.title = title
        self.project = project
        self.workspace = workspace
        self.session = session
    }

    public var id: String { pane }
}

/// A herdr workspace that can get a new tab. `cwd` is the folder of its
/// active tab on the computer.
public struct HerdrWorkspace: Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var cwd: String
    public var session: String

    public init(id: String, label: String, cwd: String = "", session: String = HerdrSession.defaultName) {
        self.id = id
        self.label = label
        self.cwd = cwd
        self.session = session
    }
}

/// A herdr session on a computer. The default session is the herdr of the
/// computer, and a named session is one that the user started with
/// `herdr session attach NAME`. An older fluxd follows the default session
/// only.
public struct HerdrSession: Sendable, Hashable, Identifiable {
    /// The name of the default session on the wire.
    public static let defaultName = "default"

    public var name: String
    public var isDefault: Bool
    public var running: Bool

    public init(name: String, isDefault: Bool = false, running: Bool = true) {
        self.name = name
        self.isDefault = isDefault
        self.running = running
    }

    public var id: String { name }

    /// The name of the session for the UI.
    public var label: String { isDefault ? "Default" : name }
}

/// What a computer reports about herdr. `enabled` is false when the
/// computer has `herdr = false` in its config.toml. `running` is true when
/// fluxd reaches the herdr server. `control` is true when the computer
/// accepts replies from this device, and new agents. `terminals` is true
/// when the computer also opens terminals for this device and lists them
/// in `panes`. `workspaces` and `kinds` are the places and the agent kinds
/// for a new agent.
///
/// A newer fluxd also follows the named herdr sessions. Then `agents`,
/// `panes`, and `workspaces` hold the items of all sessions, each with its
/// session, and `sessions` lists the sessions with the default session
/// first. `scoped(to:)` gives the items of 1 session for the agent list.
/// Without sessions from fluxd, `sessions` has the default session only.
public struct HerdrState: Sendable, Equatable {
    public var enabled: Bool
    public var running: Bool
    public var agents: [HerdrAgent]
    public var control: Bool
    public var terminals: Bool
    public var panes: [HerdrTerminal]
    public var workspaces: [HerdrWorkspace]
    public var kinds: [String]
    public var review: Bool
    public var sessions: [HerdrSession]

    public init(
        enabled: Bool,
        running: Bool,
        agents: [HerdrAgent],
        control: Bool = false,
        terminals: Bool = false,
        panes: [HerdrTerminal] = [],
        workspaces: [HerdrWorkspace] = [],
        kinds: [String] = [],
        review: Bool = false,
        sessions: [HerdrSession] = []
    ) {
        self.enabled = enabled
        self.running = running
        self.agents = agents
        self.control = control
        self.terminals = terminals
        self.panes = panes
        self.workspaces = workspaces
        self.kinds = kinds
        self.review = review
        self.sessions = sessions.isEmpty ? [HerdrSession(name: HerdrSession.defaultName, isDefault: true, running: running)] : sessions
    }

    /// The agents with `blocked` first, then done, working, idle, and
    /// unknown. The herdr order stays inside a group.
    public var sorted: [HerdrAgent] {
        agents.enumerated()
            .sorted { ($0.element.status.order, $0.offset) < ($1.element.status.order, $1.offset) }
            .map(\.element)
    }

    public var blocked: Int { agents.filter { $0.status == .blocked }.count }

    public func agent(_ pane: String) -> HerdrAgent? { agents.first { $0.pane == pane } }

    public func terminal(_ pane: String) -> HerdrTerminal? { panes.first { $0.pane == pane } }

    /// The default session.
    public var defaultSession: HerdrSession {
        sessions.first { $0.isDefault } ?? sessions.first ?? HerdrSession(name: HerdrSession.defaultName, isDefault: true, running: running)
    }

    /// The session to show for the chosen session `name`: that session
    /// while the computer has it, else the default session.
    public func session(_ name: String?) -> HerdrSession {
        name.flatMap { n in sessions.first { $0.name == n } } ?? defaultSession
    }

    /// The agents of the session `name` that need input.
    public func blockedCount(in name: String) -> Int { agents.filter { $0.session == name && $0.status == .blocked }.count }

    /// The agents, the terminals, and the workspaces of the session `name`,
    /// or of the default session when the computer has no such session.
    /// `running` tells whether that session runs.
    public func scoped(to name: String?) -> HerdrState {
        let s = session(name)
        var out = self
        out.running = s.running
        out.agents = agents.filter { $0.session == s.name }
        out.panes = panes.filter { $0.session == s.name }
        out.workspaces = workspaces.filter { $0.session == s.name }
        return out
    }
}

/// The recent output of one pane. `lines` keep the terminal colors, and
/// `text` is the same output without styles. `loading` is true while a read
/// waits for its answer. The old lines stay on screen until the new lines
/// come.
public struct HerdrOutput: Sendable, Equatable {
    /// Two outputs are equal when they show the same screen. The parse time `at` is not part of the comparison,
    /// so a new read of an unchanged screen is not a new output.
    public static func == (a: HerdrOutput, b: HerdrOutput) -> Bool {
        a.pane == b.pane && a.loading == b.loading && a.lines == b.lines && a.truncated == b.truncated
            && a.error == b.error && a.request == b.request && a.view == b.view && a.path == b.path
    }

    public var pane: String
    public var loading: Bool
    public var lines: [TermLine] {
        didSet { derive() }
    }
    public var truncated: Bool
    public var error: String?
    public var request: Int?
    public var view: String
    public var path: String
    /// The time that this device parsed the output, or nil when it is not known.
    public var at: Date?
    public private(set) var text = ""
    /// The choices of the dialog at the end of the output: a numbered
    /// dialog, or a menu row, see `AgentChoice.findMenu`.
    public private(set) var choices: [AgentChoice] = []

    public init(pane: String, loading: Bool = true, lines: [TermLine] = [], truncated: Bool = false, error: String? = nil,
                request: Int? = nil, view: String = "ansi", path: String = "", at: Date? = nil) {
        self.pane = pane
        self.loading = loading
        self.lines = lines
        self.truncated = truncated
        self.error = error
        self.request = request
        self.view = view
        self.path = path
        self.at = at
        derive()
    }

    private mutating func derive() {
        let plain = lines.map(\.text)
        text = plain.joined(separator: "\n")
        let numbered = AgentChoice.find(plain)
        choices = numbered.isEmpty ? AgentChoice.findMenu(lines) : numbered
    }
}

struct HerdrViewRead: Sendable, Equatable {
    let request: Int
    let view: String
    let path: String

    func accepts(request: Int?, view: String, path: String, supportsReview: Bool) -> Bool {
        guard let request else { return !supportsReview && self.view == "ansi" && view == "ansi" && path.isEmpty }
        return self.request == request && self.view == view && self.path == path
    }
}

/// The last reply to a pane. `action` is "keys", "prompt", or "input". `sending` is
/// true until the computer answers. `seq` is different for each reply, so
/// the UI sees each answer.
public struct HerdrReply: Sendable, Equatable {
    public var pane: String
    public var action: String
    public var seq: Int
    public var sending: Bool
    public var error: String?
    /// The code of `error`. "blocked" means that the agent waits for a
    /// choice and fluxd refused the prompt. The UI can then send `text`
    /// again as an answer.
    public var code: String?
    /// The text of a prompt.
    public var text: String?

    public init(pane: String, action: String, seq: Int, sending: Bool = true, error: String? = nil, code: String? = nil, text: String? = nil) {
        self.pane = pane
        self.action = action
        self.seq = seq
        self.sending = sending
        self.error = error
        self.code = code
        self.text = text
    }

    /// True when fluxd refused the prompt because the agent waits for a
    /// choice. The text can go again as an answer.
    public var blocked: Bool { action == "prompt" && !sending && code == HerdrWire.blockedCode && text != nil }
}

/// The answer of the computer to a reply: `{"kind":"sent"}`. `error` is nil
/// on success. `code` names some errors, see `HerdrWire.blockedCode`.
/// `request` is the number of the reply, which a newer fluxd sends back.
public struct HerdrSent: Sendable, Equatable {
    public var pane: String
    public var action: String
    public var error: String?
    public var code: String? = nil
    public var request: Int? = nil
}

/// The last new agent, new terminal, or close from this device. `action` is
/// "create" or "close". `pane` is the new or closed pane, and it is nil
/// until the computer reports it. `what` is "agent" or "terminal" for a
/// create. `sending` is true until the computer answers. `seq` is
/// different for each action, so the UI sees each answer.
public struct HerdrAction: Sendable, Equatable {
    public var action: String
    public var seq: Int
    public var sending: Bool
    public var pane: String?
    public var what: String
    public var error: String?

    public init(action: String, seq: Int, sending: Bool = true, pane: String? = nil, what: String = "", error: String? = nil) {
        self.action = action
        self.seq = seq
        self.sending = sending
        self.pane = pane
        self.what = what
        self.error = error
    }
}

/// The answer of the computer to a create or a close: `{"kind":"created"}`
/// or `{"kind":"closed"}`. `action` is "create" or "close". `request` is
/// the number of the action, which a newer fluxd sends back.
public struct HerdrDone: Sendable, Equatable {
    public var action: String
    public var pane: String?
    public var error: String?
    public var request: Int? = nil
}

/// The flux.herdr messages. docs/herdr.md describes the wire format, and
/// internal/core/herdr.go in fluxd is the other side.
public enum HerdrWire {
    /// The key names that fluxd accepts in a keys packet.
    public static let allowedKeys: Set<String> = Set(["enter", "esc", "tab", "shift+tab", "up", "down", "left", "right", "backspace", "space", "y", "n"]
        + (0...9).map(String.init))
    /// The key names that fluxd accepts in an input packet for a terminal.
    public static let terminalKeys: Set<String> = Set(["enter", "esc", "tab", "shift+tab", "up", "down", "left", "right", "backspace", "space"]
        + "abcdefghijklmnopqrstuvwxyz".map { "ctrl+\($0)" })
    /// The most keys in 1 keys or input packet.
    public static let maxKeys = 8
    /// The longest prompt or terminal text, in UTF-8 bytes.
    public static let maxPrompt = 16 * 1024
    /// The number of lines that a read asks for. fluxd allows 1 to 1000.
    public static let readLines = 1000
    /// The code of a sent answer when fluxd refused a prompt because the
    /// agent waits for a choice.
    public static let blockedCode = "blocked"

    /// Asks the computer for its agent list. The computer answers with a state.
    public static func request() -> Packet { Packet(PacketType.fluxHerdr, ["kind": "request"]) }

    /// Asks for the recent output of a pane, with its colors.
    public static func read(pane: String) -> Packet {
        Packet(PacketType.fluxHerdr, ["kind": "read", "pane": pane, "lines": readLines, "format": "ansi"])
    }

    /// Asks for the last `lines` lines of a pane, with its colors and the
    /// number `request`. A newer fluxd sends the number back, so that this
    /// answer is not taken for the answer to another read.
    public static func read(pane: String, lines: Int, request: Int) -> Packet {
        Packet(PacketType.fluxHerdr, ["kind": "read", "pane": pane, "lines": lines, "format": "ansi", "request": request])
    }

    /// Sends key presses to the agent in a pane.
    public static func keys(pane: String, _ keys: [String]) -> Packet {
        Packet(PacketType.fluxHerdr, ["kind": "keys", "pane": pane, "keys": keys])
    }

    /// Sends text to the agent in a pane. With `answer`, the text answers a
    /// dialog of an agent that waits for a choice. Without it, fluxd refuses
    /// the text for such an agent.
    public static func prompt(pane: String, _ text: String, answer: Bool = false) -> Packet {
        var body: [String: Any?] = ["kind": "prompt", "pane": pane, "text": text]
        if answer { body["answer"] = true }
        return Packet(PacketType.fluxHerdr, body)
    }

    /// Types `text` in the terminal of a pane, then presses `keys`, for
    /// example "ls" and "enter".
    public static func input(pane: String, text: String, keys: [String]) -> Packet {
        Packet(PacketType.fluxHerdr, ["kind": "input", "pane": pane, "text": text, "keys": keys])
    }

    /// Asks the computer to open a pane: an agent of kind `agent` when
    /// `what` is "agent", or a shell when it is "terminal". The pane opens
    /// in `cwd`, where empty is the home folder, as a new tab of
    /// `workspace`, or in a new workspace when `workspace` is empty. The new
    /// workspace opens in the named herdr session `session`, or in the
    /// default session when `session` is empty. A workspace ID names its
    /// session, so the packet has the session only for a new workspace.
    public static func create(what: String, agent: String, cwd: String, workspace: String, session: String = "") -> Packet {
        var body: [String: Any?] = [
            "kind": "create", "what": what, "agent": agent,
            "cwd": cwd.trimmingCharacters(in: .whitespacesAndNewlines), "workspace": workspace,
        ]
        if workspace.isEmpty && !session.isEmpty && session != HerdrSession.defaultName { body["herdr_session"] = session }
        return Packet(PacketType.fluxHerdr, body)
    }

    /// Asks the computer to close a pane. The agent or the shell in it ends.
    public static func close(pane: String) -> Packet {
        Packet(PacketType.fluxHerdr, ["kind": "close", "pane": pane])
    }

    /// Adds the number of a reply, a create, or a close to its packet. A
    /// newer fluxd sends the number back in its answer, so that a late
    /// answer to an earlier request does not end this one.
    public static func numbered(_ packet: Packet, request: Int) -> Packet {
        var p = packet
        p.body["request"] = .int(Int64(request))
        return p
    }

    /// True when fluxd accepts the keys in 1 keys packet.
    public static func allowed(_ keys: [String]) -> Bool {
        !keys.isEmpty && keys.count <= maxKeys && keys.allSatisfy { allowedKeys.contains($0) }
    }

    /// True when fluxd accepts the text and the keys in 1 input packet for a
    /// terminal: 0 to 8 terminal keys, and text or keys.
    public static func allowedInput(text: String, keys: [String]) -> Bool {
        keys.count <= maxKeys && keys.allSatisfy { terminalKeys.contains($0) } && !(text.isEmpty && keys.isEmpty)
    }

    /// Parses the body of a state packet. It returns nil for a body that is not a state.
    public static func state(_ body: [String: JSONValue]) -> HerdrState? {
        guard body["kind"]?.string == "state" else { return nil }
        let kinds = (body["kinds"]?.array ?? []).compactMap { e -> String? in
            guard case .string(let k) = e, !k.isEmpty else { return nil }
            return k
        }
        let enabled = body["enabled"]?.bool ?? true
        let control = enabled && (body["control"]?.bool ?? false)
        let terminals = control && (body["terminals"]?.bool ?? false)
        let running = enabled && (body["running"]?.bool ?? false)
        var agents = parseAgents(body["agents"], session: HerdrSession.defaultName)
        var panes = parseTerminals(body["panes"], session: HerdrSession.defaultName)
        var workspaces = parseWorkspaces(body["workspaces"], session: HerdrSession.defaultName)
        var sessions: [HerdrSession] = []
        // A newer fluxd lists each session with its items. The top-level
        // lists then hold the default session again, for an older app.
        var seen = Set<String>()
        var named: [(HerdrSession, [String: JSONValue])] = []
        for e in body["sessions"]?.array ?? [] {
            guard let o = e.object, let name = o["name"]?.string, !name.isEmpty, seen.insert(name).inserted else { continue }
            named.append((HerdrSession(name: name, isDefault: o["default"]?.bool ?? false, running: enabled && (o["running"]?.bool ?? false)), o))
        }
        if named.contains(where: { $0.0.isDefault }) {
            sessions = named.map { $0.0 }
            agents = named.flatMap { parseAgents($0.1["agents"], session: $0.0.name) }
            panes = named.flatMap { parseTerminals($0.1["panes"], session: $0.0.name) }
            workspaces = named.flatMap { parseWorkspaces($0.1["workspaces"], session: $0.0.name) }
        }
        return HerdrState(
            enabled: enabled,
            running: running || sessions.contains { $0.running },
            agents: agents,
            control: control,
            terminals: terminals,
            panes: terminals ? panes : [],
            workspaces: control ? workspaces : [],
            kinds: control ? kinds : [],
            review: enabled && (body["review"]?.bool ?? false),
            sessions: sessions.isEmpty ? [HerdrSession(name: HerdrSession.defaultName, isDefault: true, running: running)] : sessions
        )
    }

    private static func parseAgents(_ list: JSONValue?, session: String) -> [HerdrAgent] {
        (list?.array ?? []).compactMap { e -> HerdrAgent? in
            guard let o = e.object, let pane = o["pane"]?.string, !pane.isEmpty else { return nil }
            let name = o["agent"]?.string ?? ""
            return HerdrAgent(
                pane: pane,
                agent: name.isEmpty ? "agent" : name,
                status: AgentStatus(wire: o["status"]?.string),
                title: o["title"]?.string ?? "",
                project: o["project"]?.string ?? "",
                workspace: o["workspace"]?.string ?? "",
                session: session
            )
        }
    }

    private static func parseTerminals(_ list: JSONValue?, session: String) -> [HerdrTerminal] {
        (list?.array ?? []).compactMap { e -> HerdrTerminal? in
            guard let o = e.object, let pane = o["pane"]?.string, !pane.isEmpty else { return nil }
            return HerdrTerminal(pane: pane, title: o["title"]?.string ?? "", project: o["project"]?.string ?? "",
                                 workspace: o["workspace"]?.string ?? "", session: session)
        }
    }

    private static func parseWorkspaces(_ list: JSONValue?, session: String) -> [HerdrWorkspace] {
        (list?.array ?? []).compactMap { e -> HerdrWorkspace? in
            guard let o = e.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
            let label = o["label"]?.string ?? ""
            return HerdrWorkspace(id: id, label: label.isEmpty ? id : label, cwd: o["cwd"]?.string ?? "", session: session)
        }
    }

    /// The longest output text that this device parses, in UTF-8 bytes. fluxd
    /// sends at most the same.
    public static let maxText = 1 << 20

    /// Parses the body of an output packet. It returns nil for a body that is not an output.
    public static func output(_ body: [String: JSONValue], now: Date = Date()) -> HerdrOutput? {
        guard body["kind"]?.string == "output", let pane = body["pane"]?.string, !pane.isEmpty else { return nil }
        let error = body["error"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let (text, cut) = tail(body["text"]?.string ?? "", max: maxText)
        // An older fluxd sends plain text. It has no escape sequences, so the
        // same parser reads it.
        return HerdrOutput(
            pane: pane,
            loading: false,
            lines: error == nil ? TermText.lines(text) : [],
            truncated: (body["truncated"]?.bool ?? false) || cut,
            error: error,
            request: body["request"]?.int,
            view: body["view"]?.string ?? "ansi",
            path: body["path"]?.string ?? "",
            at: now
        )
    }

    /// Keeps the end of the text, at most `max` UTF-8 bytes, from the start
    /// of a line when it can, like tailText in fluxd. It returns true when
    /// it cut the text.
    static func tail(_ text: String, max: Int) -> (String, Bool) {
        let utf8 = text.utf8
        guard utf8.count > max else { return (text, false) }
        var start = utf8.index(utf8.endIndex, offsetBy: -max)
        if let newline = utf8[start...].firstIndex(of: 0x0A), utf8.index(after: newline) < utf8.endIndex {
            start = utf8.index(after: newline)
        } else {
            // Start at the first byte of a character, not at a continuation byte.
            while start < utf8.endIndex, utf8[start] & 0xC0 == 0x80 { start = utf8.index(after: start) }
        }
        return (String(decoding: utf8[start...], as: UTF8.self), true)
    }

    /// Parses the body of a created or closed packet. It returns nil for another body.
    public static func done(_ body: [String: JSONValue]) -> HerdrDone? {
        let action: String
        switch body["kind"]?.string {
        case "created": action = "create"
        case "closed": action = "close"
        default: return nil
        }
        return HerdrDone(action: action, pane: body["pane"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                         error: body["error"]?.string.flatMap { $0.isEmpty ? nil : $0 }, request: body["request"]?.int)
    }

    /// Parses the body of a sent packet. It returns nil for a body that is not a sent answer.
    public static func sent(_ body: [String: JSONValue]) -> HerdrSent? {
        guard body["kind"]?.string == "sent", let pane = body["pane"]?.string, !pane.isEmpty else { return nil }
        return HerdrSent(pane: pane, action: body["action"]?.string ?? "", error: body["error"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                         code: body["code"]?.string.flatMap { $0.isEmpty ? nil : $0 }, request: body["request"]?.int)
    }
}

/// A notification change for one pane that `HerdrTracker` finds.
public enum AgentAlert: Sendable, Equatable {
    /// The agent waits for an approval or an answer.
    case needsInput(HerdrAgent)
    /// The agent stopped working and is ready for input. This Mac waits a
    /// moment before it posts this.
    case finished(HerdrAgent)
    /// The notification of the pane is no longer true.
    case clear(String)

    public var pane: String {
        switch self {
        case .needsInput(let a), .finished(let a): return a.pane
        case .clear(let pane): return pane
        }
    }
}

/// Finds the status changes of the agents on one computer. The first state
/// after a connection only sets the start values, so it posts nothing.
public struct HerdrTracker: Sendable {
    private var last: [String: AgentStatus] = [:]
    /// The panes of `last` in the order that they came.
    private var panes: [String] = []
    private var fresh = true

    public init() {}

    /// Makes the next state set the start values. Call it when the computer connects.
    public mutating func restart() { fresh = true }

    /// Takes a new agent list and returns the notification changes.
    public mutating func update(_ agents: [HerdrAgent]) -> [AgentAlert] {
        var out: [AgentAlert] = []
        var seen = Set<String>()
        for a in agents {
            seen.insert(a.pane)
            let prev = last[a.pane]
            // An unknown status gives no information. The last known status stays.
            if a.status == .unknown { continue }
            if prev == nil { panes.append(a.pane) }
            last[a.pane] = a.status
            if fresh {
                if a.status == .working { out.append(.clear(a.pane)) }
                continue
            }
            if prev == a.status {
                continue
            } else if a.status == .blocked {
                if prev != nil { out.append(.needsInput(a)) }
            } else if a.status.ready && prev == .working {
                out.append(.finished(a))
            } else if prev != nil {
                out.append(.clear(a.pane))
            }
        }
        for pane in panes where !seen.contains(pane) {
            last[pane] = nil
            out.append(.clear(pane))
        }
        panes.removeAll { !seen.contains($0) }
        fresh = false
        return out
    }
}
