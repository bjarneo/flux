import AppKit
import FluxKit
import Observation
import UserNotifications

/// The UI state of the app. It mirrors the core and holds the selection.
@MainActor
@Observable
final class AppModel {
    let core: FluxCore
    private(set) var state = CoreState()
    private(set) var toast: String?
    var selection: String?
    /// The device that the pairing sheet shows.
    var pairingSheet: String?
    private var toastTask: Task<Void, Never>?

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
            DispatchQueue.main.async {
                guard let self else { return }
                switch action {
                case "accept": self.core.acceptPair(id)
                case "reject": self.core.cancelPair(id)
                default:
                    self.selection = id
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    static let pairCategory = "pair"

    var device: DeviceSnapshot? { selection.flatMap { id in state.devices.first { $0.id == id } } }
    var paired: [DeviceSnapshot] { state.devices.filter(\.paired) }
    var available: [DeviceSnapshot] { state.devices.filter { !$0.paired } }
    var connectedPaired: [DeviceSnapshot] { state.devices.filter { $0.paired && $0.online } }

    private func apply(_ s: CoreState) {
        state = s
        if let sel = selection, !s.devices.contains(where: { $0.id == sel }) { selection = nil }
        if selection == nil { selection = s.devices.first(where: \.paired)?.id ?? s.devices.first?.id }
        for d in s.devices where d.pairState != .incoming { Notifier.shared.remove(id: "pair-\(d.id)") }
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    private func pairRequested(_ d: DeviceSnapshot) {
        selection = d.id
        if !NSApp.isActive {
            Notifier.shared.post(id: "pair-\(d.id)", category: Self.pairCategory, title: "Pair with \(d.name)?",
                                 body: "Check that \(d.name) shows the key \(d.pairKey).", userInfo: ["device": d.id])
        }
    }
}
