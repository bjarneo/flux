import Foundation
import NIOConcurrencyHelpers
import UserNotifications

/// The one delegate of UNUserNotificationCenter. Features register a
/// category with its actions and a handler, then post notifications in that
/// category. Outside an app bundle, for example in `swift test`, every call
/// does nothing.
public final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = Notifier()

    public typealias Handler = @Sendable (_ actionIdentifier: String, _ userInfo: [AnyHashable: Any], _ replyText: String?) -> Void

    private struct Category {
        var category: UNNotificationCategory
        var handler: Handler
    }
    private let categories = NIOLockedValueBox<[String: Category]>([:])

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter needs an app bundle. The xctest tool has
        // a bundle identifier but is no app, and the center raises there.
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    /// Installs the delegate and asks for permission. Call it once at launch.
    public func start() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if !granted { FluxLog.core.info("notifications not allowed: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Registers a category. Actions with UNTextInputNotificationAction pass
    /// the typed text to the handler.
    public func register(category id: String, actions: [UNNotificationAction] = [], handler: @escaping Handler) {
        let category = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
        let all = categories.withLockedValue { c -> Set<UNNotificationCategory> in
            c[id] = Category(category: category, handler: handler)
            return Set(c.values.map(\.category))
        }
        center?.setNotificationCategories(all)
    }

    /// Shows a notification. A later post with the same id replaces it. A
    /// time-sensitive level shows it through a Focus that allows
    /// time-sensitive notifications, when the app has the time-sensitive
    /// entitlement. Without it, iOS uses the active level.
    public func post(
        id: String,
        category: String,
        title: String,
        body: String,
        subtitle: String? = nil,
        userInfo: [String: Any] = [:],
        sound: UNNotificationSound? = .default,
        attachment: URL? = nil,
        interruptionLevel: UNNotificationInterruptionLevel = .active
    ) {
        guard let center else { return }
        let content = Self.content(category: category, title: title, body: body, subtitle: subtitle, userInfo: userInfo,
                                   sound: sound, interruptionLevel: interruptionLevel)
        if let attachment, let a = try? UNNotificationAttachment(identifier: "file", url: attachment) {
            content.attachments = [a]
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// The content of a notification.
    static func content(
        category: String,
        title: String,
        body: String,
        subtitle: String? = nil,
        userInfo: [String: Any] = [:],
        sound: UNNotificationSound? = .default,
        interruptionLevel: UNNotificationInterruptionLevel = .active
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let subtitle { content.subtitle = subtitle }
        content.categoryIdentifier = category
        content.userInfo = userInfo
        content.sound = sound
        content.interruptionLevel = interruptionLevel
        return content
    }

    public func remove(id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
        center?.removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Passes the IDs of the notifications that Notification Center shows,
    /// the oldest first, to `body` on a queue of the center. It includes
    /// the notifications of an earlier run of Flux.
    func deliveredIds(_ body: @escaping @Sendable ([String]) -> Void) {
        center?.getDeliveredNotifications { notes in
            body(notes.sorted { $0.date < $1.date }.map(\.request.identifier))
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        let handler = categories.withLockedValue { $0[request.content.categoryIdentifier]?.handler }
        let text = (response as? UNTextInputNotificationResponse)?.userText
        handler?(response.actionIdentifier, request.content.userInfo, text)
    }
}
