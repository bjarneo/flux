import Foundation
import Observation
import UserNotifications

/// Find my phone in both directions (kdeconnect.findmyphone.request). A
/// computer rings this Mac, and this Mac rings a computer.
public final class FindMyPhonePlugin: FluxPlugin, @unchecked Sendable {
    private weak var core: FluxCore?
    /// The ring state that the ring window shows.
    public let model: RingModel

    @MainActor
    public init() { model = RingModel() }

    public let incoming = [PacketType.findMyPhone]
    public let outgoing = [PacketType.findMyPhone]

    public func attach(core: FluxCore) {
        self.core = core
        let model = model
        Notifier.shared.register(category: RingModel.category, actions: [
            UNNotificationAction(identifier: "stop", title: "I found it"),
        ]) { _, _, _ in
            // Both the button and a click on the notification stop the ring.
            Task { @MainActor in model.stop() }
        }
    }

    public func handle(_ packet: Packet, from device: Device) {
        let (id, name) = (device.id, device.name)
        let model = model
        Task { @MainActor in model.ring(from: name, deviceId: id) }
    }

    /// Rings a paired, connected computer.
    public func ring(_ deviceId: String) {
        guard let core else { return }
        if core.send(Packet(PacketType.findMyPhone), to: deviceId) {
            core.toast("Ringing \(core.device(deviceId)?.name ?? "the computer")")
        } else {
            core.toast("Not connected. Try again in a moment")
        }
    }
}

/// Rings this Mac for a computer until the user stops it.
@MainActor
@Observable
public final class RingModel {
    /// The name of the computer that rings this Mac, or nil.
    public private(set) var ringingFrom: String?
    /// The device ID of the computer that rings this Mac, or nil.
    public private(set) var ringingDevice: String?

    nonisolated static let category = "ring"
    private static let notificationId = "ring"
    /// A ring that nobody stops ends after 2 minutes.
    private static let maxRing: Duration = .seconds(120)

    @ObservationIgnored private let ringer = Ringer()
    @ObservationIgnored private var timeout: Task<Void, Never>?

    init() {}

    /// Starts to ring. A second request while the Mac rings stops it, so the
    /// computer can stop a ring that nobody can reach on the Mac.
    func ring(from computer: String, deviceId: String) {
        if ringingFrom != nil {
            stop()
            return
        }
        FluxLog.plugin.info("ringing for \(computer, privacy: .public)")
        ringingFrom = computer
        ringingDevice = deviceId
        ringer.start()
        Notifier.shared.post(id: Self.notificationId, category: Self.category, title: "\(computer) is ringing this Mac",
                             body: "Click to stop", sound: nil)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.maxRing)
            if !Task.isCancelled { self?.stop() }
        }
    }

    /// Stops the ring and removes its notification.
    public func stop() {
        guard ringingFrom != nil else { return }
        FluxLog.plugin.info("ring stopped")
        ringingFrom = nil
        ringingDevice = nil
        timeout?.cancel()
        timeout = nil
        ringer.stop()
        Notifier.shared.remove(id: Self.notificationId)
    }
}
