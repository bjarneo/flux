package org.omarchy.flux.core

/**
 * The time after a connection attempt in which a paired computer that is
 * not online counts as connecting, not as not reachable. A cold start loads
 * the paired computers before their links connect, so without this time the
 * Inbox shows a false error first. In milliseconds.
 */
const val CONNECT_GRACE_MS = 3_000L

/**
 * True while the connection attempt at [startedAt] is younger than [grace].
 * [startedAt] is 0 before the first attempt. Both times come from the same
 * clock, [android.os.SystemClock.elapsedRealtime].
 */
fun inConnectGrace(startedAt: Long, now: Long, grace: Long = CONNECT_GRACE_MS): Boolean =
    startedAt > 0L && now >= startedAt && now - startedAt < grace
