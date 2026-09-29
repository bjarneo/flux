import Foundation
import FluxProto
import FluxApprove
#if canImport(UserNotifications)
import UserNotifications
#endif

/// M6 approval notifications: the lock-screen path for approval prompts.
/// Ports the Android `Approvals.show` notification (full-screen intent +
/// Deny action): a time-sensitive notification with Approve and Deny
/// actions that opens the prompt over the lock screen. The biometric gate
/// itself stays in the app (`LAContext` + approval-key access control) —
/// answering from the notification still needs Face ID / Touch ID.
///
/// Delivery over a locked phone, action handling while suspended, and the
/// exact lock-screen presentation are device-gated (need entitlements +
/// hardware); the content/category mapping below is unit-tested.
public enum ApproveNotifications {
    /// Category for approval prompts (actions: Approve, Deny).
    public static let categoryId = "org.omarchy.flux.approve"
    public static let approveActionId = "org.omarchy.flux.approve.approve"
    public static let denyActionId = "org.omarchy.flux.approve.deny"

    /// Title for the prompt, e.g. "Approve sudo on omarchy-xps?".
    public static func title(for r: ApproveRequest) -> String {
        switch r.kind {
        case .approve: return "Approve \(r.service) on \(r.host)?"
        case .enroll: return "Enroll this phone on \(r.host)?"
        }
    }

    /// Registers the Approve/Deny category. Call at launch (the desktop
    /// notification bridge registers its own category beside this one).
    public static func registerCategories() {
#if canImport(UserNotifications)
        let approve = UNNotificationAction(
            identifier: approveActionId, title: "Approve",
            options: [.foreground, .authenticationRequired])
        let deny = UNNotificationAction(
            identifier: denyActionId, title: "Deny", options: [])
        let category = UNNotificationCategory(
            identifier: categoryId, actions: [approve, deny],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
#endif
    }

    /// Builds the time-sensitive request content for a held prompt.
    /// Nil without UserNotifications (Linux CI).
    public static func content(for r: ApproveRequest) -> Any? {
#if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = title(for: r)
        content.body = ApproveMessage.question(r)
        content.categoryIdentifier = categoryId
        // One group per prompt: replacing (same identifier on re-post)
        // updates the entry instead of stacking.
        content.threadIdentifier = "flux-approve-\(r.id)"
        if #available(iOS 15.0, macOS 13.0, *) {
            // Level exonerated by the 2026-09-27 device run (off changed
            // nothing), so it is back on; paid builds keep it regardless.
            content.interruptionLevel = .timeSensitive
        }
        return content
#else
        return nil
#endif
    }

    /// Shows the prompt notification now (replaces any earlier prompt —
    /// one request at a time, like Android `ID_APPROVE`). No-op when not
    /// authorized. Removes itself after `timeoutSeconds` via the link's
    /// local expiry + `dismiss(id:)`.
    /// Runs detached (same queue-trap reason as `DesktopNotificationBridge.show`).
    public static func show(_ r: ApproveRequest) {
#if canImport(UserNotifications)
        Task.detached {
            let center = UNUserNotificationCenter.current()
            let settings = try? await center.notificationSettings()
            guard let settings, settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            else {
                print("flux: approve notification NOT shown id=\(r.id) (unauthorized)")
                return
            }
            guard let content = content(for: r) as? UNMutableNotificationContent else { return }
            let request = UNNotificationRequest(
                identifier: notificationId(for: r.id), content: content, trigger: nil)
            do {
                try await center.add(request)
                print("flux: approve notification shown id=\(r.id)")
            } catch {
                // An honest log: `add` can throw after the auth check
                // passed (D22 diagnosis — a printed "shown" must mean
                // the store took it).
                print("flux: approve notification show FAILED id=\(r.id): \(error)")
            }
        }
#endif
    }

    /// Removes the prompt notification for `id` (answered/cancelled/expired).
    public static func dismiss(id: String) {
        print("flux: approve notification dismissed id=\(id)")
#if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [notificationId(for: id)])
        center.removePendingNotificationRequests(withIdentifiers: [notificationId(for: id)])
#endif
    }

    /// Logs whether `id` is currently in the delivered store (D22 audit).
    /// Distinguishes "add lied" (absent right after post) from "removed
    /// afterwards" (present, then gone with no dismiss call) from "human
    /// race" (present at every audit, user looked too early). The app
    /// schedules a delayed audit on backgrounding; `show` audits at post.
    public static func auditDelivery(id: String, tag: String, delaySeconds: UInt64 = 0) {
#if canImport(UserNotifications)
        Task.detached {
            if delaySeconds > 0 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications().map { $0.request.identifier }
            print("flux: approve audit[\(tag)] id=\(id) present=\(ids.contains(notificationId(for: id))) total=\(ids.count)")
        }
#endif
    }

    // MARK: - Action routing (D21)

    /// The notification identifier for a held prompt id. Parsed back by
    /// `promptId(fromNotificationId:)` when a lock-screen action fires.
    public static func notificationId(for promptId: String) -> String {
        "flux-approve-\(promptId)"
    }

    /// Recovers the prompt id from a notification identifier. Nil for
    /// anything this feature did not post (defensive: the delegate only
    /// routes its own category, but identifiers are user-visible).
    public static func promptId(fromNotificationId identifier: String) -> String? {
        let prefix = "flux-approve-"
        guard identifier.hasPrefix(prefix) else { return nil }
        let id = String(identifier.dropFirst(prefix.count))
        guard !id.isEmpty, id.count <= 64 else { return nil }
        return id
    }

    /// Maps a notification action to its verdict. Nil = unknown action
    /// (a plain tap on the notification body opens the app with no
    /// verdict — the sheet is the decision surface there).
    public static func verdict(forActionId actionId: String) -> Bool? {
        switch actionId {
        case approveActionId: return true
        case denyActionId: return false
        default: return nil
        }
    }
}
