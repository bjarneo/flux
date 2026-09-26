import Foundation

/// Shows the notifications that a computer sends (kdeconnect.notification),
/// and removes them when the computer cancels them.
///
/// The phone half of the notification plugin, which shares the notifications
/// of other apps with the computer, has no macOS equivalent: macOS gives no
/// app access to the notifications of other apps. So this plugin sends
/// nothing and does not accept kdeconnect.notification.request, .reply, or
/// .action.
public final class NotificationsPlugin: FluxPlugin, @unchecked Sendable {
    public init() {}

    public let incoming = [PacketType.notification]
    public let outgoing: [String] = []

    /// The notification category of computer notifications. It has no actions:
    /// a click opens Flux.
    private static let category = "computer-notification"

    public func handle(_ packet: Packet, from device: Device) {
        guard let n = ComputerNotification(packet, deviceId: device.id, computer: device.name) else { return }
        let id = "computer-\(n.key)"
        if n.cancel {
            FluxLog.plugin.info("notification \(id, privacy: .public) removed")
            Notifier.shared.remove(id: id)
            return
        }
        FluxLog.plugin.info("notification \(id, privacy: .public): \(n.title, privacy: .public) | \(n.text, privacy: .public) | \(n.subtitle, privacy: .public)")
        Notifier.shared.post(id: id, category: Self.category, title: n.title, body: n.text, subtitle: n.subtitle)
    }
}
