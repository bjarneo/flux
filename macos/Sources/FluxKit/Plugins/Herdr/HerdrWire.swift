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
/// ID, for example w5:p1.
public struct HerdrAgent: Sendable, Hashable, Identifiable {
    public var pane: String
    public var agent: String
    public var status: AgentStatus
    public var title: String
    public var project: String
    public var workspace: String

    public init(pane: String, agent: String, status: AgentStatus, title: String = "", project: String = "", workspace: String = "") {
        self.pane = pane
        self.agent = agent
        self.status = status
        self.title = title
        self.project = project
        self.workspace = workspace
    }

    public var id: String { pane }
}

/// What a computer reports about herdr. `enabled` is false when the
/// computer has `herdr = false` in its config.toml. `running` is true when
/// fluxd reaches the herdr server. `control` is true when the computer
/// accepts replies from this Mac.
public struct HerdrState: Sendable, Equatable {
    public var enabled: Bool
    public var running: Bool
    public var agents: [HerdrAgent]
    public var control: Bool

    public init(enabled: Bool, running: Bool, agents: [HerdrAgent], control: Bool = false) {
        self.enabled = enabled
        self.running = running
        self.agents = agents
        self.control = control
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
}

/// The recent output of one pane. `lines` keep the terminal colors, and
/// `text` is the same output without styles. `loading` is true while a read
/// waits for its answer. The old lines stay on screen until the new lines
/// come.
public struct HerdrOutput: Sendable, Equatable {
    public var pane: String
    public var loading: Bool
    public var lines: [TermLine] {
        didSet { derive() }
    }
    public var truncated: Bool
    public var error: String?
    public private(set) var text = ""
    /// The numbered choices of the dialog at the end of the output.
    public private(set) var choices: [AgentChoice] = []

    public init(pane: String, loading: Bool = true, lines: [TermLine] = [], truncated: Bool = false, error: String? = nil) {
        self.pane = pane
        self.loading = loading
        self.lines = lines
        self.truncated = truncated
        self.error = error
        derive()
    }

    private mutating func derive() {
        let plain = lines.map(\.text)
        text = plain.joined(separator: "\n")
        choices = AgentChoice.find(plain)
    }
}

/// The last reply to a pane. `action` is "keys" or "prompt". `sending` is
/// true until the computer answers. `seq` is different for each reply, so
/// the UI sees each answer.
public struct HerdrReply: Sendable, Equatable {
    public var pane: String
    public var action: String
    public var seq: Int
    public var sending: Bool
    public var error: String?

    public init(pane: String, action: String, seq: Int, sending: Bool = true, error: String? = nil) {
        self.pane = pane
        self.action = action
        self.seq = seq
        self.sending = sending
        self.error = error
    }
}

/// The answer of the computer to a reply: `{"kind":"sent"}`. `error` is nil
/// on success.
public struct HerdrSent: Sendable, Equatable {
    public var pane: String
    public var action: String
    public var error: String?
}

/// The flux.herdr messages. docs/herdr.md describes the wire format, and
/// internal/core/herdr.go in fluxd is the other side.
public enum HerdrWire {
    /// The key names that fluxd accepts in a keys packet.
    public static let allowedKeys: Set<String> = Set(["enter", "esc", "tab", "shift+tab", "up", "down", "left", "right", "backspace", "space", "y", "n"]
        + (0...9).map(String.init))
    /// The most keys in 1 keys packet.
    public static let maxKeys = 8
    /// The longest prompt, in UTF-8 bytes.
    public static let maxPrompt = 16 * 1024
    /// The number of lines that a read asks for. fluxd allows 1 to 400.
    public static let readLines = 200

    /// Asks the computer for its agent list. The computer answers with a state.
    public static func request() -> Packet { Packet(PacketType.fluxHerdr, ["kind": "request"]) }

    /// Asks for the recent output of a pane, with its colors.
    public static func read(pane: String) -> Packet {
        Packet(PacketType.fluxHerdr, ["kind": "read", "pane": pane, "lines": readLines, "format": "ansi"])
    }

    /// Sends key presses to the agent in a pane.
    public static func keys(pane: String, _ keys: [String]) -> Packet {
        Packet(PacketType.fluxHerdr, ["kind": "keys", "pane": pane, "keys": keys])
    }

    /// Sends text to the agent in a pane.
    public static func prompt(pane: String, _ text: String) -> Packet {
        Packet(PacketType.fluxHerdr, ["kind": "prompt", "pane": pane, "text": text])
    }

    /// True when fluxd accepts the keys in 1 keys packet.
    public static func allowed(_ keys: [String]) -> Bool {
        !keys.isEmpty && keys.count <= maxKeys && keys.allSatisfy { allowedKeys.contains($0) }
    }

    /// Parses the body of a state packet. It returns nil for a body that is not a state.
    public static func state(_ body: [String: JSONValue]) -> HerdrState? {
        guard body["kind"]?.string == "state" else { return nil }
        let agents: [HerdrAgent] = (body["agents"]?.array ?? []).compactMap { e in
            guard let o = e.object, let pane = o["pane"]?.string, !pane.isEmpty else { return nil }
            let name = o["agent"]?.string ?? ""
            return HerdrAgent(
                pane: pane,
                agent: name.isEmpty ? "agent" : name,
                status: AgentStatus(wire: o["status"]?.string),
                title: o["title"]?.string ?? "",
                project: o["project"]?.string ?? "",
                workspace: o["workspace"]?.string ?? ""
            )
        }
        let enabled = body["enabled"]?.bool ?? true
        return HerdrState(
            enabled: enabled,
            running: enabled && (body["running"]?.bool ?? false),
            agents: agents,
            control: enabled && (body["control"]?.bool ?? false)
        )
    }

    /// Parses the body of an output packet. It returns nil for a body that is not an output.
    public static func output(_ body: [String: JSONValue]) -> HerdrOutput? {
        guard body["kind"]?.string == "output", let pane = body["pane"]?.string, !pane.isEmpty else { return nil }
        let error = body["error"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        // An older fluxd sends plain text. It has no escape sequences, so the
        // same parser reads it.
        return HerdrOutput(
            pane: pane,
            loading: false,
            lines: error == nil ? TermText.lines(body["text"]?.string ?? "") : [],
            truncated: body["truncated"]?.bool ?? false,
            error: error
        )
    }

    /// Parses the body of a sent packet. It returns nil for a body that is not a sent answer.
    public static func sent(_ body: [String: JSONValue]) -> HerdrSent? {
        guard body["kind"]?.string == "sent", let pane = body["pane"]?.string, !pane.isEmpty else { return nil }
        return HerdrSent(pane: pane, action: body["action"]?.string ?? "", error: body["error"]?.string.flatMap { $0.isEmpty ? nil : $0 })
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
