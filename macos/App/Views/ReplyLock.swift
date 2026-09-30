import AppKit
import Foundation
import LocalAuthentication

/// Asks for Touch ID or the Mac password before input goes to a computer.
/// Remote keys and replies to agents can make the computer run commands, so
/// the person at the Mac confirms first. An unlock stays valid for 5 minutes,
/// like the phone lock on Android. It ends before that when this Mac sleeps,
/// its screens sleep, the screen locks, or another user takes the session.
@MainActor
enum ReplyLock {
    private static let validFor: Duration = .seconds(5 * 60)

    /// The end of the unlock, on a clock that also counts the time while
    /// this Mac sleeps. Nil while no unlock is valid.
    private static var until: ContinuousClock.Instant?

    private static var observers: [NSObjectProtocol] = []

    /// True while an earlier unlock is still valid.
    static var isUnlocked: Bool { until.map { ContinuousClock.now < $0 } ?? false }

    /// Ends the unlock, so that the next check asks again.
    static func lock() {
        until = nil
    }

    /// Ends the unlock when this Mac sleeps, its screens sleep, the screen
    /// locks, or the user session changes. Call it once at launch.
    static func watch() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { lock() }
        })
    }

    /// Runs `action` after the check, or at once while an unlock is valid.
    /// `onError` gets a message when the Mac cannot check or the check fails.
    /// A cancel calls neither. macOS shows `reason` after "Flux is trying to",
    /// so it starts with a verb, for example "answer agents on roger".
    static func run(
        reason: String,
        action: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        if isUnlocked {
            action()
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            onError(error?.localizedDescription ?? "This Mac cannot confirm who uses it")
            return
        }
        let done = Completion(action: action, onError: onError)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            let code = (error as? LAError)?.code
            let message = error?.localizedDescription
            Task { @MainActor in
                if ok {
                    until = ContinuousClock.now + validFor
                    done.action()
                } else if let code, [.userCancel, .appCancel, .systemCancel].contains(code) {
                    return
                } else {
                    done.onError(message ?? "The check failed")
                }
            }
        }
    }

    /// Carries the callbacks from the LocalAuthentication queue back to the
    /// main actor, which is the only place that calls them.
    private final class Completion: @unchecked Sendable {
        let action: @MainActor () -> Void
        let onError: @MainActor (String) -> Void

        init(action: @escaping @MainActor () -> Void, onError: @escaping @MainActor (String) -> Void) {
            self.action = action
            self.onError = onError
        }
    }
}
