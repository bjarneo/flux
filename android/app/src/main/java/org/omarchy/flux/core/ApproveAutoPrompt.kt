package org.omarchy.flux.core

/**
 * Decides when the Approve screen opens the fingerprint check by itself.
 * It has no Android dependency, so the JVM tests check it. The check
 * itself, and the signature that follows it, do not change.
 */
object ApproveAutoPrompt {
    /** The first Android version where the screen can hide the windows of other apps (Android 12). */
    const val MIN_SDK = 31

    /**
     * True when the fingerprint check opens now for [request].
     *
     * - [enabled]: the user turned the setting on. It is off by default.
     * - [sdk]: only Android 12 and later, where the screen hides the windows of other apps. The tap check of the Approve button then has nothing left to protect.
     * - [asking]: the screen waits for an answer, not in the middle of a check.
     * - [openedId]: the id of the request whose check already opened, so a cancel keeps the screen and the check does not open twice.
     *
     * An enrollment never opens by itself. It makes a new key, so the user must ask for it.
     */
    fun shouldOpen(request: ApproveRequest?, enabled: Boolean, sdk: Int, asking: Boolean, openedId: String?): Boolean =
        request != null &&
            request.kind == ApproveRequest.Kind.Approve &&
            enabled &&
            sdk >= MIN_SDK &&
            asking &&
            openedId != request.id
}
