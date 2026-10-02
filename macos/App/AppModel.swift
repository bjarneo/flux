import AppKit
import FluxKit
import Observation
import UserNotifications

/// The UI state of the app. It mirrors the core and holds the destination,
/// the scope, the order of the Inbox, and the theme setting.
@MainActor
@Observable
final class AppModel {
    let core: FluxCore
    private(set) var state = CoreState()
    private(set) var toast: String?
    /// The device that the pairing sheet shows.
    var pairingSheet: String?
    /// The destination that the sidebar selects.
    var destination: MacDestination = .inbox
    /// The pages on top of each destination.
    var inboxPath: [MacRoute] = []
    var sendPath: [MacRoute] = []
    var controlPath: [MacRoute] = []
    var computersPath: [MacRoute] = []
    /// The computer in scope, or nil for all computers. A new start begins with all computers.
    var scope: String?
    /// The order that the user gave the Inbox.
    var arrangement = InboxArrangement()
    /// The last time that the player of each computer played, by device ID.
    var playedAt: [String: Date] = [:]
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
            case .inbox: return inboxPath
            case .send: return sendPath
            case .control: return controlPath
            case .computers: return computersPath
            }
        }
        set {
            switch destination {
            case .inbox: inboxPath = newValue
            case .send: sendPath = newValue
            case .control: controlPath = newValue
            case .computers: computersPath = newValue
            }
        }
    }

    /// Opens a page on top of the destination on screen.
    func push(_ route: MacRoute) {
        path.append(route)
    }

    /// Opens the root of a destination.
    func go(_ destination: MacDestination) {
        self.destination = destination
        path = []
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

    // MARK: Inbox

    /// The Inbox items of all computers.
    func inboxItems(now: Date) -> [InboxItem] {
        Inbox.items(core: core, devices: state.devices, now: now, playedAt: playedAt)
    }

    /// Sets the computer in scope. The order of the Inbox syncs with the
    /// items of the new scope at once, so that a pin set after the change stays.
    func setScope(_ id: String?) {
        guard id != scope else { return }
        scope = id
        let all = inboxItems(now: Date())
        inboxChanged(all: all, scoped: Inbox.inScope(all, scope: id))
    }

    /// Keeps the order of the Inbox and the prompts of the agents that wait.
    /// The order syncs with the items in scope, as on Android. A new item in
    /// scope that needs the user removes the pin. The menu bar panel shows
    /// all computers in the same order, so a deferred item stays deferred
    /// while it is on a computer. The prompts follow all computers.
    func inboxChanged(all: [InboxItem], scoped: [InboxItem]) {
        var next = arrangement.sync(scoped)
        let present = Set(all.map(\.key))
        next.deferred = arrangement.deferred.filter { present.contains($0) }
        if next != arrangement { arrangement = next }
        var keys = Set<String>()
        for item in all {
            if case .agent(let deviceId, let agent, _) = item.content, agent.status == .blocked {
                keys.insert(HerdrModel.promptKey(deviceId, pane: agent.pane))
            }
        }
        core.plugin(HerdrPlugin.self)?.keepPrompts(keys)
    }

    /// Moves the master item to the end of the stack.
    func showNext(_ key: String) {
        arrangement = arrangement.swipe(key)
    }

    /// Moves a stack item to the master position.
    func showFirst(_ key: String) {
        arrangement = arrangement.promote(key)
    }

    /// Moves the master item of the Inbox in scope to the end of the stack.
    /// The Go menu calls it.
    func showNextItem() {
        let scoped = Inbox.inScope(inboxItems(now: Date()), scope: scope)
        let arranged = arrangement.arrange(scoped)
        guard arranged.count > 1, let first = arranged.first else { return }
        showNext(first.key)
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
        // A computer that is no longer paired leaves the scope.
        if let scope, !s.devices.contains(where: { $0.id == scope && $0.paired }) { self.scope = nil }
        // A new pairing shows the Inbox of the new computer.
        if let id = Self.newlyPaired(old: old.devices.map { ($0.id, $0.paired) }, new: s.devices.map { ($0.id, $0.paired) }).first {
            pairingSheet = nil
            scope = id
            destination = .inbox
            inboxPath = []
            computersPath = []
            notePaired(id)
        }
        for d in s.devices where d.pairState != .incoming { Notifier.shared.remove(id: "pair-\(d.id)") }
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
    /// press meant for the open page cannot accept it. The Inbox shows the
    /// request, and a notification shows the key. A click on the
    /// notification opens the pairing page of the computer.
    private func pairRequested(_ d: DeviceSnapshot) {
        if NSApp.isActive { show("\(d.name) wants to pair") }
        Notifier.shared.post(id: "pair-\(d.id)", category: Self.pairCategory, title: "Pair with \(d.name)?",
                             body: "Check that \(d.name) shows the key \(KeyView.grouped(d.pairKey)).",
                             userInfo: ["device": d.id, "key": d.pairKey])
    }
}
