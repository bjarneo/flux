package org.omarchy.flux.core

/** The kinds of new images that Flux sends by itself. */
enum class CaptureKind { Screenshot, Photo }

/** 1 image from MediaStore, as the capture watch reads it. */
data class MediaImage(
    val id: Long,
    val relativePath: String,
    val name: String,
    val pending: Boolean,
    /** The time that MediaStore added the image, in seconds. */
    val dateAdded: Long,
)

/** The folders of new screenshots and camera photos. */
object CaptureRules {
    /** A pending image that is older than this is lost. The watch does not wait for it. */
    const val PENDING_LIMIT_SEC = 24 * 60 * 60L

    /** Returns the kind of an image in [relativePath], or null for an image in another folder. */
    fun kindOf(relativePath: String): CaptureKind? {
        val p = relativePath.trim().trim('/').lowercase() + "/"
        return when {
            p.startsWith("pictures/screenshots/") || p.startsWith("dcim/screenshots/") -> CaptureKind.Screenshot
            p.startsWith("dcim/camera/") -> CaptureKind.Photo
            else -> null
        }
    }
}

/**
 * What the capture watch has done, so that no image goes out twice.
 * Every image up to [baseline] is done. [sent] holds the images after the
 * baseline that went out. [from] holds, for each switch that is on, the
 * newest image at the time that the switch turned on. Only a newer image
 * of that kind goes out.
 */
data class CaptureState(
    val baseline: Long = 0,
    val sent: Set<Long> = emptySet(),
    val from: Map<CaptureKind, Long> = emptyMap(),
) {
    /** Turns a kind on. [newest] is the newest image ID now. */
    fun enable(kind: CaptureKind, newest: Long): CaptureState {
        if (kind in from) return this
        // With no switch on, nothing older than now needs a look.
        return if (from.isEmpty()) {
            CaptureState(baseline = newest, sent = emptySet(), from = mapOf(kind to newest))
        } else {
            copy(from = from + (kind to newest))
        }
    }

    fun disable(kind: CaptureKind): CaptureState = copy(from = from - kind)

    fun markSent(id: Long): CaptureState = copy(sent = sent + id)
}

/** The result of 1 scan: the images to send now, and the new state. */
data class CapturePlan(val send: List<Pair<MediaImage, CaptureKind>>, val state: CaptureState)

/** The most IDs that [CaptureState.sent] keeps. */
const val MAX_SENT = 500

/**
 * Plans a scan of the images after the baseline. An image goes out when
 * it is complete, it is in a watched folder, its switch is on, it is newer
 * than the time that the switch turned on, and it did not go out before.
 * The baseline moves up through the images that need no more work. A
 * pending image or an image that did not go out yet stops it, so that the
 * next scan looks at that image again. [now] is the time in seconds.
 */
fun planCapture(state: CaptureState, images: List<MediaImage>, now: Long): CapturePlan {
    val send = mutableListOf<Pair<MediaImage, CaptureKind>>()
    var baseline = state.baseline
    var blocked = false
    for (img in images.filter { it.id > state.baseline }.sortedBy { it.id }) {
        val done = when {
            img.id in state.sent -> true
            img.pending -> now - img.dateAdded > CaptureRules.PENDING_LIMIT_SEC
            else -> {
                val kind = CaptureRules.kindOf(img.relativePath)
                val start = kind?.let { state.from[it] }
                if (kind != null && start != null && img.id > start) {
                    send += img to kind
                    false
                } else {
                    true
                }
            }
        }
        if (!done) blocked = true
        if (done && !blocked) baseline = img.id
    }
    val sent = state.sent.filter { it > baseline }.sorted().takeLast(MAX_SENT).toSet()
    return CapturePlan(send, state.copy(baseline = baseline, sent = sent))
}
