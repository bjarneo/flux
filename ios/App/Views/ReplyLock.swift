import FluxKit
import Foundation
import LocalAuthentication
import SwiftUI

/// The time during which an unlock stays valid.
struct UnlockWindow {
    let validFor: TimeInterval
    /// The end of the unlock, in system uptime.
    private(set) var until: TimeInterval = 0

    init(validFor: TimeInterval) {
        self.validFor = validFor
    }

    func isUnlocked(at now: TimeInterval) -> Bool { now < until }

    mutating func unlock(at now: TimeInterval) { until = now + validFor }
}

/// Asks for Face ID, Touch ID, or the passcode before input goes to a
/// computer. Remote keys and replies to agents can make the computer run
/// commands, so the person with the iPhone confirms first. An unlock stays
/// valid for 5 minutes while the app runs, like the phone lock on Android.
@MainActor
enum ReplyLock {
    private static var window = UnlockWindow(validFor: 5 * 60)

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// True while an earlier unlock is still valid.
    static var isUnlocked: Bool { window.isUnlocked(at: now) }

    /// Runs `action` after the check, or at once while an unlock is valid.
    /// `onError` gets a message when the iPhone cannot check or the check
    /// fails. A cancel calls neither. iOS shows `reason` under the Touch ID
    /// prompt and on the passcode screen, so it is a short sentence, for
    /// example "Answer agents on roger."
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
            onError(error?.localizedDescription ?? "\(FluxPlatform.current.deviceNounStart) cannot confirm who uses it")
            return
        }
        let done = Completion(action: action, onError: onError)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            let code = (error as? LAError)?.code
            let message = error?.localizedDescription
            Task { @MainActor in
                if ok {
                    window.unlock(at: now)
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

/// Shows its content only after the check of `ReplyLock`. A tile checks
/// before it opens a screen whose controls are on, but the controls can
/// turn on while the screen is open, and then this checks in the screen.
struct UnlockGate<Content: View>: View {
    /// The reason under the prompt, a short sentence.
    let reason: String
    @ViewBuilder let content: () -> Content
    @State private var unlocked = ReplyLock.isUnlocked
    @State private var error: String?

    var body: some View {
        if unlocked {
            content()
        } else {
            ContentUnavailableView {
                Label("Locked", systemImage: "lock")
            } description: {
                Text(error ?? reason)
            } actions: {
                Button("Unlock") { unlock() }
                    .buttonStyle(.borderedProminent)
            }
            .onAppear { unlock() }
        }
    }

    private func unlock() {
        error = nil
        ReplyLock.run(reason: reason) { unlocked = true } onError: { error = $0 }
    }
}
