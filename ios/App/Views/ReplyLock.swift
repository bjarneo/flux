import FluxKit
import Foundation
import LocalAuthentication
import SwiftUI
import UIKit

/// Seconds since the first read, on a clock that also counts the time while
/// the iPhone sleeps. The system uptime stops during sleep.
enum ElapsedTime {
    private static let start = ContinuousClock.now

    /// Reads the start before the clock. The first read sets the start, so
    /// the value is never below 0.
    static var now: TimeInterval {
        let origin = start
        return (ContinuousClock.now - origin) / Duration.seconds(1)
    }
}

/// The time during which an unlock stays valid.
struct UnlockWindow {
    let validFor: TimeInterval
    /// The end of the unlock, in `ElapsedTime`. Nil while no unlock is valid.
    private(set) var until: TimeInterval?

    init(validFor: TimeInterval) {
        self.validFor = validFor
    }

    func isUnlocked(at now: TimeInterval) -> Bool { until.map { now < $0 } ?? false }

    mutating func unlock(at now: TimeInterval) { until = now + validFor }

    /// Ends the unlock at once.
    mutating func lock() { until = nil }
}

/// Asks for Face ID, Touch ID, or the passcode before input goes to a
/// computer. Remote keys and replies to agents can make the computer run
/// commands, so the person with the iPhone confirms first. An unlock stays
/// valid for 5 minutes, like the phone lock on Android. It ends before that
/// when the iPhone locks.
@MainActor
enum ReplyLock {
    private static var window = UnlockWindow(validFor: 5 * 60)

    private static var now: TimeInterval { ElapsedTime.now }

    private static var observer: NSObjectProtocol?

    /// Posted when an unlock ends before its time, so that open screens lock.
    static let didLock = Notification.Name("org.omarchy.flux.ReplyLock.didLock")

    /// True while an earlier unlock is still valid.
    static var isUnlocked: Bool { window.isUnlocked(at: now) }

    /// Ends the unlock, and locks the screens that `UnlockGate` shows.
    static func lock() {
        window.lock()
        NotificationCenter.default.post(name: didLock, object: nil)
    }

    /// Ends the unlock when the iPhone locks. iOS tells a running Flux a few
    /// seconds after the lock, when the protected files close. Call it once
    /// at launch.
    static func watch() {
        guard observer == nil else { return }
        // Starts the clock at launch.
        _ = ElapsedTime.now
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { lock() }
        }
    }

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
/// The screen locks again when the iPhone locks, and when Flux comes back
/// after the unlock ended, like the Android app.
struct UnlockGate<Content: View>: View {
    /// The reason under the prompt, a short sentence.
    let reason: String
    @ViewBuilder let content: () -> Content
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = ReplyLock.isUnlocked
    @State private var error: String?
    /// True after Flux left the screen, until it comes back. The prompt
    /// itself makes Flux inactive, so only the background counts.
    @State private var wasAway = false

    var body: some View {
        Group {
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
                // iOS shows no prompt while Flux is off the screen.
                .onAppear { if scenePhase == .active { unlock() } }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReplyLock.didLock)) { _ in unlocked = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { wasAway = true }
            guard phase == .active, wasAway else { return }
            wasAway = false
            if unlocked, !ReplyLock.isUnlocked {
                unlocked = false
            } else if !unlocked {
                unlock()
            }
        }
    }

    private func unlock() {
        error = nil
        ReplyLock.run(reason: reason) { unlocked = true } onError: { error = $0 }
    }
}
