import Foundation

/// Keeps Do Not Disturb sync from sending a change back to the side that
/// made it. `known` is the last state of this Mac. A state from a computer
/// sets it before the Mac applies the state, so the Focus read that follows
/// does not count as a local change. fluxd and the Android app have the same
/// guard.
final class DndGuard: @unchecked Sendable {
    private let settleMs: Int64
    private let lock = NSLock()
    private var known = false
    private var valid = false
    private var pending = false
    private var until: Int64 = 0

    init(settleMs: Int64 = 3_000) {
        self.settleMs = settleMs
    }

    /// Takes a state that this Mac reports, at the time `now` in
    /// milliseconds. Returns true when it is a local change that the
    /// computers must get. The first state only sets the start value.
    func local(_ on: Bool, now: Int64) -> Bool {
        lock.withLock {
            if pending {
                if on == known {
                    pending = false
                    return false
                }
                // The Mac still reports the state from before the change.
                if now < until { return false }
                // The change from the computer did not apply. The Mac state wins.
                pending = false
            }
            if !valid {
                known = on
                valid = true
                return false
            }
            if on == known { return false }
            known = on
            return true
        }
    }

    /// Takes a state from a computer. Returns true when the Mac must apply it.
    func remote(_ on: Bool, now: Int64) -> Bool {
        lock.withLock {
            if valid && on == known { return false }
            known = on
            valid = true
            pending = true
            until = now + settleMs
            return true
        }
    }
}
