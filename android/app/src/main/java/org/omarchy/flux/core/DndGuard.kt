package org.omarchy.flux.core

/**
 * Keeps Do Not Disturb sync from sending a change back to the side that
 * made it. [known] is the last state of this phone. A state from a
 * computer sets it before the phone applies the state, so the broadcast
 * that follows does not count as a local change. fluxd has the same guard.
 */
class DndGuard(private val settleMs: Long = 3_000) {
    private var known = false
    private var valid = false
    private var pending = false
    private var until = 0L

    /**
     * Takes a state that this phone reports, at the time [now] in
     * milliseconds. Returns true when it is a local change that the
     * computers must get. The first state only sets the start value.
     */
    @Synchronized
    fun local(on: Boolean, now: Long): Boolean {
        if (pending) {
            if (on == known) {
                pending = false
                return false
            }
            // The phone still reports the state from before the change.
            if (now < until) return false
            // The change from the computer did not apply. The phone state wins.
            pending = false
        }
        if (!valid) {
            known = on
            valid = true
            return false
        }
        if (on == known) return false
        known = on
        return true
    }

    /** Takes a state from a computer. Returns true when the phone must apply it. */
    @Synchronized
    fun remote(on: Boolean, now: Long): Boolean {
        if (valid && on == known) return false
        known = on
        valid = true
        pending = true
        until = now + settleMs
        return true
    }
}
