import Foundation

/// The kinds of Inbox items, in the order of the Inbox. The first 3 kinds
/// need the user: an agent that waits for input, an approval, and a pair
/// request. Then come the kinds that the user can act on from the stack:
/// what plays now, the clipboard, and the transfers. The agents that are
/// done or that work come last. Nothing stores the order.
public enum InboxKind: Int, CaseIterable, Sendable, Comparable {
    case agentInput, approval, pairRequest, media, clipboard, transfer, agentDone, agentWorking

    /// True for the kinds that need the user.
    public var needsYou: Bool { self == .agentInput || self == .approval || self == .pairRequest }

    /// "AgentInput", "Approval", "PairRequest", "Media", "Clipboard",
    /// "Transfer", "AgentDone", or "AgentWorking", as on Android. Item keys use it.
    public var keyName: String {
        switch self {
        case .agentInput: return "AgentInput"
        case .approval: return "Approval"
        case .pairRequest: return "PairRequest"
        case .media: return "Media"
        case .clipboard: return "Clipboard"
        case .transfer: return "Transfer"
        case .agentDone: return "AgentDone"
        case .agentWorking: return "AgentWorking"
        }
    }

    public static func < (a: InboxKind, b: InboxKind) -> Bool { a.rawValue < b.rawValue }
}

/// The color role of the state of an item. The apps map it to the palette.
/// Red marks only what needs the user and errors.
public enum InboxTone: Sendable, Equatable {
    case red, green, accent, cyan, sub
}

/// 1 item of the Inbox. `key` stays the same while the item is the same,
/// so the UI keeps its place. `deviceIds` are the computers of the item. An
/// item with no computers shows in every scope.
public struct InboxItem: Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        /// A herdr agent that waits for input, finished, or works. `control`
        /// is true when the computer takes replies.
        case agent(deviceId: String, agent: HerdrAgent, control: Bool)
        /// A sudo, polkit, or enrollment request that waits for the fingerprint.
        case approval(ApproveRequest)
        /// A computer that is not paired and asks to pair.
        case pair(deviceId: String)
        /// A file that goes to or comes from a computer.
        case transfer(FileTransfer)
        /// The last clip that this device sent or received.
        case clip(ClipEvent)
        /// What a player on a computer plays now.
        case media(deviceId: String, player: RemotePlayer)
    }

    public var content: Content
    /// The name of the computer, or a count of computers.
    public var computer: String

    public init(_ content: Content, computer: String) {
        self.content = content
        self.computer = computer
    }

    public var kind: InboxKind {
        switch content {
        case .agent(_, let agent, _):
            switch agent.status {
            case .blocked: return .agentInput
            case .done: return .agentDone
            default: return .agentWorking
            }
        case .approval: return .approval
        case .pair: return .pairRequest
        case .transfer: return .transfer
        case .clip: return .clipboard
        case .media: return .media
        }
    }

    /// A new status of an agent is a new key, so an agent that waits again moves up again.
    public var key: String {
        switch content {
        case .agent(let deviceId, let agent, _): return "agent|\(deviceId)|\(agent.pane)|\(kind.keyName)"
        case .approval(let r): return "approve|\(r.computerId)|\(r.id)"
        case .pair(let deviceId): return "pair|\(deviceId)"
        case .transfer(let t): return "transfer|\(t.id.uuidString)"
        case .clip: return "clip"
        case .media(let deviceId, _): return "media|\(deviceId)"
        }
    }

    /// The computers of the item. A pair request has none, so it shows in every scope.
    public var deviceIds: Set<String> {
        switch content {
        case .agent(let deviceId, _, _): return [deviceId]
        case .approval(let r): return [r.computerId]
        case .pair: return []
        case .transfer(let t): return [t.deviceId]
        case .clip(let c): return Set(c.deviceIds)
        case .media(let deviceId, _): return [deviceId]
        }
    }

    public var id: String { key }
}

/// The text of an item, as in the Inbox of Flux for Android.
public extension InboxItem {
    /// The state as a short word in sentence case, for the window title and for VoiceOver.
    var stateWord: String {
        switch content {
        case .agent:
            switch kind {
            case .agentInput: return "Needs input"
            case .agentDone: return "Done"
            default: return "Working"
            }
        case .approval: return "Needs approval"
        case .pair: return "Pair request"
        case .transfer(let t):
            switch t.state {
            case .running: return t.incoming ? "Receiving" : "Sending"
            case .done: return t.incoming ? "Received" : "Sent"
            case .failed: return "Failed"
            }
        case .clip: return "Clipboard"
        case .media(_, let player): return player.playing ? "Playing" : "Paused"
        }
    }

    /// The color role of the state dot and the state word.
    var tone: InboxTone {
        if kind.needsYou { return .red }
        switch content {
        case .agent: return kind == .agentDone ? .green : .accent
        case .transfer(let t):
            switch t.state {
            case .running: return .accent
            case .done: return .green
            case .failed: return .red
            }
        case .clip: return .cyan
        case .media(_, let player): return player.playing ? .green : .sub
        case .approval, .pair: return .red
        }
    }

    /// The source of the item for its window title, without the computer:
    /// for example the agent and its project. Blank parts are dropped.
    var sourceParts: [String] {
        let parts: [String]
        switch content {
        case .agent(_, let agent, _): parts = [agent.agent, agent.project.isEmpty ? agent.workspace : agent.project]
        case .approval(let r): parts = [r.service]
        case .media(_, let player): parts = [player.name]
        case .pair, .transfer, .clip: parts = []
        }
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The title of a stack tile.
    var stackTitle: String {
        switch content {
        case .agent(_, let agent, _):
            if !agent.title.isEmpty { return agent.title }
            return agent.project.isEmpty ? agent.pane : agent.project
        case .approval(let r):
            return r.kind == .approve ? "Approve \(r.service)" : "Enroll \(FluxPlatform.current.deviceNoun)"
        case .pair: return computer
        case .transfer(let t): return t.name
        case .clip(let c):
            if c.image { return "An image" }
            return c.secret ? ClipEvent.hiddenText : c.preview
        case .media(_, let player): return player.title.isEmpty ? "Unknown title" : player.title
        }
    }

    /// The line under the title of a stack tile. The window title already holds the source and the state.
    var stackLine: String {
        switch content {
        case .agent: return computer
        case .approval(let r): return "\(r.user) on \(r.host)"
        case .pair: return "Compare the key to pair"
        case .transfer(let t): return t.incoming ? "From \(computer)" : "To \(computer)"
        case .clip(let c): return c.sent ? "Sent to \(computer)" : "From \(computer)"
        case .media(_, let player): return [player.artist, computer].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// The title of the master tile.
    var masterTitle: String {
        switch content {
        case .approval(let r):
            return r.kind == .approve ? "Approve \(r.service) on \(r.host)?"
                : "Enroll \(FluxPlatform.current.deviceNoun) on \(r.host)?"
        case .clip(let c): return c.sent ? "Sent to \(computer)" : "From \(computer)"
        case .agent, .pair, .transfer, .media: return stackTitle
        }
    }
}
