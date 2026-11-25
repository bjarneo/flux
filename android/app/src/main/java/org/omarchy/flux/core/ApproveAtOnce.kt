package org.omarchy.flux.core

/**
 * The rules for the fingerprint check at once. When the switch is on, the
 * approval screen opens the fingerprint prompt with no tap. docs/approve.md
 * describes why each rule exists.
 */
object ApproveAtOnce {
    /** The first Android version where the approval screen hides the windows of other apps. */
    const val MIN_SDK = 31

    /** True when this Android version can turn the switch on. */
    fun supported(sdk: Int): Boolean = sdk >= MIN_SDK

    /**
     * True when the approval screen opens the prompt now.
     *
     * @param enabled the switch is on.
     * @param kind the kind of the request. Only an approval opens the prompt.
     * @param sdk the Android version.
     * @param resumed the screen is resumed.
     * @param focused the window of the screen has the focus.
     * @param requestId the ID of the request on the screen.
     * @param openedFor the ID of the request for which the screen opened the prompt before, or null.
     */
    fun shouldOpen(
        enabled: Boolean,
        kind: ApproveRequest.Kind,
        sdk: Int,
        resumed: Boolean,
        focused: Boolean,
        requestId: String,
        openedFor: String?,
    ): Boolean =
        enabled && kind == ApproveRequest.Kind.Approve && supported(sdk) && resumed && focused && openedFor != requestId

    private const val KEEP = 64
    private val opened = LinkedHashSet<String>()

    /** True when the prompt opened before for this request ID in this process. */
    @Synchronized
    fun wasOpened(requestId: String): Boolean = requestId in opened

    /**
     * Records that the prompt opened for this request ID. The record lives as long as the process,
     * so a new screen for the same request does not open the prompt again. It keeps the last 64 IDs.
     */
    @Synchronized
    fun markOpened(requestId: String) {
        opened.add(requestId)
        while (opened.size > KEEP) opened.remove(opened.first())
    }

    /** Clears the record. Only tests call this. */
    @Synchronized
    internal fun resetOpened() = opened.clear()
}
