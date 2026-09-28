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
/// agent. When the computer allows it, this Mac also sends keys and prompts
/// to an agent. The app asks for Touch ID or the password before the first
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
    /// How long a read waits for the output.
    static let readTimeout: Duration = .seconds(10)
    /// How long a reply waits for the answer of the computer.
    static let replyTimeout: Duration = .seconds(10)
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
    /// Counts the reads and the replies, so that a late timeout does not
    /// replace a newer answer.
    @MainActor private var reads = 0
    @MainActor private var replies = 0

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
        case "output":
            // Only the pane on screen keeps its output.
            guard let out = HerdrWire.output(p.body), model.outputs[deviceId]?.pane == out.pane else { return }
            model.outputs[deviceId] = out
        case "sent":
            guard let sent = HerdrWire.sent(p.body), var reply = model.replies[deviceId], reply.pane == sent.pane, reply.sending else { return }
            reply.sending = false
            reply.error = sent.error
            model.replies[deviceId] = reply
            guard sent.error == nil else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.rereadDelay)
                guard let self, self.model.outputs[deviceId]?.pane == sent.pane else { return }
                self.read(deviceId, pane: sent.pane)
            }
        default:
            FluxLog.plugin.debug("herdr: ignored kind \(p.string("kind") ?? "", privacy: .public)")
        }
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
        reads += 1
        let token = reads
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.readTimeout)
            guard let self, token == self.reads, let out = self.model.output(deviceId, pane: pane), out.loading else { return }
            self.model.outputs[deviceId]?.loading = false
            self.model.outputs[deviceId]?.error = "\(self.computerName(deviceId)) did not answer"
        }
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
    /// prompt, or types it into a dialog.
    @MainActor
    public func sendPrompt(_ deviceId: String, pane: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard t.utf8.count <= HerdrWire.maxPrompt else {
            replies += 1
            model.replies[deviceId] = HerdrReply(pane: pane, action: "prompt", seq: replies, sending: false,
                                                 error: "The text is too long. The limit is 16 KB.")
            return
        }
        reply(deviceId, pane: pane, action: "prompt", HerdrWire.prompt(pane: pane, t))
    }

    @MainActor
    private func reply(_ deviceId: String, pane: String, action: String, _ packet: Packet) {
        replies += 1
        let seq = replies
        model.replies[deviceId] = HerdrReply(pane: pane, action: action, seq: seq)
        guard core?.send(packet, to: deviceId) == true else {
            model.replies[deviceId] = HerdrReply(pane: pane, action: action, seq: seq, sending: false,
                                                 error: "\(computerName(deviceId)) is not reachable")
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.replyTimeout)
            guard let self, var r = self.model.replies[deviceId], r.seq == seq, r.sending else { return }
            r.sending = false
            r.error = "\(self.computerName(deviceId)) did not answer"
            self.model.replies[deviceId] = r
        }
    }

    private func computerName(_ deviceId: String) -> String { core?.device(deviceId)?.name ?? "The computer" }

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
