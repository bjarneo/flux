import Foundation
import Observation
import UserNotifications

/// The herdr agents of each computer for the UI. `HerdrPlugin` changes it
/// on the main actor.
@MainActor
@Observable
public final class HerdrModel {
    /// The agents of each computer by device ID. A computer has no entry
    /// before its first agent list.
    public internal(set) var states: [String: HerdrState] = [:]
    /// The output of the agent that the agents window of a computer shows.
    public internal(set) var outputs: [String: HerdrOutput] = [:]
    /// The last reply from the agents window of a computer.
    public internal(set) var replies: [String: HerdrReply] = [:]
    /// The last new agent, new terminal, or close on a computer.
    public internal(set) var actions: [String: HerdrAction] = [:]
    /// The first task of the last new agent on a computer.
    public internal(set) var firstTasks: [String: FirstTask] = [:]

    /// Notify when an agent on a computer needs input. It applies to all computers.
    public var inputAlerts = true {
        didSet { defaults?.set(inputAlerts, forKey: HerdrPlugin.inputAlertsKey) }
    }
    /// Notify when an agent on a computer finishes. It applies to all computers.
    public var doneAlerts = true {
        didSet { defaults?.set(doneAlerts, forKey: HerdrPlugin.doneAlertsKey) }
    }
    /// The dictation language as a tag such as de-DE. Empty means Automatic.
    public var dictationLanguage = "" {
        didSet { defaults?.set(dictationLanguage, forKey: HerdrPlugin.dictationLanguageKey) }
    }

    /// Opens the output of an agent: the device ID and the pane. The app sets
    /// it, and a click on an agent notification calls it.
    @ObservationIgnored public var open: (@MainActor (_ deviceId: String, _ pane: String) -> Void)?

    @ObservationIgnored private var defaults: UserDefaults?

    init() {}

    func load(_ defaults: UserDefaults) {
        inputAlerts = defaults.object(forKey: HerdrPlugin.inputAlertsKey) as? Bool ?? true
        doneAlerts = defaults.object(forKey: HerdrPlugin.doneAlertsKey) as? Bool ?? true
        dictationLanguage = defaults.string(forKey: HerdrPlugin.dictationLanguageKey) ?? ""
        self.defaults = defaults
    }

    /// The output of `pane` on a computer, or nil when the window shows no output of it.
    public func output(_ deviceId: String, pane: String) -> HerdrOutput? {
        outputs[deviceId].flatMap { $0.pane == pane ? $0 : nil }
    }

    /// The last reply to `pane` on a computer.
    public func reply(_ deviceId: String, pane: String) -> HerdrReply? {
        replies[deviceId].flatMap { $0.pane == pane ? $0 : nil }
    }
}

/// flux.herdr in both directions. fluxd sends the coding agents that herdr
/// runs on the computer, and this Mac asks for the recent output of an
/// agent. When the computer allows it, this device also sends keys and
/// prompts to an agent, starts agents, and closes them. When the computer
/// allows terminals, it also opens terminals and types in them. The app asks for Touch ID or the password before the first
/// reply. docs/herdr.md describes the feature and the wire format.
public final class HerdrPlugin: FluxPlugin, @unchecked Sendable {
    public static let notificationCategory = "herdr"
    static let deviceKey = "device"
    static let paneKey = "pane"
    static let inputAlertsKey = "herdr.inputAlerts"
    static let doneAlertsKey = "herdr.doneAlerts"
    static let dictationLanguageKey = "herdr.dictationLanguage"

    /// How long a finished agent must stay ready before this Mac posts it.
    /// The status can change between tool calls.
    static let finishHold: Duration = .seconds(2)
    /// How long a read waits for the output. fluxd can take 10 seconds to
    /// collect the history of an agent.
    static let readTimeout: Duration = .seconds(15)
    /// How long a new agent or terminal waits. fluxd waits up to 45 seconds
    /// for herdr to start an agent.
    static let createTimeout: Duration = .seconds(60)
    /// How long a reply waits for the answer of the computer.
    static let replyTimeout: Duration = .seconds(10)
    /// How long a close waits for the answer of the computer.
    static let closeTimeout: Duration = .seconds(10)
    /// How long this Mac waits after a reply before it reads the output
    /// again. The agent needs a moment to draw.
    static let rereadDelay: Duration = .milliseconds(700)

