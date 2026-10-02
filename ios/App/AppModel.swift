import FluxKit
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// A screen on the navigation stack of a tab.
enum Route: Hashable {
    case settings
    /// The page of a paired computer under Computers.
    case computer(String)
    /// A screen of a feature, see `FeatureRoute`.
    case feature(FeatureRoute)
}

/// The 4 destinations of the tab bar, in order.
enum AppTab: Hashable, CaseIterable {
    case inbox, send, control, computers
}

/// A short message for the user. Each one has its own id, so that the same
/// text twice shows twice.
struct Toast: Equatable {
    let id = UUID()
    let message: String
}

/// The UI state of the app. It mirrors the core and holds the navigation.
@MainActor
@Observable
final class AppModel {
    let core: FluxCore
    /// True in the demo for App Review and screenshots. The app then shows
    /// the sample computers of `DemoMode` and starts no network and no feature.
    let demo: Bool
    private(set) var state = CoreState()
    private(set) var toast: Toast?
    var tab: AppTab = .inbox
    var inboxPath: [Route] = []
    var sendPath: [Route] = []
    var controlPath: [Route] = []
    var computersPath: [Route] = []
    /// The computer in scope, or nil for all computers. A new start begins
    /// with all computers.
    var scope: String?
    /// The order that the user gave the Inbox.
    var arrangement = InboxArrangement()
    /// The last time that the player of each computer played, so that a
    /// paused player stays in the Inbox for a time.
    var playedAt: [String: Date] = [:]
    /// True for 3 seconds after a connection attempt starts. The Inbox then
    /// says that it connects, not that a computer is not reachable.
    private(set) var connecting = false
    /// The computer that paired last, for 6 seconds.
    private(set) var newlyPairedId: String?
    /// The theme setting. It keeps the key of the old Appearance setting.
    var themeMode = ThemeMode(key: UserDefaults.standard.string(forKey: ThemeMode.defaultsKey)) {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: ThemeMode.defaultsKey) }
    }
    /// The question for the computer of an action, see `TargetRun`.
    var targetRequest: TargetRequest?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var pairedTask: Task<Void, Never>?

    /// The path of the selected tab. A feature that pushes a screen pushes
    /// it onto the selected tab.
    var path: [Route] {
        get {
            switch tab {
            case .inbox: return inboxPath
            case .send: return sendPath
            case .control: return controlPath
            case .computers: return computersPath
            }
        }
        set {
            switch tab {
            case .inbox: inboxPath = newValue
            case .send: sendPath = newValue
            case .control: controlPath = newValue
            case .computers: computersPath = newValue
            }
        }
    }
    /// The computer that the pairing sheet asks to pair with.
    var pairingSheet: String?
    /// False while the app is off the screen.
    private(set) var isActive = false
    /// True while the touchpad shows. The screen of the iPhone stays on then.
    var touchpadOpen = false
    /// The number of App Intents that use the links now. The links stay
    /// open in the background while one runs, see `withBackgroundLink`.
    private(set) var intentsRunning = 0
    /// True while Flux is off the screen and runs only for App Intents. The
    /// links close when the last action ends, so the features start no
    /// transfer then, see `FeatureHooks.intentsChanged`.
    var runsOnlyForIntents: Bool { !isActive && intentsRunning > 0 }
    private var toastTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    /// The pairing sheet that shows now, see `pairSheetClosed`.
    @ObservationIgnored var shownPairSheet: String?

    init(core: FluxCore, demo: Bool = false) {
        self.core = core
        self.demo = demo
        state = demo ? DemoMode.state(core.state) : core.state
        core.onChange = { [weak self] s in MainActor.assumeIsolated { self?.apply(s) } }
        core.onToast = { [weak self] m in MainActor.assumeIsolated { self?.show(m) } }
        core.onPairRequest = { [weak self] d in MainActor.assumeIsolated { self?.pairRequested(d) } }
        Notifier.shared.register(category: Self.pairCategory, actions: Self.pairActions()) { [weak self] action, info, _ in
            guard let id = info["device"] as? String else { return }
            let key = info["key"] as? String
            DispatchQueue.main.async {
                guard let self else { return }
                switch action {
                case "accept":
                    // Accept only the request whose key the notification showed.
                    guard let d = self.device(id), d.pairState == .incoming, d.pairKey == key else { return }
                    self.core.acceptPair(id)
                case "reject":
                    if let d = self.device(id), d.pairState == .incoming { self.rejectPair(d) }
                // A tap opens Flux, which shows the request.
                default: break
                }
            }
        }
        watchBackgroundWork()
        watchScreenAwake()
    }

    static let pairCategory = "pair"

    /// The actions of a pairing notification. Accept needs an unlocked
    /// iPhone and opens Flux, so that a person with a locked iPhone cannot
    /// pair it. Reject works from the lock screen.
    nonisolated static func pairActions() -> [UNNotificationAction] {
        [
            UNNotificationAction(identifier: "accept", title: "Accept", options: [.authenticationRequired, .foreground]),
            UNNotificationAction(identifier: "reject", title: "Reject", options: [.destructive]),
        ]
    }

    var paired: [DeviceSnapshot] { state.devices.filter(\.paired) }
    var available: [DeviceSnapshot] { state.devices.filter { !$0.paired } }

    func device(_ id: String) -> DeviceSnapshot? { state.devices.first { $0.id == id } }

    /// The computer of the pairing sheet: one that asks to pair comes first.
    var pairSheetDevice: String? {
        state.devices.first { $0.pairState == .incoming }?.id ?? pairingSheet
    }

    /// Rejects a pairing request. The core then ends the requests from the
    /// same computer or address at once for 30 seconds.
    func rejectPair(_ d: DeviceSnapshot) {
        core.cancelPair(d.id)
    }

    /// Unpairs the computer. This iPhone also deletes its approval key for
    /// the computer, so that a new pairing needs a new enrollment.
    func unpair(_ id: String) {
        core.unpair(id)
        core.plugin(ApprovePlugin.self)?.removeKey(id)
    }

    // MARK: Theme and Inbox

    /// The theme of the computer in scope, or the last theme without a scope.
    var computerTheme: ComputerTheme? {
        if demo { return DemoMode.theme(scope: scope) }
        return core.plugin(ThemePlugin.self)?.model.current(scope: scope)
    }

    /// The palette to draw. `systemDark` is the mode of the iPhone.
    func palette(systemDark: Bool) -> ThemePalette {
        themeMode.palette(computer: computerTheme?.palette, systemDark: systemDark)
    }

    /// The light or dark mode of the windows, see `AppearanceController`.
    var nightMode: ThemeMode {
        themeMode.nightMode(computer: computerTheme?.palette)
    }

    /// The Inbox items of all computers at the time `now`, ranked.
    func inboxItems(now: Date) -> [InboxItem] {
        if demo { return DemoMode.inboxItems(now: now) }
        return Inbox.items(core: core, devices: state.devices, now: now, playedAt: playedAt)
    }

    /// Sets the computer in scope, or all computers with nil. The scope
    /// filters the Inbox, Send, and Control, and it picks the computer theme.
    func setScope(_ id: String?) {
        scope = id
    }

    /// The Inbox items changed. The arrangement forgets the items that are
    /// gone, and the herdr plugin drops the prompts of the agents that no
    /// longer wait.
    func inboxChanged(all: [InboxItem], scoped: [InboxItem]) {
        let next = arrangement.sync(scoped)
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

    /// Moves a stack item to the master tile.
    func showFirst(_ key: String) {
        arrangement = arrangement.promote(key)
    }

    /// The links connect for 3 seconds before the Inbox says that a
    /// computer is not reachable.
    func startConnectGrace() {
        connecting = true
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.connecting = false }
        }
    }

    /// Looks for the computers again. The demo uses no network.
    func retry() {
        guard !demo else { return }
        startConnectGrace()
        core.search()
    }

    /// Selects a tab. A tap on the open tab goes back to its root.
    func select(_ tab: AppTab) {
        if tab == self.tab { path = [] }
        self.tab = tab
    }

    /// Shows the new pairing in the Inbox for 6 seconds.
    private func notePaired(_ id: String) {
        newlyPairedId = id
        pairedTask?.cancel()
        pairedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.newlyPairedId = nil }
        }
    }

    /// The text of the unpair dialog. It names the approval key when this
    /// iPhone has one for the computer.
    func unpairMessage(_ d: DeviceSnapshot) -> String {
        let text = "\(d.name) and this iPhone forget each other. Pair again to use it."
        guard core.plugin(ApprovePlugin.self)?.model.keys[d.id] != nil else { return text }
        return text + " This iPhone deletes its approval key for \(d.name). The key file on the computer stays until you run: sudo flux-cli approve remove"
    }

    /// The pairing sheet closed. A swipe on a request from a computer rejects
    /// it. A change of the sheet to another computer is no swipe, so only the
    /// sheet that still shows counts.
    func pairSheetClosed() {
        if let id = shownPairSheet, id == pairSheetDevice, let d = device(id), d.pairState == .incoming {
            rejectPair(d)
        }
        pairingSheet = nil
    }

    private func apply(_ s: CoreState) {
        // The demo keeps its sample computers and leaves the share queue alone.
        if demo {
            state = DemoMode.state(s)
            return
        }
        let old = state
        state = s
        for d in s.devices where d.pairState != .incoming { Notifier.shared.remove(id: "pair-\(d.id)") }
        if let id = pairingSheet, !s.devices.contains(where: { $0.id == id }) { pairingSheet = nil }
        FeatureHooks.stateChanged(s, model: self)
        // A computer that is no longer paired leaves the scope.
        if let id = scope, !s.devices.contains(where: { $0.id == id && $0.paired }) { scope = nil }
        // A new pairing opens the Inbox of the new computer. Flux asks for
        // notifications here, so that the question comes with a reason.
        if let id = Self.newlyPaired(old: old.devices.map { ($0.id, $0.paired) }, new: s.devices.map { ($0.id, $0.paired) }).first {
            pairingSheet = nil
            scope = id
            tab = .inbox
            inboxPath = []
            notePaired(id)
            NotificationAccess.shared.ask()
        }
    }

    /// The computers that are paired in `new` and were known but not paired in `old`.
    nonisolated static func newlyPaired(old: [(id: String, paired: Bool)], new: [(id: String, paired: Bool)]) -> [String] {
        let before = Dictionary(old.map { ($0.id, $0.paired) }, uniquingKeysWith: { a, _ in a })
        return new.filter { $0.paired && before[$0.id] == false }.map(\.id)
    }

    func show(_ message: String) {
        toast = Toast(message: message)
        UIAccessibility.post(notification: .announcement, argument: message)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    /// The sheet shows the request while Flux is on the screen. Otherwise a
    /// notification with Accept and Reject shows it. The core refuses a
    /// request from a computer or address whose last request ended less
    /// than 30 seconds ago, so such a request does not come here.
    private func pairRequested(_ d: DeviceSnapshot) {
        guard !isActive else { return }
        Notifier.shared.post(id: "pair-\(d.id)", category: Self.pairCategory, title: "Pair with \(d.name)?",
                             body: "Check that \(d.name) shows the key \(KeyView.grouped(d.pairKey)).",
                             userInfo: ["device": d.id, "key": d.pairKey])
    }

    // MARK: Lifecycle

    /// iOS suspends Flux soon after it leaves the screen. Flux keeps its
    /// links for the background time that iOS gives, then closes them, so
    /// that the computers see it leave. It connects again when it returns.
    func scenePhaseChanged(_ phase: ScenePhase) {
        if phase != .active { FeatureHooks.leftActive(model: self) }
        switch phase {
        case .active:
            isActive = true
            // The demo starts no discovery, listener, or link.
            guard !demo else { return }
            endBackgroundTask()
            FeatureHooks.intentsChanged(model: self)
            startConnectGrace()
            core.resume()
            FeatureHooks.sceneChanged(active: true, model: self)
        case .background:
            isActive = false
            guard !demo else { return }
            FeatureHooks.intentsChanged(model: self)
            FeatureHooks.sceneChanged(active: false, model: self)
            beginBackgroundTask()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Flux links") { [weak self] in
            MainActor.assumeIsolated { self?.backgroundTimeEnded() }
        }
        if backgroundTask == .invalid, !FeatureHooks.runsInBackground(model: self) { core.stop() }
    }

    private func backgroundTimeEnded() {
        // A live microphone keeps Flux running, and it streams over the links.
        // Else the links close while iOS still gives Flux time.
        if !FeatureHooks.runsInBackground(model: self) { core.stop() }
        endBackgroundTask()
    }

    /// Starts the links for an App Intent, also while Flux is in the
    /// background, and runs `body` with the IDs of the connected, paired
    /// computers, see `FluxCore.waitForPairedLinks`. After `body`, the links
    /// close again when Flux is not on the screen and no other work needs
    /// them, so that the computers see the iPhone leave.
    func withBackgroundLink<T>(timeout: Duration, _ body: @MainActor ([String]) async -> T) async -> T {
        intentsRunning += 1
        FeatureHooks.intentsChanged(model: self)
        core.resume()
        let ids = await core.waitForPairedLinks(timeout: timeout)
        let result = await body(ids)
        intentsRunning -= 1
        FeatureHooks.intentsChanged(model: self)
        stopWhenIdle()
        return result
    }

    /// Closes the links while Flux is off the screen, iOS gives it no
    /// background time, and no feature needs the links in the background.
    private func stopWhenIdle() {
        if !isActive, backgroundTask == .invalid, !FeatureHooks.runsInBackground(model: self) {
            core.stop()
        }
    }

    /// Closes the links when the work that kept Flux running in the
    /// background ends after its background time, such as a microphone
    /// stream that the computer stops.
    private func watchBackgroundWork() {
        withObservationTracking {
            _ = FeatureHooks.runsInBackground(model: self)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.watchBackgroundWork()
                    self.stopWhenIdle()
                }
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Keeps the screen of the iPhone on while a feature needs it, see
    /// `FeatureHooks.keepsScreenOn`. This is the only place that sets the
    /// idle timer, so that 1 screen cannot undo another.
    private func watchScreenAwake() {
        let on = withObservationTracking {
            FeatureHooks.keepsScreenOn(model: self)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.watchScreenAwake() }
            }
        }
        if UIApplication.shared.isIdleTimerDisabled != on { UIApplication.shared.isIdleTimerDisabled = on }
    }
}
