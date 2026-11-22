import AppKit
import FluxKit
import Observation
import UserNotifications

/// The UI state of the app. It mirrors the core and holds the destination,
/// the open chat, the scope, the times of the chats, and the theme setting.
@MainActor
@Observable
final class AppModel {
    let core: FluxCore
    private(set) var state = CoreState()
    private(set) var toast: String?
    /// The device that the pairing sheet shows.
    var pairingSheet: String?
    /// The destination that the sidebar selects.
    var destination: MacDestination = .chats
    /// The chat that the detail column shows while Chats is open, or nil.
    var chat: ChatOpen?
    /// The computer of the sheet that starts an agent, or nil.
    var startAgent: String?
    /// The pages on top of each destination.
    var chatPath: [MacRoute] = []
    var controlPath: [MacRoute] = []
    var computersPath: [MacRoute] = []
    /// The computer in scope of Control and Computers, or nil for all
    /// computers. A new start begins with all computers.
    var scope: String?
    /// The first time that this Mac saw each Inbox item of all computers, by key. See `watchEvents`.
    private(set) var seen: [String: Date] = [:]
    /// The time that each paired computer went offline in this run of Flux, by device ID.
    private var wentOffline: [String: Date] = [:]
    /// True for 3 seconds after a connection attempt starts. A computer
    /// that is not online then counts as connecting.
    private(set) var connecting = false
    /// The computer that paired last, for 6 seconds.
    private(set) var newlyPairedId: String?
    /// The theme setting. It reuses the key of the old Appearance setting.
    var themeMode = ThemeMode(key: UserDefaults.standard.string(forKey: ThemeMode.defaultsKey)) {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: ThemeMode.defaultsKey) }
    }
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var pairedTask: Task<Void, Never>?
    @ObservationIgnored private var seenClock = SeenClock()
    /// The first time that the list of chats showed each row whose start is not known.
    @ObservationIgnored private var listClock = SeenClock()
    /// The state of the agent chats of each computer in the window: the drafts and the dictation.
    @ObservationIgnored private var agentModels: [String: AgentsWindowModel] = [:]

    init(core: FluxCore) {
        self.core = core
        state = core.state
        core.onChange = { [weak self] s in MainActor.assumeIsolated { self?.apply(s) } }
        core.onToast = { [weak self] m in MainActor.assumeIsolated { self?.show(m) } }
        core.onPairRequest = { [weak self] d in MainActor.assumeIsolated { self?.pairRequested(d) } }
        Notifier.shared.register(category: Self.pairCategory, actions: [
            UNNotificationAction(identifier: "accept", title: "Accept"),
            UNNotificationAction(identifier: "reject", title: "Reject", options: [.destructive]),
        ]) { [weak self] action, info, _ in
            guard let id = info["device"] as? String else { return }
            let key = info["key"] as? String
            DispatchQueue.main.async {
                guard let self else { return }
                switch action {
                case "accept":
                    // Accept only the request whose key the notification showed.
                    guard let d = self.state.devices.first(where: { $0.id == id }), d.pairState == .incoming, d.pairKey == key else { return }
                    self.core.acceptPair(id)
                case "reject": self.core.cancelPair(id)
                default:
                    // The pairing page of the computer shows the key.
                    self.destination = .computers
                    self.computersPath = [.pairing(id)]
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    static let pairCategory = "pair"

    var paired: [DeviceSnapshot] { state.devices.filter(\.paired) }
    var available: [DeviceSnapshot] { state.devices.filter { !$0.paired } }
    var connectedPaired: [DeviceSnapshot] { state.devices.filter { $0.paired && $0.online } }

    /// The paired computer with the ID, or nil.
    func pairedDevice(_ id: String?) -> DeviceSnapshot? {
        guard let id else { return nil }
        return state.devices.first { $0.id == id && $0.paired }
    }

    // MARK: Navigation

    /// The pages on top of the destination on screen.
    var path: [MacRoute] {
        get {
            switch destination {
            case .chats: return chatPath
            case .control: return controlPath
            case .computers: return computersPath
            }
        }
        set {
            switch destination {
            case .chats: chatPath = newValue
            case .control: controlPath = newValue
            case .computers: computersPath = newValue
            }
        }
    }

    /// Opens a page on top of the destination on screen.
    func push(_ route: MacRoute) {
        path.append(route)
    }

    /// Opens the root of a destination. Chats keeps the chat that was open.
    func go(_ destination: MacDestination) {
        self.destination = destination
        path = []
    }

    /// Opens a chat in the detail column.
    func open(_ chat: ChatOpen) {
        // herdr keeps 1 output of each computer. While the agents window of the computer is open, its agents show there.
        if case .agent(let id, let pane) = chat, AgentsWindows.shared.isOpen(id) {
            AgentsWindows.shared.show(id, pane: pane, app: self)
            return
        }
        destination = .chats
        self.chat = chat
        chatPath = []
    }

    // MARK: Theme

    /// The theme of the computer in scope, or the last theme without a scope.
    var computerTheme: ComputerTheme? {
        core.plugin(ThemePlugin.self)?.model.current(scope: scope)
    }

    /// The palette to draw. `systemDark` is the light or dark mode of the window.
    func palette(systemDark: Bool) -> ThemePalette {
        themeMode.palette(computer: computerTheme?.palette, systemDark: systemDark)
    }

    /// The light or dark mode of the windows: `.system`, `.light`, or `.dark`.
    var nightMode: ThemeMode {
        themeMode.nightMode(computer: computerTheme?.palette)
    }

    /// Sets the light or dark mode of the windows now and after each change
    /// of the theme. The Mac can run with no window open, so a view cannot
    /// do it.
    func watchTheme() {
        let night = withObservationTracking {
            nightMode
        } onChange: { [weak self] in
            // onChange runs before the change, so read again on the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchTheme() } }
        }
        AppearanceController.shared.apply(night)
    }

    // MARK: Chats

    /// The Inbox items of all computers: the agents, the approval, and the pair requests.
    func inboxItems() -> [InboxItem] {
        Inbox.items(core: core, devices: state.devices)
    }

    /// The list of chats: what needs the user, the agents, and the paired
    /// computers with the newest entry of each chat. `query` keeps only the
    /// rows that hold it. SwiftUI tracks each model that it reads.
    func chatList(query: String = "") -> ChatList {
        let share = core.plugin(SharePlugin.self)
        let herdr = core.plugin(HerdrPlugin.self)
        let log = Chat.entries(
            sent: share?.model.sent ?? [],
            transfers: share?.model.transfers ?? [],
            clip: core.plugin(ClipboardPlugin.self)?.model.last,
            answers: core.plugin(ApprovePlugin.self)?.model.history ?? [],
            items: [],
            since: { _, _ in nil },
            seen: [:]
        )
        return Chats.list(devices: state.devices, herdr: herdr?.model.states ?? [:],
                          approval: core.plugin(ApprovePlugin.self)?.model.current, log: log,
                          since: { herdr?.model.agentSince(device: $0, pane: $1) },
                          lastSeen: { wentOffline[$0] },
                          seen: &listClock, now: Date(), query: query)
    }

    /// The time that the paired computer `id` went offline in this run of
    /// Flux, or nil when Flux does not know it.
    func lastSeen(_ id: String) -> Date? { wentOffline[id] }

    /// The state of the agent chats of a computer in the window, or nil
    /// without herdr. It keeps the drafts of each agent while the user opens
    /// other chats.
    func agentModel(_ deviceId: String) -> AgentsWindowModel? {
        if let m = agentModels[deviceId] { return m }
        guard let plugin = core.plugin(HerdrPlugin.self) else { return nil }
        let m = AgentsWindowModel(deviceId: deviceId, app: self, plugin: plugin, selection: nil)
        agentModels[deviceId] = m
        return m
    }

    /// Sets the computer in scope.
    func setScope(_ id: String?) {
        guard id != scope else { return }
        scope = id
    }

    /// Keeps the times and the prompts of the Inbox items of all computers
    /// while the app runs, also while no window shows them. It runs again
    /// after each change of the items.
    func watchEvents() {
        let items = withObservationTracking {
            inboxItems()
        } onChange: { [weak self] in
            // onChange runs before the change, so read again on the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchEvents() } }
        }
        eventsChanged(items)
    }

    /// Records the first time of each new item, and keeps the prompt of each
    /// agent that waits or works.
    private func eventsChanged(_ items: [InboxItem]) {
        let next = seenClock.update(items.map(\.key), now: Date())
        if next != seen { seen = next }
        var keys = Set<String>()
        for item in items {
            if case .agent(let deviceId, let agent, _) = item.content, agent.status == .blocked || agent.status == .working {
                keys.insert(HerdrModel.promptKey(deviceId, pane: agent.pane))
            }
        }
        core.plugin(HerdrPlugin.self)?.keepPrompts(keys)
    }

    /// The times of the chats for `items`: the first time of each item, or
    /// `now` for an item that `watchEvents` did not record yet.
    func chatSeen(_ items: [InboxItem], now: Date = Date()) -> [String: Date] {
        var out = seen
        for item in items where out[item.key] == nil { out[item.key] = now }
        return out
    }

    /// Starts the 3 seconds in which a computer that is not online counts as connecting.
    func startConnectGrace() {
        connecting = true
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.connecting = false }
        }
    }

    /// Searches for the computers again.
    func retry() {
        startConnectGrace()
        core.search()
    }

    // MARK: State

    private func apply(_ s: CoreState) {
        let old = state
        if s != state { state = s }
        // A computer that is no longer paired leaves the scope, and its chats close.
        if let scope, !s.devices.contains(where: { $0.id == scope && $0.paired }) { self.scope = nil }
        if let id = chat?.deviceId, !s.devices.contains(where: { $0.id == id && $0.paired }) { chat = nil }
        // A new pairing shows the chat of the new computer.
        if let id = Self.newlyPaired(old: old.devices.map { ($0.id, $0.paired) }, new: s.devices.map { ($0.id, $0.paired) }).first {
            pairingSheet = nil
            scope = id
            open(.computer(id))
            computersPath = []
            notePaired(id)
        }
        for d in s.devices where d.pairState != .incoming { Notifier.shared.remove(id: "pair-\(d.id)") }
        for d in s.devices where d.paired && !d.online && old.devices.contains(where: { $0.id == d.id && $0.online }) {
            wentOffline[d.id] = Date()
        }
        FeatureHooks.stateChanged(s, model: self)
    }

    /// The computers that are paired in `new` and were known but not paired in `old`.
    nonisolated static func newlyPaired(old: [(id: String, paired: Bool)], new: [(id: String, paired: Bool)]) -> [String] {
        let before = Dictionary(old.map { ($0.id, $0.paired) }, uniquingKeysWith: { a, _ in a })
        return new.filter { $0.paired && before[$0.id] == false }.map(\.id)
    }

    private func notePaired(_ id: String) {
        newlyPairedId = id
        pairedTask?.cancel()
        pairedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.newlyPairedId = nil }
        }
    }

    /// Unpairs the computer. This Mac also deletes its approval key for the
    /// computer, so that a new pairing needs a new enrollment.
    func unpair(_ id: String) {
        core.unpair(id)
        core.plugin(ApprovePlugin.self)?.removeKey(id)
    }

    /// The text of the unpair dialog. It names the approval key when this
    /// Mac has one for the computer.
    func unpairMessage(_ d: DeviceSnapshot) -> String {
        let text = "\(d.name) and this Mac forget each other. Pair again to use it."
        guard core.plugin(ApprovePlugin.self)?.model.keys[d.id] != nil else { return text }
        return text + " This Mac deletes its approval key for \(d.name). The key file on the computer stays until you run: sudo flux-cli approve remove"
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    /// A request from a computer does not take the window, so that a key
    /// press meant for the open page cannot accept it. The list of chats
    /// shows the request, and a notification shows the key. A click on the
    /// notification opens the pairing page of the computer.
    private func pairRequested(_ d: DeviceSnapshot) {
        if NSApp.isActive { show("\(d.name) wants to pair") }
        Notifier.shared.post(id: "pair-\(d.id)", category: Self.pairCategory, title: "Pair with \(d.name)?",
                             body: "Check that \(d.name) shows the key \(KeyView.grouped(d.pairKey)).",
                             userInfo: ["device": d.id, "key": d.pairKey])
    }
}