    public let incoming = [PacketType.fluxHerdr]
    public let outgoing = [PacketType.fluxHerdr]
    public let model: HerdrModel
    private weak var core: FluxCore?

    @MainActor private var trackers: [String: HerdrTracker] = [:]
    /// The finished notifications that wait for `finishHold`, by device ID and pane.
    @MainActor private var pending: [String: Task<Void, Never>] = [:]
    /// Counts the reads of each computer and all replies, so that a late
    /// timeout does not replace a newer answer. A read of 1 computer does
    /// not cancel the read timeout of another computer.
    @MainActor private var reads: [String: Int] = [:]
    @MainActor private var replies = 0
    /// Counts the creates and the closes, so that a late timeout does not
    /// replace a newer one.
    @MainActor private var actions = 0
    /// The time in seconds for the first task. Tests set their own.
    @MainActor var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Counts the output parses of each computer, so that an older parse
    /// that ends late does not replace a newer output.
    @MainActor private var parses: [String: Int] = [:]

    @MainActor
    public init() { model = HerdrModel() }

    public func attach(core: FluxCore) {
        self.core = core
        let defaults = core.defaults
        let model = model
        DispatchQueue.main.async { MainActor.assumeIsolated { model.load(defaults) } }
        Notifier.shared.register(category: Self.notificationCategory) { action, info, _ in
            guard action == UNNotificationDefaultActionIdentifier,
                  let id = info[Self.deviceKey] as? String, let pane = info[Self.paneKey] as? String else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { model.open?(id, pane) } }
        }
    }

    /// The next agent list sets the start values, so a reconnect posts nothing.
    public func onConnected(_ device: Device) {
        let id = device.id
        DispatchQueue.main.async { MainActor.assumeIsolated { self.trackers[id, default: HerdrTracker()].restart() } }
    }

    /// The core lock is held. The main queue keeps the order of the packets.
    public func handle(_ packet: Packet, from device: Device) {
        let id = device.id
        let name = device.name
        DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(packet, deviceId: id, computer: name) } }
    }

    @MainActor
    func receive(_ p: Packet, deviceId: String, computer: String) {
        switch p.string("kind") {
        case "state":
            guard let state = HerdrWire.state(p.body) else { return }
            model.states[deviceId] = state
            let alerts = trackers[deviceId, default: HerdrTracker()].update(state.agents)
            alert(alerts, deviceId: deviceId, computer: computer)
            advanceFirstTask(deviceId)
        case "output":
            // Only the pane on screen keeps its output. The check reads the
            // pane before the parse, and the parse of up to 1 MiB of text
            // runs off the main actor.
            guard let pane = p.body["pane"]?.string, !pane.isEmpty, model.outputs[deviceId]?.pane == pane else { return }
            let parse = (parses[deviceId] ?? 0) + 1
            parses[deviceId] = parse
            let body = p.body
            Task.detached { [weak self] in
                guard let out = HerdrWire.output(body) else { return }
                await self?.show(out, deviceId: deviceId, parse: parse)
            }
        case "sent":
            // A newer fluxd sends back the number of the reply. A late answer
            // to an earlier reply then does not end a newer one. An answer
            // without a number matches by the pane, as before.
            guard let sent = HerdrWire.sent(p.body) else { return }
            if sent.action == "prompt", var task = model.firstTasks[deviceId], task.phase == .sending, task.pane == sent.pane,
               sent.request == nil || sent.request == task.reply {
                task.sent(error: sent.error)
                model.firstTasks[deviceId] = task
            }
            guard var reply = model.replies[deviceId], reply.pane == sent.pane, reply.sending,
                  sent.request == nil || sent.request == reply.seq else { return }
            reply.sending = false
            reply.error = sent.error
            reply.code = sent.error == nil ? nil : sent.code
            model.replies[deviceId] = reply
            guard sent.error == nil else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.rereadDelay)
                guard let self, self.model.outputs[deviceId]?.pane == sent.pane else { return }
                self.read(deviceId, pane: sent.pane)
            }
        case "created", "closed":
            guard let done = HerdrWire.done(p.body), var action = model.actions[deviceId],
                  action.action == done.action, action.sending else { return }
            if done.action == "close" && action.pane != done.pane { return }
            // A late answer to an earlier create or close does not end this one.
            if let request = done.request, request != action.seq { return }
            action.sending = false
            action.pane = done.pane ?? action.pane
            action.error = done.error
            model.actions[deviceId] = action
            settleFirstTask(deviceId, action)
        default:
            FluxLog.plugin.debug("herdr: ignored kind \(p.string("kind") ?? "", privacy: .public)")
        }
    }

    /// Shows a parsed output, unless a newer output of the computer came
    /// or the window shows another pane now.
    @MainActor
    private func show(_ out: HerdrOutput, deviceId: String, parse: Int) {
        guard parses[deviceId] == parse, model.outputs[deviceId]?.pane == out.pane else { return }
        model.outputs[deviceId] = out
        advanceFirstTask(deviceId)
    }

    // MARK: Requests

    /// Asks the computer for its agent list now.
    @MainActor
    public func request(_ deviceId: String) {
        core?.send(HerdrWire.request(), to: deviceId)
    }

    /// Asks the computer for the recent output of `pane`. The output of the
    /// last read stays on screen until the answer comes.
    @MainActor
    public func read(_ deviceId: String, pane: String) {
        var out = model.output(deviceId, pane: pane) ?? HerdrOutput(pane: pane)
        out.loading = true
        out.error = nil
        model.outputs[deviceId] = out
        guard core?.send(HerdrWire.read(pane: pane), to: deviceId) == true else {
            model.outputs[deviceId]?.loading = false
            model.outputs[deviceId]?.error = "\(computerName(deviceId)) is not reachable"
            return
        }
        let token = reads[deviceId, default: 0] + 1
        reads[deviceId] = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.readTimeout)
            guard let self, token == self.reads[deviceId], let out = self.model.output(deviceId, pane: pane), out.loading else { return }
            self.model.outputs[deviceId]?.loading = false
            self.model.outputs[deviceId]?.error = "\(self.computerName(deviceId)) did not answer"
        }
    }

    /// Reads the output of `pane` again, unless the last read did not end.
    /// The polls of the screens use it, so that reads do not pile up on a
    /// slow link. A manual refresh uses `read`.
    @MainActor
    public func poll(_ deviceId: String, pane: String) {
        guard model.output(deviceId, pane: pane)?.loading != true else { return }
        read(deviceId, pane: pane)
    }

    /// Forgets the output and the last reply when the window stops showing the agent.
    @MainActor
    public func closeOutput(_ deviceId: String, pane: String) {
        if model.outputs[deviceId]?.pane == pane { model.outputs[deviceId] = nil }
        if model.replies[deviceId]?.pane == pane { model.replies[deviceId] = nil }
    }

    /// Sends key presses to the agent in `pane`, for example "2" to select
    /// the second choice of a dialog. Only the keys that fluxd allows go out.
    @MainActor
    public func sendKeys(_ deviceId: String, pane: String, _ keys: [String]) {
        guard HerdrWire.allowed(keys) else { return }
        reply(deviceId, pane: pane, action: "keys", HerdrWire.keys(pane: pane, keys))
    }

    /// Sends `text` to the agent in `pane`. The computer submits it as a
    /// prompt. fluxd refuses a prompt to an agent that waits for a choice,
    /// with the error "The agent waits for a choice. Pick a choice first."
    /// and the code "blocked", see `HerdrReply.blocked`. With `answer`,
    /// fluxd types the text into the dialog. Set `answer` only from an
    /// action where the user chose to type an answer.
    @MainActor
    public func sendPrompt(_ deviceId: String, pane: String, _ text: String, answer: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard t.utf8.count <= HerdrWire.maxPrompt else {
            replies += 1
            model.replies[deviceId] = HerdrReply(pane: pane, action: "prompt", seq: replies, sending: false,
                                                 error: "The text is too long. The limit is 16 KB.")
            return
        }
        reply(deviceId, pane: pane, action: "prompt", HerdrWire.prompt(pane: pane, t, answer: answer), text: t)
    }

    /// Types `text` in the terminal `pane`, then sends `keys`, for example
    /// "ls" and "enter". Only the keys that fluxd allows go out.
    @MainActor
    public func sendInput(_ deviceId: String, pane: String, text: String, keys: [String]) {
        guard HerdrWire.allowedInput(text: text, keys: keys) else { return }
        guard text.utf8.count <= HerdrWire.maxPrompt else {
            replies += 1
            model.replies[deviceId] = HerdrReply(pane: pane, action: "input", seq: replies, sending: false,
                                                 error: "The text is too long. The limit is 16 KB.")
            return
        }
        reply(deviceId, pane: pane, action: "input", HerdrWire.input(pane: pane, text: text, keys: keys))
    }

    /// Asks the computer to open a pane: an agent of `kind` when `what` is
    /// "agent", or a shell when it is "terminal". The pane opens in `cwd`,
    /// as a new tab of `workspace`, or in a new workspace when `workspace`
    /// is empty. `model.actions` has the answer. A new agent gets `task` as
    /// its first prompt when it is ready, see `FirstTask`.
    @MainActor
    public func create(_ deviceId: String, what: String, kind: String, cwd: String, workspace: String, task: String? = nil) {
        let text = what == "agent" ? task?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        if !text.isEmpty {
            // The task belongs to the next action.
            model.firstTasks[deviceId] = FirstTask(text: text, action: actions + 1)
        } else {
            model.firstTasks[deviceId] = nil
        }
        action(deviceId, HerdrAction(action: "create", seq: 0, what: what), timeout: Self.createTimeout,
               HerdrWire.create(what: what, agent: kind, cwd: cwd, workspace: workspace))
    }

    /// Forgets the first task of the last new agent, after the UI showed its end.
    @MainActor
    public func clearFirstTask(_ deviceId: String) {
        model.firstTasks[deviceId] = nil
    }

    /// Asks the computer to close `pane`. The agent or the shell in it ends.
    @MainActor
    public func close(_ deviceId: String, pane: String) {
        action(deviceId, HerdrAction(action: "close", seq: 0, pane: pane), timeout: Self.closeTimeout, HerdrWire.close(pane: pane))
    }

    /// Forgets the last create or close, after the UI used its answer.
    @MainActor
    public func clearAction(_ deviceId: String, seq: Int) {
        if model.actions[deviceId]?.seq == seq { model.actions[deviceId] = nil }
    }

    @MainActor
    private func action(_ deviceId: String, _ start: HerdrAction, timeout: Duration, _ packet: Packet) {
        actions += 1
        let seq = actions
        var a = start
        a.seq = seq
        model.actions[deviceId] = a
        guard core?.send(HerdrWire.numbered(packet, request: seq), to: deviceId) == true else {
            a.sending = false
            a.error = "\(computerName(deviceId)) is not reachable"
            model.actions[deviceId] = a
            settleFirstTask(deviceId, a)
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, var a = self.model.actions[deviceId], a.seq == seq, a.sending else { return }
            a.sending = false
            a.error = "\(self.computerName(deviceId)) did not answer"
            self.model.actions[deviceId] = a
            self.settleFirstTask(deviceId, a)
        }
    }

    // MARK: First task

    /// Gives the answer to a create to the first task of that create.
    @MainActor
    private func settleFirstTask(_ deviceId: String, _ action: HerdrAction) {
        guard action.action == "create", var task = model.firstTasks[deviceId], task.action == action.seq else { return }
        task.created(pane: action.pane, error: action.error)
        model.firstTasks[deviceId] = task
        advanceFirstTask(deviceId)
    }

    /// Sends the first task when its agent stayed ready for
    /// `FirstTask.hold`. The output on screen counts when it is of the new
    /// agent, so a dialog there holds the task. When the agent becomes
    /// ready, the output is read again, and the task is checked again at
    /// the end of the hold, and at the deadline for the pane to appear.
    @MainActor
    private func advanceFirstTask(_ deviceId: String) {
        guard var task = model.firstTasks[deviceId], let pane = task.pane else { return }
        let out = model.output(deviceId, pane: pane)
        let (before, appearBefore) = (task.due, task.appearDue)
        let go = task.update(status: model.states[deviceId]?.agent(pane)?.status, choices: !(out?.choices.isEmpty ?? true), now: clock())
        model.firstTasks[deviceId] = task
        if let due = task.appearDue, due != appearBefore {
            // The agent list may never have the pane: check again at the deadline.
            let wait = max(0, due - clock()) + 0.05
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.advanceFirstTask(deviceId)
            }
        }
        if let due = task.due, due != before {
            if out != nil { read(deviceId, pane: pane) }
            let wait = max(0, due - clock()) + 0.05
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.advanceFirstTask(deviceId)
            }
        }
        guard go else { return }
        task.reply = reply(deviceId, pane: pane, action: "prompt", HerdrWire.prompt(pane: pane, task.text))
        // The reply fails at once when the computer is not reachable.
        if let r = model.replies[deviceId], r.seq == task.reply, !r.sending { task.sent(error: r.error) }
        model.firstTasks[deviceId] = task
    }

    /// Sends a reply and returns its number. The packet gets the number,
    /// see `HerdrWire.numbered`. `text` is the text of a prompt.
    @MainActor
    @discardableResult
    private func reply(_ deviceId: String, pane: String, action: String, _ packet: Packet, text: String? = nil) -> Int {
        replies += 1
        let seq = replies
        model.replies[deviceId] = HerdrReply(pane: pane, action: action, seq: seq, text: text)
        guard core?.send(HerdrWire.numbered(packet, request: seq), to: deviceId) == true else {
            model.replies[deviceId] = HerdrReply(pane: pane, action: action, seq: seq, sending: false,
                                                 error: "\(computerName(deviceId)) is not reachable", text: text)
            return seq
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.replyTimeout)
            guard let self else { return }
            let error = "\(self.computerName(deviceId)) did not answer"
            if var task = self.model.firstTasks[deviceId], task.reply == seq, task.phase == .sending {
                task.sent(error: error)
                self.model.firstTasks[deviceId] = task
            }
            guard var r = self.model.replies[deviceId], r.seq == seq, r.sending else { return }
            r.sending = false
            r.error = error
            self.model.replies[deviceId] = r
        }
        return seq
    }

    private func computerName(_ deviceId: String) -> String { core?.withDevice(deviceId) { $0.name } ?? "The computer" }

    // MARK: Notifications

    static func notificationId(_ deviceId: String, _ pane: String) -> String { "herdr-\(deviceId)-\(pane)" }

    /// Posts and removes the notifications for `alerts`.
    @MainActor
    private func alert(_ alerts: [AgentAlert], deviceId: String, computer: String) {
        for a in alerts {
            let key = "\(deviceId)|\(a.pane)"
            pending.removeValue(forKey: key)?.cancel()
            switch a {
            case .clear(let pane):
                Notifier.shared.remove(id: Self.notificationId(deviceId, pane))
            case .needsInput(let agent):
                if model.inputAlerts { post(agent, deviceId: deviceId, computer: computer) }
            case .finished(let agent):
                guard model.doneAlerts else {
                    Notifier.shared.remove(id: Self.notificationId(deviceId, agent.pane))
                    continue
                }
                pending[key] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.finishHold)
                    guard !Task.isCancelled, let self else { return }
                    self.pending[key] = nil
                    // The agent must still be ready after the hold.
                    guard let now = self.model.states[deviceId]?.agent(agent.pane), now.status.ready, self.model.doneAlerts else { return }
                    self.post(now, deviceId: deviceId, computer: computer)
                }
            }
        }
    }

    /// Shows that an agent needs input or finished. Each pane has 1
    /// notification, and a click opens the output of the agent.
    @MainActor
    private func post(_ agent: HerdrAgent, deviceId: String, computer: String) {
        let place = [agent.project, agent.workspace, agent.pane].first { !$0.isEmpty } ?? agent.pane
        let blocked = agent.status == .blocked
        Notifier.shared.post(
            id: Self.notificationId(deviceId, agent.pane),
            category: Self.notificationCategory,
            title: blocked ? "\(agent.agent) in \(place) needs input" : "\(agent.agent) in \(place) finished",
            body: agent.title,
            subtitle: computer,
            userInfo: [Self.deviceKey: deviceId, Self.paneKey: agent.pane]
        )
    }
}
