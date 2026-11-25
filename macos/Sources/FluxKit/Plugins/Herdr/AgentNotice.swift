import Foundation

// The text and the actions of the notification of an agent. This is a port
// of AgentNotice.kt of the Android app, so that all apps give the same
// actions for the same dialog. See decision 002 for the rule of the actions.

/// How a notification action acts. `choice` sends a choice, `reply` sends
/// the text of the user, and `open` opens the thread.
public enum NoticeKind: Sendable, Equatable {
    case choice, reply, open
}

/// One action of the agent notification. `key` is the number of the choice
/// for a `.choice`, or empty.
public struct NoticeAction: Sendable, Equatable {
    public var kind: NoticeKind
    public var label: String
    public var key: String

    public init(_ kind: NoticeKind, _ label: String, _ key: String) {
        self.kind = kind
        self.label = label
        self.key = key
    }
}

/// The text of the notification of an agent. `text` is the line of the
/// collapsed notification, and `bigText` is the expanded text with each
/// choice in full. `dialogId` is the ID of the dialog that the texts came
/// from, or empty. The actions carry it, so that the ID and the labels match.
public struct AgentNotice: Sendable, Equatable {
    public var title: String
    public var text: String
    public var bigText: String
    public var actions: [NoticeAction]
    public var dialogId: String

    public init(title: String, text: String, bigText: String, actions: [NoticeAction], dialogId: String = "") {
        self.title = title
        self.text = text
        self.bigText = bigText
        self.actions = actions
        self.dialogId = dialogId
    }
}

/// The longest label of an action, in characters.
public let actionLabelMax = 24

/// The words that end the text of a notification of a computer with Agent control off.
public let readOnlyText = "Read only"

/// The most choices that get 1 action each.
private let maxChoiceActions = 3

/// Cuts `label` at a word end to `max` characters, and adds an ellipsis when it cuts.
public func cutLabel(_ label: String, max: Int = actionLabelMax) -> String {
    let t = Array(label.trimmingCharacters(in: .whitespacesAndNewlines))
    if t.count <= max { return String(t) }
    // The label may end exactly at the limit, so the next character must be a space.
    let head = Array(t[0...max])
    let cut: [Character]
    if let space = head.lastIndex(of: " "), space > 0 {
        cut = Array(head[0..<space])
    } else {
        cut = Array(t[0..<max])
    }
    var end = cut.count
    while end > 0, ",;:. ".contains(cut[end - 1]) { end -= 1 }
    return String(cut[0..<end]) + "…"
}

/// The line of a dialog for the notification: the first line above the
/// choices, for example the command, and then the question.
private func summary(_ dialog: AgentDialog) -> String {
    let first = dialog.lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let head = first.isEmpty || ".?!".contains(first.last!) ? first : first + "."
    return [head, dialog.question.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: " ")
}

/// Builds the notification of `agent`. `dialog` is the dialog that the last
/// read found, or nil. `control` is true when the computer accepts input
/// from this device.
///
/// A blocked agent with 2 or 3 choices gets 1 action for each choice. A
/// blocked agent with no choices gets Reply. Other agents get no action.
/// With `control` off, the text ends with Read only and the notification
/// has no action.
public func agentNotice(_ agent: HerdrAgent, dialog: AgentDialog?, control: Bool) -> AgentNotice {
    let place = [agent.project, agent.workspace, agent.pane].first { !$0.isEmpty } ?? agent.pane
    if agent.status != .blocked {
        return AgentNotice(title: "\(agent.agent) in \(place) finished", text: agent.title, bigText: agent.title, actions: [])
    }
    let question = dialog.map(summary).flatMap { $0.isEmpty ? nil : $0 } ?? agent.title
    let numbered = (dialog?.choices ?? []).map { "\($0.key). \($0.label)" }.joined(separator: "\n")
    let suffix = control ? "" : readOnlyText
    let text = [question, suffix].filter { !$0.isEmpty }.joined(separator: " ")
    var big = [question, numbered].filter { !$0.isEmpty }.joined(separator: "\n")
    if !suffix.isEmpty { big = big.isEmpty ? suffix : big + "\n" + suffix }
    var actions: [NoticeAction] = []
    var reply = false
    if control, let dialog {
        let n = dialog.choices.count
        if (2...maxChoiceActions).contains(n) {
            actions = dialog.choices.map { NoticeAction(.choice, cutLabel($0.label), $0.key) }
        } else if n == 0 {
            reply = true
            actions = [NoticeAction(.reply, "Reply", "")]
        }
    }
    let title = reply ? "\(agent.agent) in \(place) asks a question" : "\(agent.agent) in \(place) needs input"
    return AgentNotice(title: title, text: text, bigText: big, actions: actions, dialogId: dialog?.id ?? "")
}
