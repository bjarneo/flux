import Crypto
import Foundation

// The question of a blocked agent, for the notification of the agent and for
// the answer from it. This is a port of AgentDialogs.kt of the Android app,
// so that both apps read the same dialog and use the same dialog ID.

/// How many lines a dialog read asks for. This is the scan range of `AgentChoice.find`.
public let dialogReadLines = 40

/// How long a dialog read waits for the answer. A later answer is not used.
public let dialogReadTimeout: Duration = .seconds(3)

/// The lines above the choices that `AgentDialog` keeps.
private let dialogLines = 4

/// The question of a blocked agent. `question` is the line that asks, or
/// empty. `lines` are the lines above the choices, for example the command
/// that a choice approves. `choices` are the numbered choices or the menu
/// row, and the list is empty for a question with free text. `id` is the
/// first 16 hex digits of the SHA-256 of the question, the lines, and the
/// labels of the choices. `at` is the time of the read.
public struct AgentDialog: Sendable, Hashable {
    public var question: String
    public var lines: [String]
    public var choices: [AgentChoice]
    public var command: Bool
    public var id: String
    public var at: Date

    public init(question: String, lines: [String], choices: [AgentChoice], command: Bool, id: String, at: Date) {
        self.question = question
        self.lines = lines
        self.choices = choices
        self.command = command
        self.id = id
        self.at = at
    }
}

/// The ID of a dialog: the first 16 hex digits of the SHA-256 of its question, lines, and labels.
public func dialogId(question: String, lines: [String], labels: [String]) -> String {
    // The separator is a control character that a terminal line does not hold.
    let text = ([question] + lines + ["\u{1}"] + labels).joined(separator: "\u{0}")
    let hex = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(16))
}

/// Parses the dialog at the end of `out`. It returns nil for an output with
/// an error or with no lines. An output with no choices gives a dialog with
/// an empty choice list. Then the question is the last line that ends with a
/// question mark, or empty.
public func parseDialog(_ out: HerdrOutput, at: Date) -> AgentDialog? {
    if out.error != nil || out.lines.isEmpty { return nil }
    let texts = out.lines.map(\.text)
    let choices = out.choices
    let ask = AgentAsk.find(texts, maxLines: dialogLines)
    var question = ask?.question ?? ""
    if question.isEmpty {
        question = choices.isEmpty
            ? (texts.suffix(12).last { $0.trimmingCharacters(in: .whitespaces).hasSuffix("?") }?.trimmingCharacters(in: .whitespaces) ?? "")
            : ""
    }
    let lines = ask?.lines ?? []
    return AgentDialog(question: question, lines: lines, choices: choices, command: ask?.command ?? false,
                       id: dialogId(question: question, lines: lines, labels: choices.map(\.label)), at: at)
}

/// What `DialogBook` needs from the app. The tests replace it.
public protocol DialogIo: AnyObject {
    /// True while the agent screen of `pane` shows its output.
    func screenOpen(_ deviceId: String, _ pane: String) -> Bool

    /// True while the agent screen of `pane` waits for an answer.
    func screenReading(_ deviceId: String, _ pane: String) -> Bool

    /// Asks the agent screen to read `pane` again. It returns false when the computer is not reachable.
    func readScreen(_ deviceId: String, _ pane: String) -> Bool

    /// Sends a read of `pane` with a new request number. It calls `register`
    /// with the number before it returns, so that the answer cannot come
    /// first. It returns false when the computer is not reachable.
    func send(_ deviceId: String, _ pane: String, register: (Int) -> Void) -> Bool

    func now() -> Date

    /// Runs `task` after `delay`.
    func later(_ delay: Duration, _ task: @escaping () -> Void)

    /// Runs `task` outside the code that holds the book.
    func post(_ task: @escaping () -> Void)
}

/// Keeps the last dialog of each blocked pane and reads a dialog on request.
/// It keeps at most 1 read of a pane in flight, because fluxd answers only
/// the newest read of a pane. When the agent screen of the pane is open, the
/// read goes through that screen, so the screen and the notification share
/// 1 answer. Else the read has its own request number, and its answer does
/// not replace the output of a screen. Use it from 1 thread. The app uses it on the main actor.
public final class DialogBook {
    private final class Wait {
        let key: String
        var callbacks: [(AgentDialog?) -> Void] = []
        /// The request number of the read, or nil for a read of the screen or before the send.
        var request: Int?

