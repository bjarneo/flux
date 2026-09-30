import Foundation

/// The Focus change that paired computers did not get yet. iOS runs the
/// Flux Focus filter also while Flux has no link, for example in the
/// background or before Flux runs. A change then waits here for each
/// computer that was paired at the change, until that computer connects.
/// The state lives in the defaults, because iOS can end Flux before a
/// computer connects.
///
/// Only a change counts: the first Focus state that Flux sees sets the
/// start value, and a state that equals the last one does nothing. A
/// computer that pairs after the change does not get it.
final class FocusBacklog: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    /// The last Focus state that Flux saw, also in an earlier run.
    static let focusKey = "dnd.focus"
    /// The Focus state that computers still need.
    static let unsentKey = "dnd.unsent"
    /// The IDs of the computers that still need `unsentKey`.
    static let waitingKey = "dnd.waiting"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Takes a Focus state. It returns true for a change, which then waits
    /// for each computer in `paired`, the computers that are paired now.
    /// `keep` false records the state but keeps no change, for example
    /// while the sync is off.
    func report(_ on: Bool, paired: [String], keep: Bool = true) -> Bool {
        lock.withLock {
            let last = defaults.object(forKey: Self.focusKey) as? Bool
            defaults.set(on, forKey: Self.focusKey)
            guard let last, last != on else { return false }
            guard keep else {
                clearLocked()
                return false
            }
            save(on, waiting: paired)
            return true
        }
    }

    /// Records the computers that got the state `on`.
    func reached(_ ids: [String], on: Bool) {
        lock.withLock {
            guard defaults.object(forKey: Self.unsentKey) as? Bool == on else { return }
            save(on, waiting: waitingIDs().filter { !ids.contains($0) })
        }
    }

    /// Returns the state that the computer did not get yet, and records
    /// that it gets it now. It returns nil when nothing waits for it.
    func take(for id: String) -> Bool? {
        lock.withLock {
            guard let on = defaults.object(forKey: Self.unsentKey) as? Bool else { return nil }
            let waiting = waitingIDs()
            guard waiting.contains(id) else { return nil }
            save(on, waiting: waiting.filter { $0 != id })
            return on
        }
    }

    /// Stops the wait of a computer that was unpaired, so that it gets no
    /// old change when it pairs again.
    func forget(_ id: String) {
        lock.withLock {
            guard let on = defaults.object(forKey: Self.unsentKey) as? Bool else { return }
            save(on, waiting: waitingIDs().filter { $0 != id })
        }
    }

    /// Forgets the change that waits.
    func clear() {
        lock.withLock { clearLocked() }
    }

    private func waitingIDs() -> [String] {
        defaults.stringArray(forKey: Self.waitingKey) ?? []
    }

    /// Stores the change and the computers that wait for it. It forgets the
    /// change when no computer waits.
    private func save(_ on: Bool, waiting: [String]) {
        guard !waiting.isEmpty else {
            clearLocked()
            return
        }
        defaults.set(on, forKey: Self.unsentKey)
        defaults.set(waiting, forKey: Self.waitingKey)
    }

    private func clearLocked() {
        defaults.removeObject(forKey: Self.unsentKey)
        defaults.removeObject(forKey: Self.waitingKey)
    }
}
