import Foundation

/// The App Group that the app and the share extension share. Its id is the
/// FLUX_APP_GROUP build setting, which both Info.plist files carry.
enum ShareGroup {
    static var identifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "FluxAppGroup") as? String
    }

    /// The folder of the queue and the computer list, or nil when the build
    /// has no App Group, for example a device build whose team does not
    /// own the group id.
    static var root: URL? {
        guard let identifier,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else { return nil }
        return container.appendingPathComponent("Share", isDirectory: true)
    }

    static var defaults: UserDefaults? { identifier.flatMap { UserDefaults(suiteName: $0) } }

    static let lastComputerKey = "share.lastComputer"

    /// The computer that the extension sent to last.
    static var lastComputer: String? {
        get { defaults?.string(forKey: lastComputerKey) }
        set { defaults?.set(newValue, forKey: lastComputerKey) }
    }

    /// The Darwin notification that the extension posts after it queued
    /// items, so that a running app sends them at once.
    static let queuedNotification = "org.omarchy.flux.share.queued"

    static func postQueued() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(queuedNotification as CFString), nil, nil, true)
    }
}
