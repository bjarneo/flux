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
    /**
     * False when an app that is not a camera or screenshot app of the phone
     * wrote the image. Any app can add an image to a camera folder, so
     * Flux does not send such an image by itself.
     */
    val trusted: Boolean = true,
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

/** An image that no computer took: the number of failed tries, and the time of the next try in seconds. */
data class CaptureRetry(val failures: Int, val next: Long)

/**
 * The waits after an image that no computer took. The first wait is 1
 * minute, each wait doubles, and a wait is at most 1 hour. After
 * [MAX_TRIES] tries, the watch gives up on the image.
 */
object CaptureRetries {
    const val FIRST_WAIT_SEC = 60L
    const val MAX_WAIT_SEC = 60 * 60L
    const val MAX_TRIES = 8

    /** Returns the wait after [failures] failed tries, in seconds. */
    fun wait(failures: Int): Long = (FIRST_WAIT_SEC shl (failures - 1).coerceIn(0, 6)).coerceAtMost(MAX_WAIT_SEC)

    /** Returns the retry after 1 more failed try at [now], in seconds. */
    fun failed(old: CaptureRetry?, now: Long): CaptureRetry {
        val n = (old?.failures ?: 0) + 1
        return CaptureRetry(n, now + wait(n))
    }

    /** True when the watch gives up on an image after [r]. */
    fun givesUp(r: CaptureRetry): Boolean = r.failures >= MAX_TRIES

    /**
     * Returns the time of the next try in seconds, or null when no image
     * waits for a time. An image in [busy] waits for the end of its upload,
     * so its time does not count.
     */
    fun nextTry(retries: Map<Long, CaptureRetry>, busy: Set<Long>): Long? =
        retries.filterKeys { it !in busy }.values.minOfOrNull { it.next }
}

/** The result of 1 scan: the images to send now, and the new state. */
data class CapturePlan(val send: List<Pair<MediaImage, CaptureKind>>, val state: CaptureState)

/** The most IDs that [CaptureState.sent] keeps. */
const val MAX_SENT = 500

/**
 * Plans a scan of the images after the baseline. An image goes out when
 * it is complete, it is in a watched folder, a camera or screenshot app
 * wrote it, its switch is on, it is newer than the time that the switch
 * turned on, and it did not go out before. An image in [retries] waits
 * until the time of its next try. An image in [busy] waits while an
 * earlier upload of it goes on. The baseline moves up through the images
 * that need no more work. A pending image or an image that did not go out
 * yet stops it, so that the next scan looks at that image again. [now] is
 * the time in seconds.
 */
fun planCapture(
    state: CaptureState,
    images: List<MediaImage>,
    now: Long,
    retries: Map<Long, CaptureRetry> = emptyMap(),
    busy: Set<Long> = emptySet(),
): CapturePlan {
    val send = mutableListOf<Pair<MediaImage, CaptureKind>>()
    var baseline = state.baseline
    var blocked = false
    for (img in images.filter { it.id > state.baseline }.sortedBy { it.id }) {
        val done = when {
            img.id in state.sent -> true
            img.pending -> now - img.dateAdded > CaptureRules.PENDING_LIMIT_SEC
            !img.trusted -> true
            else -> {
                val kind = CaptureRules.kindOf(img.relativePath)
                val start = kind?.let { state.from[it] }
                if (kind != null && start != null && img.id > start) {
                    // An image that waits for its next try or for its upload still stops the baseline.
                    if (img.id !in busy && (retries[img.id]?.next ?: 0) <= now) send += img to kind
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
