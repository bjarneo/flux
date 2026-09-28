import Foundation

/// The first task of a new agent. The text goes as a prompt when the new
/// agent is ready for input. When the agent asks a question first, such
/// as whether it may trust the folder, the task waits until the user
/// answered and the agent is ready.
public struct FirstTask: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// The computer starts the agent.
        case starting
        /// The agent runs and is not ready yet.
        case waiting
        /// The agent asks a question. The task goes after the answer.
        case answering
        /// The prompt went, and the computer did not answer yet.
        case sending
        /// The agent got the task.
        case sent
        /// The task did not go, for this reason.
        case failed(String)
    }

    /// The prompt, without blanks at its ends.
    public let text: String
    /// The number of the create of the agent, see `HerdrAction.seq`.
    public let action: Int
    /// The pane of the new agent, when the computer reported it.
    public private(set) var pane: String?
    public private(set) var phase = Phase.starting
    /// The number of the prompt reply, see `HerdrReply.seq`.
    var reply: Int?
    /// True after the agent list had the pane.
    private var seen = false

    public init(text: String, action: Int = 0) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.action = action
    }

    /// True when the task went or failed.
    public var finished: Bool {
        switch phase {
        case .sent, .failed: return true
        default: return false
        }
    }

    /// Takes the answer to the create: the new pane, or why the agent did not start.
    public mutating func created(pane: String?, error: String?) {
        guard phase == .starting else { return }
        if let error {
            phase = .failed(error)
        } else if let pane {
            self.pane = pane
            phase = .waiting
        } else {
            phase = .failed("The computer did not report the new agent.")
        }
    }

    /// Takes the status of the agent, nil when the agent list does not have
    /// its pane, and whether the output on screen ends with a dialog. It
    /// returns true when the task must go now.
    public mutating func update(status: AgentStatus?, choices: Bool) -> Bool {
        guard phase == .waiting || phase == .answering else { return false }
        guard let status else {
            if seen { phase = .failed("The agent stopped before it got the task.") }
            return false
        }
        seen = true
        if status == .blocked || choices {
            phase = .answering
            return false
        }
        guard status.ready else { return false }
        phase = .sending
        return true
    }

    /// Takes the answer to the prompt.
    public mutating func sent(error: String?) {
        guard phase == .sending else { return }
        phase = error.map(Phase.failed) ?? .sent
    }
}
