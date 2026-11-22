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
    /// The output that the Inbox reads for the question of 1 agent, by
    /// `promptKey`. It is apart from `outputs`, so that the Inbox and an
    /// agent screen do not replace each other's output.
    public internal(set) var prompts: [String: HerdrOutput] = [:]
    /// The time that each agent got its status, by device ID and pane. See `AgentClock`.
    public internal(set) var since: [String: [String: Date]] = [:]
    /// The herdr session that the user picked for the agent list of each
    /// computer, by device ID. A computer without an entry shows the default
    /// session. The choice stays while its session is gone, and the list
    /// shows the default session meanwhile, see `session(_:)`.
    public internal(set) var sessionChoices: [String: String] = [:]

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

    /// The agents whose thread shows "The question changed. Pick again.", by
    /// `promptKey`. An answer from a notification sets it when the agent
    /// asks another question. The thread clears it when it closes.
    public internal(set) var questionChanged: Set<String> = []

    /// Opens the output of an agent: the device ID and the pane. The app sets
    /// it, and a click on an agent notification calls it.
    @ObservationIgnored public var open: (@MainActor (_ deviceId: String, _ pane: String) -> Void)?

    /// Asks for the unlock of the app, then calls `action`. `computer` is
    /// the name of the computer that the answer goes to. The app sets it
    /// with its Touch ID, Face ID, or password check, which stays valid for
    /// 5 minutes. `onError` gets a message when the check fails.
    /// `onCancel` runs when the user cancels the check. Without this
    /// closure, an answer from a notification sends nothing and opens the
    /// thread.
    @ObservationIgnored public var unlock: (@MainActor (_ computer: String, _ action: @escaping @MainActor () -> Void,
                                                         _ onError: @escaping @MainActor (String) -> Void,
                                                         _ onCancel: @escaping @MainActor () -> Void) -> Void)?

    @ObservationIgnored private var defaults: UserDefaults?

    init() {}

    func load(_ defaults: UserDefaults) {
        inputAlerts = defaults.object(forKey: HerdrPlugin.inputAlertsKey) as? Bool ?? true
        doneAlerts = defaults.object(forKey: HerdrPlugin.doneAlertsKey) as? Bool ?? true
        dictationLanguage = defaults.string(forKey: HerdrPlugin.dictationLanguageKey) ?? ""
        sessionChoices = defaults.dictionary(forKey: HerdrPlugin.sessionsKey) as? [String: String] ?? [:]
        self.defaults = defaults
    }

    /// The herdr session that the agent list of a computer shows: the
    /// picked session while the computer has it, else the default session.
    /// Nil before the first agent list.
    public func session(_ deviceId: String) -> HerdrSession? {
        states[deviceId]?.session(sessionChoices[deviceId])
    }

    /// The agents, terminals, and workspaces of a computer in the session
    /// that its agent list shows, see `HerdrState.scoped(to:)`. Nil before
    /// the first agent list.
    public func scoped(_ deviceId: String) -> HerdrState? {
        states[deviceId]?.scoped(to: sessionChoices[deviceId])
    }

    /// `scoped(_:)` of each computer, by device ID.
    public var scopedStates: [String: HerdrState] {
        Dictionary(uniqueKeysWithValues: states.map { ($0.key, $0.value.scoped(to: sessionChoices[$0.key])) })
    }

    /// The session for a new workspace on a computer, for `HerdrPlugin.create`:
    /// the name of the shown session, or empty for the default session.
    public func createSession(_ deviceId: String) -> String {
        guard let s = session(deviceId), !s.isDefault else { return "" }
        return s.name
    }

    /// Shows the herdr session `name` in the agent list of a computer. This
    /// device keeps the choice.
    public func selectSession(_ deviceId: String, _ name: String) {
        let isDefault = states[deviceId]?.sessions.first { $0.name == name }?.isDefault ?? (name == HerdrSession.defaultName)
        let next: String? = isDefault ? nil : name
        guard sessionChoices[deviceId] != next else { return }
        sessionChoices[deviceId] = next
        defaults?.set(sessionChoices, forKey: HerdrPlugin.sessionsKey)
    }

    /// Shows the session of `pane` in the agent list of a computer, so that
    /// the list has the agent that a notification opens.
    public func reveal(_ deviceId: String, pane: String) {
        guard let state = states[deviceId],
              let name = state.agent(pane)?.session ?? state.terminal(pane)?.session,
              name != session(deviceId)?.name else { return }
        selectSession(deviceId, name)
    }

    /// The output of `pane` on a computer, or nil when the window shows no output of it.
    public func output(_ deviceId: String, pane: String) -> HerdrOutput? {
        outputs[deviceId].flatMap { $0.pane == pane ? $0 : nil }
    }

    /// The last reply to `pane` on a computer.
    public func reply(_ deviceId: String, pane: String) -> HerdrReply? {
        replies[deviceId].flatMap { $0.pane == pane ? $0 : nil }
    }

    /// The time that the agent in `pane` on a computer got its status, or nil when this device did not see it.
    public func agentSince(device: String, pane: String) -> Date? { since[device]?[pane] }

    /// True while the thread of `pane` shows that the question changed, see `questionChanged`.
    public func isQuestionChanged(_ deviceId: String, pane: String) -> Bool {
        questionChanged.contains(Self.promptKey(deviceId, pane: pane))
    }

    /// The key of the prompt of `pane` on a computer in `prompts`.
    public nonisolated static func promptKey(_ deviceId: String, pane: String) -> String { deviceId + "|" + pane }

    /// The output that the Inbox read for `pane` on a computer, or nil before the first read.
    public func prompt(_ deviceId: String, pane: String) -> HerdrOutput? { prompts[Self.promptKey(deviceId, pane: pane)] }
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
    static let dialogKey = "dialog"
    /// The identifier of the action that sends the text of a Reply.
    static let replyAction = "reply"
    /// The start of the identifier of a choice action. The key of the choice follows.
    static let choiceAction = "choice."
    /// The request numbers of the dialog reads start here, so that they do not meet the numbers of the window reads.
    static let dialogRequestBase = 1 << 40
    static let inputAlertsKey = "herdr.inputAlerts"
    static let doneAlertsKey = "herdr.doneAlerts"
    static let dictationLanguageKey = "herdr.dictationLanguage"
    static let sessionsKey = "herdr.sessions"

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
    /// How long a reply in the place of a choice waits for the agent to leave its dialog, see `tell`.
    static let tellWait: Duration = .seconds(4)
    /// How often a reply in the place of a choice checks the status of the agent.
    static let tellStep: Duration = .milliseconds(250)

    public let incoming = [PacketType.fluxHerdr]
    public let outgoing = [PacketType.fluxHerdr]
    public let model: HerdrModel
    private weak var core: FluxCore?

    @MainActor private var trackers: [String: HerdrTracker] = [:]
    /// The status times of the agents of each computer, by device ID.
    @MainActor private var clocks: [String: AgentClock] = [:]
    /// The finished notifications that wait for `finishHold`, by device ID and pane.
    @MainActor private var pending: [String: Task<Void, Never>] = [:]
    /// Counts the reads of each computer and all replies, so that a late
    /// timeout does not replace a newer answer. A read of 1 computer does
    /// not cancel the read timeout of another computer.
    @MainActor private var reads: [String: Int] = [:]
    @MainActor private var reviews: [String: String] = [:]
    @MainActor private var viewReads: [String: HerdrViewRead] = [:]
    @MainActor private var replies = 0
    /// Counts the creates and the closes, so that a late timeout does not
    /// replace a newer one.
    @MainActor private var actions = 0
    /// The time in seconds for the first task. Tests set their own.
    @MainActor var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Counts the output parses of each computer, so that an older parse
    /// that ends late does not replace a newer output.
    @MainActor private var parses: [String: Int] = [:]
    /// The number of the last read and of the last parse of each prompt of
    /// the Inbox, by `HerdrModel.promptKey`, as `reads` and `parses` do for
    /// the window. Each number comes from `promptSeq` and is not used again,
    /// also after `keepPrompts` drops a prompt. A late timeout or parse of a
    /// dropped prompt then does not match a new read of the same agent.
    @MainActor private var promptReads: [String: Int] = [:]
    @MainActor private(set) var promptParses: [String: Int] = [:]
    @MainActor private var promptSeq = 0
    /// The dialog of each blocked pane, for the notification and for its answer.
    private let dialogs: DialogBook
    private let dialogLink: DialogLink
    @MainActor private var dialogSeq = 0
    /// The category of each notification that has actions, by notification ID.
    @MainActor private var noticeCategories: [String: String] = [:]
    /// The notification IDs whose unlock check runs now.
    @MainActor private var checking: Set<String> = []
    /// Tests set these to replace the link: it sends a packet and says whether the link took it.
    @MainActor var sender: ((Packet, String) -> Bool)?
    /// Tests set this to see each notification that the plugin posts: its ID and whether it is quiet.
    @MainActor var posted: ((_ id: String, _ quiet: Bool) -> Void)?
    /// Tests set this to say whether the link to a computer is open.
    @MainActor var linkProbe: ((String) -> Bool)?

    @MainActor
    public init() {
        model = HerdrModel()
        let link = DialogLink()
        dialogLink = link
        dialogs = DialogBook(io: link)
        link.plugin = self
    }

    public func attach(core: FluxCore) {
        self.core = core
        let defaults = core.defaults
        let model = model
        DispatchQueue.main.async { MainActor.assumeIsolated { model.load(defaults) } }
        Notifier.shared.register(category: Self.notificationCategory, handler: noticeHandler)
    }

    /// The handler of the notification actions. All categories of the agent notifications use it.
    private var noticeHandler: Notifier.Handler {
        { [weak self] action, info, text in
            guard let id = info[Self.deviceKey] as? String, let pane = info[Self.paneKey] as? String else { return }
            let dialog = info[Self.dialogKey] as? String ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.noticeAction(action, deviceId: id, pane: pane, dialog: dialog, text: text) }
            }
        }
    }

    /// The next agent list sets the start values, so a reconnect posts nothing.
    public func onConnected(_ device: Device) {
        let id = device.id
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.trackers[id, default: HerdrTracker()].restart()
                self.clocks[id, default: AgentClock()].restart()
            }
        }
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
            // A state with the same times leaves the model as it is, so that the views do not update.
            let since = clocks[deviceId, default: AgentClock()].update(state.agents, now: Date())
            if model.since[deviceId] != since { model.since[deviceId] = since }
            let alerts = trackers[deviceId, default: HerdrTracker()].update(state.agents)
            alert(alerts, deviceId: deviceId, computer: computer)
            advanceFirstTask(deviceId)
        case "output":
            // Only the pane on screen and the prompts of the Inbox keep
            // their output. The check reads the pane before the parse, and
            // the parse of up to 1 MiB of text runs off the main actor.
            guard let pane = p.body["pane"]?.string, !pane.isEmpty else { return }
            // The answer to a dialog read of the notification is for the dialog book only.
            if dialogs.takes(deviceId, pane, request: p.int("request")) {
                let body = p.body
                Task.detached { [weak self] in
                    guard let out = HerdrWire.output(body) else { return }
                    await self?.finishDialogRead(out, deviceId: deviceId)
                }
                return
            }
            let key = HerdrModel.promptKey(deviceId, pane: pane)
            var windowParse: Int?
            if model.outputs[deviceId]?.pane == pane && acceptsView(deviceId, pane: pane, request: p.int("request"), view: p.string("view") ?? "ansi", path: p.string("path") ?? "") {
                let n = (parses[deviceId] ?? 0) + 1
                parses[deviceId] = n
                windowParse = n
            }
            var promptParse: Int?
            if model.prompts[key] != nil && p.string("view") != "diff" && p.int("request") == nil {
                promptSeq += 1
                promptParses[key] = promptSeq
                promptParse = promptSeq
            }
            guard windowParse != nil || promptParse != nil else { return }
            // A @Sendable closure cannot capture a var.
            let window = windowParse
            let prompt = promptParse
            let body = p.body
            Task.detached { [weak self] in
                guard let out = HerdrWire.output(body) else { return }
                await self?.show(out, deviceId: deviceId, window: window, prompt: prompt)
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
                guard let self else { return }
                if self.model.outputs[deviceId]?.pane == sent.pane { self.read(deviceId, pane: sent.pane) }
                if self.model.prompts[HerdrModel.promptKey(deviceId, pane: sent.pane)] != nil {
                    self.readPrompt(deviceId, pane: sent.pane)
                }
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

    /// Shows a parsed output in the window and in the prompt of the Inbox.
    /// Each place skips it when a newer output came, or when the window
    /// shows another pane now. `window` and `prompt` are the numbers of the
    /// parse for each place, or nil when the place did not want it.
    @MainActor
    func show(_ out: HerdrOutput, deviceId: String, window: Int?, prompt: Int?) {
        if let window, parses[deviceId] == window, model.outputs[deviceId]?.pane == out.pane,
           acceptsView(deviceId, pane: out.pane, request: out.request, view: out.view, path: out.path) {
            model.outputs[deviceId] = out
            dialogs.onScreenOutput(deviceId, out)
            advanceFirstTask(deviceId)
        }
        let key = HerdrModel.promptKey(deviceId, pane: out.pane)
        if let prompt, promptParses[key] == prompt, model.prompts[key] != nil {
            model.prompts[key] = out
        }
    }

    // MARK: Requests

    @MainActor
    private func acceptsView(_ deviceId: String, pane: String, request: Int?, view: String, path: String) -> Bool {
        guard let expected = viewReads[deviceId + ":" + pane] else { return true }
        return expected.accepts(request: request, view: view, path: path, supportsReview: model.states[deviceId]?.review == true)
    }

    /// Asks the computer for its agent list now.
    @MainActor
    public func request(_ deviceId: String) {
        core?.send(HerdrWire.request(), to: deviceId)
    }

    /// Asks the computer for the recent output of `pane`. The output of the
    /// last read stays on screen until the answer comes.
    @MainActor
    public func read(_ deviceId: String, pane: String, review: Bool? = nil, path: String = "") {
        let key = deviceId + ":" + pane
        if review == true { reviews[key] = path }
        if review == false { reviews[key] = nil }
        let mode = reviews[key] == nil ? "ansi" : "diff"
        let selectedPath = reviews[key] ?? ""
        let token = reads[deviceId, default: 0] + 1
        reads[deviceId] = token
        viewReads[key] = HerdrViewRead(request: token, view: mode, path: selectedPath)
        let previous = model.output(deviceId, pane: pane)
        var out = previous.flatMap { $0.view == mode && $0.path == selectedPath ? $0 : nil } ?? HerdrOutput(pane: pane)
        out.loading = true
        out.error = nil
        model.outputs[deviceId] = out
        let packet = Packet(PacketType.fluxHerdr, ["kind": "read", "pane": pane, "format": mode, "path": selectedPath, "request": token, "lines": 1000])
        guard core?.send(packet, to: deviceId) == true else {
            model.outputs[deviceId]?.loading = false
            model.outputs[deviceId]?.error = "\(computerName(deviceId)) is not reachable"
            return
        }
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
        reviews[deviceId + ":" + pane] = nil
        viewReads[deviceId + ":" + pane] = nil
        model.questionChanged.remove(HerdrModel.promptKey(deviceId, pane: pane))
        if model.outputs[deviceId]?.pane == pane { model.outputs[deviceId] = nil }
        if model.replies[deviceId]?.pane == pane { model.replies[deviceId] = nil }
    }

    /// Asks the computer for the output of `pane` for the Inbox. The answer
    /// goes to `HerdrModel.prompts`. The old lines stay until it comes.
    @MainActor
    public func readPrompt(_ deviceId: String, pane: String) {
        let key = HerdrModel.promptKey(deviceId, pane: pane)
        var out = model.prompts[key] ?? HerdrOutput(pane: pane)
        out.loading = true
        out.error = nil
        model.prompts[key] = out
        guard core?.send(HerdrWire.read(pane: pane), to: deviceId) == true else {
            model.prompts[key]?.loading = false
            model.prompts[key]?.error = "\(computerName(deviceId)) is not reachable"
            return
        }
        promptSeq += 1
        let token = promptSeq
        promptReads[key] = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.readTimeout)
            guard let self, token == self.promptReads[key], self.model.prompts[key]?.loading == true else { return }
            self.model.prompts[key]?.loading = false
            self.model.prompts[key]?.error = "\(self.computerName(deviceId)) did not answer"
        }
    }

    /// Drops each prompt whose key is not in `keys`. The apps call it when
    /// the Inbox items change, with the `HerdrModel.promptKey` of each agent
    /// that waits.
    @MainActor
    public func keepPrompts(_ keys: Set<String>) {
        for key in Array(model.prompts.keys) where !keys.contains(key) {
            model.prompts[key] = nil
            promptReads[key] = nil
            promptParses[key] = nil
        }
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
    /// action where the user chose to type an answer. Without `feedback`,
    /// an open review of the pane adds no "Review feedback" line.
    @MainActor
    public func sendPrompt(_ deviceId: String, pane: String, _ text: String, answer: Bool = false, feedback: Bool = true) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !answer, feedback, let path = reviews[deviceId + ":" + pane] {
            t = "Review feedback for \(path.isEmpty ? "the working tree" : path):\n" + t
        }
        guard t.utf8.count <= HerdrWire.maxPrompt else {
            replies += 1
            model.replies[deviceId] = HerdrReply(pane: pane, action: "prompt", seq: replies, sending: false,
                                                 error: "The text is too long. The limit is 16 KB.")
            return
        }
        reply(deviceId, pane: pane, action: "prompt", HerdrWire.prompt(pane: pane, t, answer: answer), text: t)
    }

    /// Rejects the action that the agent in `pane` asks for with the choice
    /// `keys`, such as "No, and tell Codex what to do differently", and then
    /// sends `text` as the next prompt. The prompt goes out when the agent no
    /// longer waits for a choice, or after `tellWait`. fluxd refuses a
    /// prompt to an agent that still waits, so the text cannot select a choice.
    @MainActor
    public func tell(_ deviceId: String, pane: String, keys: [String], text: String) {
        sendKeys(deviceId, pane: pane, keys)
        Task { @MainActor [weak self] in
            let start = ContinuousClock.now
            while ContinuousClock.now - start < Self.tellWait {
                try? await Task.sleep(for: Self.tellStep)
                guard let self else { return }
                if self.model.states[deviceId]?.agents.first(where: { $0.pane == pane })?.status != .blocked { break }
            }
            // The reply answers the agent, not a review of its changes.
            self?.sendPrompt(deviceId, pane: pane, text, feedback: false)
        }
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
    /// is empty. A new workspace opens in the herdr session `session`, see
    /// `HerdrModel.createSession`. `model.actions` has the answer. A new
    /// agent gets `task` as its first prompt when it is ready, see `FirstTask`.
    @MainActor
    public func create(_ deviceId: String, what: String, kind: String, cwd: String, workspace: String, task: String? = nil,
                       session: String = "") {
        let text = what == "agent" ? task?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        if !text.isEmpty {
            // The task belongs to the next action.
            model.firstTasks[deviceId] = FirstTask(text: text, action: actions + 1)
        } else {
            model.firstTasks[deviceId] = nil
        }
        action(deviceId, HerdrAction(action: "create", seq: 0, what: what), timeout: Self.createTimeout,
               HerdrWire.create(what: what, agent: kind, cwd: cwd, workspace: workspace, session: session))
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
        guard transmit(HerdrWire.numbered(packet, request: seq), to: deviceId) else {
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

    /// The category of the notification of a dialog. The ID of the dialog follows the family name.
    static func categoryId(dialog: String) -> String { "\(notificationCategory):\(dialog)" }

    /// The actions of a notification. On an iPhone, Flux comes to the front
    /// for Face ID, and iOS asks for the unlock before it runs an action.
    /// A Reply takes text in the notification. The action that this Mac or
    /// iPhone runs asks for the check of the app again, see `answer`.
    static func notificationActions(_ actions: [NoticeAction], platform: FluxPlatform) -> [UNNotificationAction] {
        let options: UNNotificationActionOptions = platform == .phone ? [.foreground, .authenticationRequired] : []
        return actions.map { a -> UNNotificationAction in
            switch a.kind {
            case .choice:
                return UNNotificationAction(identifier: choiceAction + a.key, title: a.label, options: options)
            case .reply:
                return UNTextInputNotificationAction(identifier: replyAction, title: a.label, options: options,
                                                     textInputButtonTitle: "Send", textInputPlaceholder: "Answer")
            case .open:
                return UNNotificationAction(identifier: "open", title: a.label, options: [.foreground])
            }
        }
    }

    /// Sends a packet. Tests replace the link with `sender`.
    @MainActor
    private func transmit(_ packet: Packet, to deviceId: String) -> Bool {
        if let sender { return sender(packet, deviceId) }
        return core?.send(packet, to: deviceId) == true
    }

    /// True while the link to a computer is open.
    @MainActor
    private func linkOpen(_ deviceId: String) -> Bool {
        if let linkProbe { return linkProbe(deviceId) }
        return core?.withDevice(deviceId) { $0.online } ?? false
    }

    /// Posts and removes the notifications for `alerts`.
    @MainActor
    private func alert(_ alerts: [AgentAlert], deviceId: String, computer: String) {
        for a in alerts {
            let key = "\(deviceId)|\(a.pane)"
            pending.removeValue(forKey: key)?.cancel()
            switch a {
            case .clear(let pane):
                removeNotice(deviceId, pane)
            case .needsInput(let agent):
                if model.inputAlerts { post(agent, deviceId: deviceId, computer: computer) }
            case .finished(let agent):
                guard model.doneAlerts else {
                    removeNotice(deviceId, agent.pane)
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

    /// Removes the notification of a pane, its category, and its dialog.
    @MainActor
    private func removeNotice(_ deviceId: String, _ pane: String) {
        let id = Self.notificationId(deviceId, pane)
        Notifier.shared.remove(id: id)
        if let category = noticeCategories.removeValue(forKey: id) { Notifier.shared.unregister(category: category) }
        dialogs.forget(deviceId, pane)
    }

    /// Shows that an agent needs input or finished. Each pane has 1
    /// notification, and a click opens the output of the agent. A blocked
    /// agent posts at once. Then 1 read of its pane finds the dialog, and the
    /// same notification gets the question and the actions.
    @MainActor
    private func post(_ agent: HerdrAgent, deviceId: String, computer: String, quiet: Bool = false) {
        let control = model.states[deviceId]?.control == true
        postNotice(agent, agentNotice(agent, dialog: nil, control: control), deviceId: deviceId, computer: computer, quiet: quiet)
        guard agent.status == .blocked else { return }
        dialogs.peek(deviceId, agent.pane) { [weak self] dialog in
            guard let self, let dialog, self.model.inputAlerts,
                  let now = self.model.states[deviceId]?.agent(agent.pane), now.status == .blocked else { return }
            let control = self.model.states[deviceId]?.control == true
            self.postNotice(now, agentNotice(now, dialog: dialog, control: control), deviceId: deviceId, computer: computer, quiet: true)
        }
    }

    /// Posts `notice`. A notice with actions gets the category of its
    /// dialog. A later post of the same pane replaces the notification, and
    /// `quiet` keeps the sound off for that update.
    @MainActor
    private func postNotice(_ agent: HerdrAgent, _ notice: AgentNotice, deviceId: String, computer: String, quiet: Bool) {
        let id = Self.notificationId(deviceId, agent.pane)
        var category = Self.notificationCategory
        if !notice.actions.isEmpty {
            category = Self.categoryId(dialog: notice.dialogId)
            Notifier.shared.register(category: category, actions: Self.notificationActions(notice.actions, platform: .current),
                                     handler: noticeHandler)
        }
        let old = noticeCategories[id]
        noticeCategories[id] = category == Self.notificationCategory ? nil : category
        posted?(id, quiet)
        Notifier.shared.post(
            id: id,
            category: category,
            title: notice.title,
            body: notice.bigText,
            subtitle: computer,
            userInfo: [Self.deviceKey: deviceId, Self.paneKey: agent.pane, Self.dialogKey: notice.dialogId],
            sound: quiet ? nil : UNNotificationSound.default
        )
        if let old, old != category { Notifier.shared.unregister(category: old) }
    }

    // MARK: Answers from a notification

    /// What a tap on a notification does. The tap on the notification opens
    /// the thread. A choice or a Reply answers the agent, see `answer`.
    @MainActor
    func noticeAction(_ action: String, deviceId: String, pane: String, dialog: String, text: String?) {
        switch action {
        case UNNotificationDefaultActionIdentifier:
            openThread(deviceId, pane: pane, changed: false)
        case Self.replyAction:
            answer(deviceId, pane: pane, dialog: dialog, choice: nil, text: text ?? "")
        case _ where action.hasPrefix(Self.choiceAction):
            answer(deviceId, pane: pane, dialog: dialog, choice: String(action.dropFirst(Self.choiceAction.count)), text: nil)
        default:
            break
        }
    }

    /// Opens the thread of `pane`. With `changed`, the thread says that the
    /// question changed. With `error`, the thread shows why the answer did
    /// not go out, for example after a failed unlock.
    @MainActor
    private func openThread(_ deviceId: String, pane: String, changed: Bool, error: String? = nil) {
        removeNotice(deviceId, pane)
        if changed { model.questionChanged.insert(HerdrModel.promptKey(deviceId, pane: pane)) }
        if let error {
            replies += 1
            model.replies[deviceId] = HerdrReply(pane: pane, action: "keys", seq: replies, sending: false, error: error)
        }
        model.reveal(deviceId, pane: pane)
        model.open?(deviceId, pane)
    }

    /// True when the agent still waits and the computer takes input from this device over an open link.
    @MainActor
    private func answerReady(_ deviceId: String, _ pane: String) -> Bool {
        guard linkOpen(deviceId), let state = model.states[deviceId] else { return false }
        return state.control && state.agent(pane)?.status == .blocked
    }

    /// Answers an agent from its notification: the `choice` key, or the
    /// `text` of a Reply. It sends nothing before the unlock of the app
    /// succeeds. When the link is closed, the agent no longer waits, or
    /// the unlock fails, it sends nothing and opens the thread. After the
    /// unlock, it reads the pane again and sends only when the dialog is
    /// still the one of the notification, with `dialog` as its ID.
    @MainActor
    func answer(_ deviceId: String, pane: String, dialog: String, choice: String?, text: String?) {
        guard answerReady(deviceId, pane), let unlock = model.unlock else {
            openThread(deviceId, pane: pane, changed: false)
            return
        }
        // A Reply with an empty field sends nothing.
        if choice == nil, (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        // A second tap does nothing while a check runs for the same pane.
        let key = Self.notificationId(deviceId, pane)
        guard checking.insert(key).inserted else { return }
        unlock(computerName(deviceId), { [weak self] in
            self?.checking.remove(key)
            self?.verifyAndSend(deviceId, pane: pane, dialog: dialog, choice: choice, text: text)
        }, { [weak self] message in
            self?.checking.remove(key)
            self?.openThread(deviceId, pane: pane, changed: false, error: message)
        }, { [weak self] in
            self?.checking.remove(key)
            self?.repostAfterCancel(deviceId, pane: pane)
        })
    }

    /// Posts the notification of a pane again after the user cancelled the
    /// check. The system removed it with the tap. It comes back with its
    /// actions, only while the agent still waits and the alerts are on, and
    /// it makes no sound.
    @MainActor
    private func repostAfterCancel(_ deviceId: String, pane: String) {
        guard model.inputAlerts, let agent = model.states[deviceId]?.agent(pane), agent.status == .blocked else { return }
        post(agent, deviceId: deviceId, computer: computerName(deviceId), quiet: true)
    }

    @MainActor
    private func verifyAndSend(_ deviceId: String, pane: String, dialog: String, choice: String?, text: String?) {
        guard answerReady(deviceId, pane) else {
            openThread(deviceId, pane: pane, changed: false)
            return
        }
        if let choice {
            dialogs.verify(deviceId, pane, id: dialog, onSame: { [weak self] d in
                guard let self else { return }
                guard let c = d.choices.first(where: { $0.key == choice }), HerdrWire.allowed(c.keys), self.answerReady(deviceId, pane) else {
                    self.openThread(deviceId, pane: pane, changed: true)
                    return
                }
                self.sendKeys(deviceId, pane: pane, c.keys)
                self.sent(deviceId, pane)
            }, onChanged: { [weak self] d in
                self?.openThread(deviceId, pane: pane, changed: d != nil)
            })
        } else if let text {
            dialogs.peek(deviceId, pane) { [weak self] d in
                guard let self else { return }
                // A Reply sends only while the dialog is the one of the notification.
                if replyMatches(d, dialog), self.answerReady(deviceId, pane) {
                    self.sendPrompt(deviceId, pane: pane, text, answer: true)
                    self.sent(deviceId, pane)
                } else {
                    self.openThread(deviceId, pane: pane, changed: d != nil)
                }
            }
        }
    }

    /// Removes the notification after a send. A send that failed opens the thread.
    @MainActor
    private func sent(_ deviceId: String, _ pane: String) {
        if let r = model.replies[deviceId], !r.sending, r.error != nil {
            openThread(deviceId, pane: pane, changed: false)
        } else {
            removeNotice(deviceId, pane)
        }
    }

    // MARK: Dialog reads

    @MainActor
    fileprivate func sendDialogRead(_ deviceId: String, _ pane: String, register: (Int) -> Void) -> Bool {
        dialogSeq += 1
        let request = Self.dialogRequestBase + dialogSeq
        register(request)
        return transmit(HerdrWire.read(pane: pane, lines: dialogReadLines, request: request), to: deviceId)
    }

    @MainActor
    fileprivate func finishDialogRead(_ out: HerdrOutput, deviceId: String) {
        dialogs.onOutput(deviceId, out)
    }

    @MainActor
    fileprivate func screenRead(_ deviceId: String, _ pane: String) -> (open: Bool, loading: Bool) {
        guard let out = model.outputs[deviceId], out.pane == pane else { return (false, false) }
        return (true, out.loading)
    }

    @MainActor
    fileprivate func readScreen(_ deviceId: String, _ pane: String) -> Bool {
        read(deviceId, pane: pane)
        return model.outputs[deviceId]?.error == nil
    }

    /// Connects `DialogBook` to the plugin. The book runs on the main actor, so each call is already there.
    fileprivate final class DialogLink: DialogIo, @unchecked Sendable {
        weak var plugin: HerdrPlugin?

        func screenOpen(_ deviceId: String, _ pane: String) -> Bool {
            MainActor.assumeIsolated { plugin?.screenRead(deviceId, pane).open ?? false }
        }

        func screenReading(_ deviceId: String, _ pane: String) -> Bool {
            MainActor.assumeIsolated { plugin?.screenRead(deviceId, pane).loading ?? false }
        }

        func readScreen(_ deviceId: String, _ pane: String) -> Bool {
            MainActor.assumeIsolated { plugin?.readScreen(deviceId, pane) ?? false }
        }

        func send(_ deviceId: String, _ pane: String, register: (Int) -> Void) -> Bool {
            MainActor.assumeIsolated { plugin?.sendDialogRead(deviceId, pane, register: register) ?? false }
        }

        func now() -> Date { Date() }

        func later(_ delay: Duration, _ task: @escaping () -> Void) {
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                task()
            }
        }

        func post(_ task: @escaping () -> Void) { task() }
    }
}
