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
        if s != state { state = s }
        if let sel = selection, !s.devices.contains(where: { $0.id == sel }) { selection = nil }
        if selection == nil { selection = s.devices.first(where: \.paired)?.id ?? s.devices.first?.id }
        for d in s.devices where d.pairState != .incoming { Notifier.shared.remove(id: "pair-\(d.id)") }
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
    /// press meant for the open page cannot accept it. The sidebar marks the
    /// computer, and a notification shows the request. A click on the
    /// notification selects the computer.
    private func pairRequested(_ d: DeviceSnapshot) {
        if NSApp.isActive { show("\(d.name) wants to pair") }
        Notifier.shared.post(id: "pair-\(d.id)", category: Self.pairCategory, title: "Pair with \(d.name)?",
                             body: "Check that \(d.name) shows the key \(KeyView.grouped(d.pairKey)).",
                             userInfo: ["device": d.id, "key": d.pairKey])
    }
}
