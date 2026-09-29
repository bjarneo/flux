import Foundation
import NIOConcurrencyHelpers

/// Shows the notifications that a computer sends in flux.notification
/// packets.
///
/// The phone half of the notification plugin, which shares the notifications
/// of other apps with the computer, has no macOS equivalent: macOS gives no
/// app access to the notifications of other apps. So this plugin sends
/// nothing and does not accept flux.notification.request, .reply, or
/// .action.
public final class NotificationsPlugin: FluxPlugin, @unchecked Sendable {
    public init() {}

    public let incoming = [PacketType.notification]
    public let outgoing: [String] = []

    /// The notification category of computer notifications. It has no actions:
    /// a click opens Flux.
    private static let category = "computer-notification"

    /// Limits the notifications of each computer, so that a computer cannot
    /// bury the other notifications of this device.
    private let limit = NIOLockedValueBox(NotificationLimit())

    public func handle(_ packet: Packet, from device: Device) {
        guard let n = ComputerNotification(packet, deviceId: device.id, computer: device.name) else { return }
        let id = "computer-\(n.key)"
        let now = ProcessInfo.processInfo.systemUptime
        guard limit.withLockedValue({ $0.allow(device.id, now: now) }) else {
            FluxLog.plugin.info("notification \(id, privacy: .public) dropped: too many from this computer")
            return
        }
        // The text can be private, so the log keeps it out of reach of other apps.
        FluxLog.plugin.info("notification \(id, privacy: .public): \(n.title, privacy: .private) | \(n.text, privacy: .private) | \(n.subtitle, privacy: .private)")
        Notifier.shared.post(id: id, category: Self.category, title: n.title, body: n.text, subtitle: n.subtitle)
    }
}

/// A token bucket for each computer: a burst of `burst` notifications, then
/// `perSecond` each second.
struct NotificationLimit {
    static let burst = 10.0
    static let perSecond = 1.0

    private var buckets: [String: (tokens: Double, at: TimeInterval)] = [:]

    /// Reports whether a notification from the device may show now, and
    /// takes a token for it. `now` is in seconds of uptime.
    mutating func allow(_ deviceId: String, now: TimeInterval) -> Bool {
        let last = buckets[deviceId] ?? (tokens: Self.burst, at: now)
        let tokens = min(Self.burst, last.tokens + max(0, now - last.at) * Self.perSecond)
        guard tokens >= 1 else {
            buckets[deviceId] = (tokens: tokens, at: now)
            return false
        }
        buckets[deviceId] = (tokens: tokens - 1, at: now)
        return true
    }
}
