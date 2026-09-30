import FluxKit
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// A screen on the navigation stack.
enum Route: Hashable {
    case device(String)
    case settings
    /// A screen of a feature, see `FeatureRoute`.
    case feature(FeatureRoute)
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
    var path: [Route] = []
    /// The computer that the pairing sheet asks to pair with.
    var pairingSheet: String?
    /// False while the app is off the screen.
    private(set) var isActive = false
    /// True while the touchpad shows. The screen of the iPhone stays on then.
    var touchpadOpen = false
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
        // A new pairing opens the computer's screen. Flux asks for
        // notifications here, so that the question comes with a reason.
        if let id = Self.newlyPaired(old: old.devices.map { ($0.id, $0.paired) }, new: s.devices.map { ($0.id, $0.paired) }).first {
            pairingSheet = nil
            path = [.device(id)]
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
            core.resume()
            FeatureHooks.sceneChanged(active: true, model: self)
        case .background:
            isActive = false
            guard !demo else { return }
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
                    if !self.isActive, self.backgroundTask == .invalid, !FeatureHooks.runsInBackground(model: self) {
                        self.core.stop()
                    }
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
