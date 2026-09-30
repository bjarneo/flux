import Foundation
import NIOConcurrencyHelpers
import UserNotifications

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

    /// Counts the notifications of an earlier run toward the limit of each
    /// computer, before the network starts.
    public func attach(core: FluxCore) {
        DeliveredNotifications.seed()
    }

    public func handle(_ packet: Packet, from device: Device) {
        guard let n = ComputerNotification(packet, deviceId: device.id, computer: device.name) else { return }
        let id = DeliveredNotifications.notificationPrefix + n.key
        let grant = NotificationLimit.takeNow(device.id)
        guard grant != .drop else {
            FluxLog.plugin.info("notification \(id, privacy: .public) dropped: too many from this computer")
            return
        }
        // The text can be private, so the log keeps it out of reach of other apps.
        FluxLog.plugin.info("notification \(id, privacy: .public): \(n.title, privacy: .private) | \(n.text, privacy: .private) | \(n.subtitle, privacy: .private)")
        DeliveredNotifications.post(id: id, deviceId: device.id)
        Notifier.shared.post(id: id, category: Self.category, title: n.title, body: n.text, subtitle: n.subtitle,
                             sound: grant == .sound ? UNNotificationSound.default : nil)
    }
}

/// The delivered notifications of each computer, the oldest first. A
/// computer keeps at most `cap` of them, so that it cannot fill
/// Notification Center.
struct DeliveredNotifications {
    static let cap = 20

    /// The notifications and received links of all computers.
    private static let shared = NIOLockedValueBox(DeliveredNotifications())

    /// Adds the notification `id` of the computer before its post, and
    /// removes the oldest notifications of the computer above `cap`.
    static func post(id: String, deviceId: String) {
        let old = shared.withLockedValue { $0.add(id, deviceId: deviceId) }
        for oldId in old { Notifier.shared.remove(id: oldId) }
    }

    /// Adds the notifications of the computers that Notification Center
    /// still shows from an earlier run, so that the limit holds after a
    /// restart. It removes the oldest notifications above `cap`.
    static func seed() {
        Notifier.shared.deliveredIds { found in
            let old = Self.shared.withLockedValue { $0.seed(found) }
            for oldId in old { Notifier.shared.remove(id: oldId) }
        }
    }

    /// The start of the ID of a computer notification. The ID continues
    /// with the device ID, a colon, and the ID from the computer.
    static let notificationPrefix = "computer-"
    /// The start of the ID of a received link. The ID continues with the
    /// device ID, a colon, and a UUID.
    static let linkPrefix = "share-link-"

    /// A new notification ID for a received link of the computer.
    static func linkId(deviceId: String) -> String { "\(linkPrefix)\(deviceId):\(UUID().uuidString)" }

    /// The device ID in the ID of a computer notification or a received
    /// link, or nil for the ID of another notification.
    static func deviceId(of id: String) -> String? {
        for prefix in [notificationPrefix, linkPrefix] where id.hasPrefix(prefix) {
            let rest = id.dropFirst(prefix.count)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let deviceId = String(rest[..<colon])
            return validDeviceId(deviceId) ? deviceId : nil
        }
        return nil
    }

    private var ids: [String: [String]] = [:]

    /// Adds the delivered IDs of an earlier run, the oldest first, before
    /// the IDs of this run, and returns the IDs to remove, the oldest first.
    /// It skips the IDs that are in the list and the IDs of other
    /// notifications.
    mutating func seed(_ found: [String]) -> [String] {
        var earlier: [String: [String]] = [:]
        for id in found {
            guard let deviceId = Self.deviceId(of: id), ids[deviceId]?.contains(id) != true,
                  earlier[deviceId]?.contains(id) != true else { continue }
            earlier[deviceId, default: []].append(id)
        }
        var old: [String] = []
        for (deviceId, seeded) in earlier {
            var list = seeded + ids[deviceId, default: []]
            let drop = Array(list.prefix(max(0, list.count - Self.cap)))
            list.removeFirst(drop.count)
            ids[deviceId] = list
            old += drop
        }
        return old
    }

    /// Adds the notification `id` of the device and returns the IDs to
    /// remove, the oldest first. A post with an ID that is in the list
    /// replaces that notification, so the ID moves to the end.
    mutating func add(_ id: String, deviceId: String) -> [String] {
        var list = ids[deviceId, default: []]
        list.removeAll { $0 == id }
        list.append(id)
        let old = Array(list.prefix(max(0, list.count - Self.cap)))
        list.removeFirst(old.count)
        ids[deviceId] = list
        return old
    }

    /// The delivered IDs of the device, the oldest first.
    func delivered(_ deviceId: String) -> [String] { ids[deviceId] ?? [] }
}

/// A token bucket for each computer: a burst of `burst` notifications, then
/// `perSecond` each second.
struct NotificationLimit {
    static let burst = 10.0
    static let perSecond = 1.0

    /// What a new notification of a computer can do now.
    enum Grant: Equatable {
        /// The notification must not show.
        case drop
        /// The notification shows without a sound, because it is part of a burst.
        case quiet
        /// The notification shows with a sound.
        case sound
    }

    /// The limit of all notifications that a computer causes, such as
    /// flux.notification packets and received links, so that a computer
    /// cannot bury the other notifications of this device.
    private static let shared = NIOLockedValueBox(NotificationLimit())

    /// Takes a token of the computer from the shared limit now. It returns
    /// false when the notification must not show.
    static func allowsNow(_ deviceId: String) -> Bool { takeNow(deviceId) != .drop }

    /// Takes a token of the computer from the shared limit now.
    static func takeNow(_ deviceId: String) -> Grant {
        let now = ProcessInfo.processInfo.systemUptime
        return shared.withLockedValue { $0.take(deviceId, now: now) }
    }

    private var buckets: [String: (tokens: Double, at: TimeInterval)] = [:]

    /// Reports whether a notification from the device may show now, and
    /// takes a token for it. `now` is in seconds of uptime.
    mutating func allow(_ deviceId: String, now: TimeInterval) -> Bool { take(deviceId, now: now) != .drop }

    /// Takes a token for a notification from the device. Only a
    /// notification that finds the full burst makes a sound, so that a
    /// burst makes 1 sound. `now` is in seconds of uptime.
    mutating func take(_ deviceId: String, now: TimeInterval) -> Grant {
        let last = buckets[deviceId] ?? (tokens: Self.burst, at: now)
        let tokens = min(Self.burst, last.tokens + max(0, now - last.at) * Self.perSecond)
        guard tokens >= 1 else {
            buckets[deviceId] = (tokens: tokens, at: now)
            return .drop
        }
        buckets[deviceId] = (tokens: tokens - 1, at: now)
        return tokens >= Self.burst ? .sound : .quiet
    }
}
