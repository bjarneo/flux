import Foundation

/// The Focus change that paired computers did not get yet. iOS runs the
/// Flux Focus filter also while Flux has no link, for example in the
/// background or before Flux runs. A change then waits here until each
/// computer connects. The state lives in the defaults, because iOS can end
/// Flux before a computer connects.
///
/// Only a change counts: the first Focus state that Flux sees sets the
/// start value, and a state that equals the last one does nothing.
final class FocusBacklog: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    /// The last Focus state that Flux saw, also in an earlier run.
    static let focusKey = "dnd.focus"
    /// The Focus state that computers still need.
    static let unsentKey = "dnd.unsent"
    /// The IDs of the computers that got `unsentKey`.
    static let reachedKey = "dnd.reached"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Takes a Focus state. It returns true for a change, which then waits
    /// for each computer. `keep` false records the state but keeps no
    /// change, for example while the sync is off.
    func report(_ on: Bool, keep: Bool = true) -> Bool {
        lock.withLock {
            let last = defaults.object(forKey: Self.focusKey) as? Bool
            defaults.set(on, forKey: Self.focusKey)
            guard let last, last != on else { return false }
            guard keep else {
                clearLocked()
                return false
            }
            defaults.set(on, forKey: Self.unsentKey)
            defaults.set([String](), forKey: Self.reachedKey)
            return true
        }
    }

    /// Records the computers that got the state `on`.
    func reached(_ ids: [String], on: Bool) {
        lock.withLock {
            guard defaults.object(forKey: Self.unsentKey) as? Bool == on else { return }
            let reached = defaults.stringArray(forKey: Self.reachedKey) ?? []
            defaults.set(reached + ids.filter { !reached.contains($0) }, forKey: Self.reachedKey)
        }
    }

    /// Returns the state that the computer did not get yet, and records
    /// that it gets it now. It returns nil when nothing waits for it.
    func take(for id: String) -> Bool? {
        lock.withLock {
            guard let on = defaults.object(forKey: Self.unsentKey) as? Bool else { return nil }
            let reached = defaults.stringArray(forKey: Self.reachedKey) ?? []
            guard !reached.contains(id) else { return nil }
            defaults.set(reached + [id], forKey: Self.reachedKey)
            return on
        }
    }

    /// Forgets the change that waits.
    func clear() {
        lock.withLock { clearLocked() }
    }

    private func clearLocked() {
        defaults.removeObject(forKey: Self.unsentKey)
        defaults.removeObject(forKey: Self.reachedKey)
    }
}
