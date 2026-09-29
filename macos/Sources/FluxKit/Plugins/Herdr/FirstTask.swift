import Foundation

/// The first task of a new agent. The text goes as a prompt when the new
/// agent is ready for input. When the agent asks a question first, such
/// as whether it may trust the folder, the task waits until the user
/// answered and the agent is ready. The agent must stay ready with no
/// dialog for `hold`, because an agent can show the next dialog right
/// after the user answered the last one.
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
    /// Since when the agent is ready with no dialog, in system uptime.
    private var readyAt: TimeInterval?
    /// Since when the task waits for the pane in the agent list, in system uptime.
    private var missingSince: TimeInterval?

    /// How long the agent must stay ready with no dialog before the task goes.
    public static let hold: TimeInterval = 2
    /// How long the task waits for the new pane in the agent list, as long
    /// as a create waits for its answer.
    public static let appearLimit: TimeInterval = 60

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

    /// The time when the task can go, when the agent is ready now. Call
    /// `update` again then.
    public var due: TimeInterval? { readyAt.map { $0 + Self.hold } }

    /// The time when the task fails, when the agent list never had the
    /// pane. Call `update` again then.
    public var appearDue: TimeInterval? {
        guard !seen, !finished else { return nil }
        return missingSince.map { $0 + Self.appearLimit }
    }

    /// Takes the status of the agent at `now`, nil when the agent list does
    /// not have its pane, and whether the output on screen ends with a
    /// dialog. It returns true when the task must go now.
    public mutating func update(status: AgentStatus?, choices: Bool, now: TimeInterval) -> Bool {
        guard phase == .waiting || phase == .answering else { return false }
        guard let status else {
            if seen {
                phase = .failed("The agent stopped before it got the task.")
            } else if let missingSince, now - missingSince >= Self.appearLimit {
                phase = .failed("The agent did not appear.")
            } else if missingSince == nil {
                missingSince = now
            }
            readyAt = nil
            return false
        }
        seen = true
        if status == .blocked || choices {
            phase = .answering
            readyAt = nil
            return false
        }
        guard status.ready else {
            readyAt = nil
            return false
        }
        guard let readyAt else {
            self.readyAt = now
            return false
        }
        guard now - readyAt >= Self.hold else { return false }
        phase = .sending
        return true
    }

    /// Takes the answer to the prompt.
    public mutating func sent(error: String?) {
        guard phase == .sending else { return }
        phase = error.map(Phase.failed) ?? .sent
    }
}