        init(_ key: String) { self.key = key }
    }

    private let io: DialogIo
    private var waits: [String: Wait] = [:]
    private var last: [String: AgentDialog] = [:]

    public init(io: DialogIo) { self.io = io }

    private func key(_ deviceId: String, _ pane: String) -> String { "\(deviceId)|\(pane)" }

    /// The last dialog that a read found for `pane`, or nil.
    public func latest(_ deviceId: String, _ pane: String) -> AgentDialog? { last[key(deviceId, pane)] }

    /// Forgets the dialog of `pane`, for example when the agent is no longer blocked.
    public func forget(_ deviceId: String, _ pane: String) {
        last[key(deviceId, pane)] = nil
    }

    /// True when an output of `pane` with the request number `request` is
    /// the answer to a read of this book, and `onOutput` takes it. An older
    /// fluxd sends no request number, so the pane is the match. A read
    /// through an open screen has no request number of its own, so
    /// `onScreenOutput` takes its answer.
    public func takes(_ deviceId: String, _ pane: String, request: Int?) -> Bool {
        guard let wait = waits[key(deviceId, pane)], let own = wait.request else { return false }
        return request == nil || request == own
    }

    /// True while a read of `pane` waits.
    public func waiting(_ deviceId: String, _ pane: String) -> Bool { waits[key(deviceId, pane)] != nil }

    /// Reads the dialog of `pane` and calls `done` with it. `done` gets nil
    /// when the read fails, takes more than `timeout`, or finds no dialog.
    /// A second call while a read waits joins that read.
    public func peek(_ deviceId: String, _ pane: String, timeout: Duration = dialogReadTimeout, done: @escaping (AgentDialog?) -> Void) {
        let k = key(deviceId, pane)
        if let wait = waits[k] {
            wait.callbacks.append(done)
            return
        }
        let wait = Wait(k)
        wait.callbacks.append(done)
        waits[k] = wait
        let sent: Bool
        if io.screenOpen(deviceId, pane) {
            sent = io.screenReading(deviceId, pane) || io.readScreen(deviceId, pane)
        } else {
            sent = io.send(deviceId, pane) { wait.request = $0 }
        }
        if !sent {
            finish(wait, nil)
            return
        }
        io.later(timeout) { [weak self] in self?.finish(wait, nil) }
    }

    /// Reads the dialog again and calls `onSame` with the new dialog when
    /// its ID is `id`. Else it calls `onChanged` with the new dialog, or
    /// with nil when the read failed. Thus a caller sends only the choice of
    /// the new read, and a menu choice gets the arrows from the new selection.
    public func verify(_ deviceId: String, _ pane: String, id: String, timeout: Duration = dialogReadTimeout,
                       onSame: @escaping (AgentDialog) -> Void, onChanged: @escaping (AgentDialog?) -> Void) {
        peek(deviceId, pane, timeout: timeout) { d in
            if let d, d.id == id { onSame(d) } else { onChanged(d) }
        }
    }

    /// Takes an output that answers a read of this book. It returns true
    /// when it took the output, and then the screen must not use it.
    @discardableResult
    public func onOutput(_ deviceId: String, _ out: HerdrOutput) -> Bool {
        guard let wait = waits[key(deviceId, out.pane)], let request = wait.request else { return false }
        // An older fluxd sends no request number, so the pane is the match.
        if let r = out.request, r != request { return false }
        finish(wait, out)
        return true
    }

    /// Takes the output that the agent screen of a pane accepted, for the reads that went through the screen.
    public func onScreenOutput(_ deviceId: String, _ out: HerdrOutput) {
        guard let wait = waits[key(deviceId, out.pane)], wait.request == nil, !out.loading else { return }
        finish(wait, out)
    }

    private func finish(_ wait: Wait, _ out: HerdrOutput?) {
        let dialog = out.flatMap { parseDialog($0, at: io.now()) }
        guard waits[wait.key] === wait else { return }
        waits[wait.key] = nil
        if let dialog { last[wait.key] = dialog }
        let callbacks = wait.callbacks
        io.post { callbacks.forEach { $0(dialog) } }
    }
}

/// True when a Reply may send its text: the new read `d` has no choices and
/// its ID is `dialogId`, the dialog of the notification.
public func replyMatches(_ d: AgentDialog?, _ dialogId: String) -> Bool {
    guard let d else { return false }
    return !dialogId.isEmpty && d.choices.isEmpty && d.id == dialogId
}
