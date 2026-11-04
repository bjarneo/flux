package org.omarchy.flux.webcam

import java.util.Locale
import kotlin.math.roundToInt

/**
 * A camera that the phone can stream. [id] is the camera to open. With a
 * [physicalId], the frames come from that lens of the logical camera [id],
 * as many phones show their extra back lenses only this way. [fov] is the
 * focal length divided by the sensor width, so a larger value sees a
 * narrower view. It is 0 when the camera does not report it.
 */
data class Lens(
    val id: String,
    val physicalId: String?,
    val facing: String,
    val fov: Float,
)

/** A [Lens] with the name that the settings and the computer show. */
data class NamedLens(val name: String, val lens: Lens)

/**
 * Names the lenses. The first lens of each direction is the main one and
 * keeps the name "back" or "front", so saved settings stay valid. Each
 * other lens is named by its zoom next to the main lens, such as
 * "back 0.6x" or "back 3x". A lens with the same zoom as a named lens of
 * the same direction is the same lens, seen again as a part of a logical
 * camera, and is left out. The back lenses come first, each direction
 * from wide to narrow.
 */
fun nameLenses(lenses: List<Lens>): List<NamedLens> {
    val out = mutableListOf<NamedLens>()
    for (facing in listOf("back", "front")) {
        val group = lenses.filter { it.facing == facing }
        val main = group.firstOrNull() ?: continue
        // A logical camera can leave out its focal length. Its own lenses
        // then give the base: the first one with a focal length is the main lens.
        val base = main.fov.takeIf { it > 0f }
            ?: group.firstOrNull { it.id == main.id && it.physicalId != null && it.fov > 0f }?.fov
            ?: 0f
        val named = mutableListOf(NamedLens(facing, main) to 1f)
        val seenPhysical = mutableSetOf<String>()
        seenPhysical += main.id
        for (lens in group.drop(1)) {
            val key = lens.physicalId ?: lens.id
            if (!seenPhysical.add(key)) continue
            val zoom = if (base > 0f && lens.fov > 0f) lens.fov / base else 0f
            if (zoom > 0f) {
                val label = zoomLabel(zoom)
                if (named.any { (_, z) -> z > 0f && zoomLabel(z) == label }) continue
                named += NamedLens("$facing ${label}x", lens) to zoom
            } else {
                named += NamedLens("$facing ${named.size + 1}", lens) to 0f
            }
        }
        // The main lens first, then the others from wide to narrow. A lens without a zoom goes last.
        val (first, rest) = named.first() to named.drop(1)
        out += first.first
        out += rest.sortedBy { (_, z) -> if (z > 0f) z else Float.MAX_VALUE }.map { it.first }
    }
    return out
}

/** Returns a zoom as 1 decimal without a trailing ".0", such as "0.6" or "3". */
fun zoomLabel(zoom: Float): String {
    val tenths = (zoom * 10f).roundToInt()
    return if (tenths % 10 == 0) (tenths / 10).toString() else String.format(Locale.ROOT, "%.1f", tenths / 10f)
}

/** The most cameras in a list, as fluxd keeps at most 16 values. */
const val MAX_CAMERAS = 16

/**
 * Returns the camera in [all] for [name]: the camera of that name, else
 * the main camera of the same direction, else the first camera.
 */
fun pickNamed(all: List<NamedLens>, name: String): NamedLens? =
    pickName(all.map { it.name }, name)?.let { n -> all.first { it.name == n } }

/** Returns the name in [names] for [name], as [pickNamed] picks it. */
fun pickName(names: List<String>, name: String): String? =
    names.firstOrNull { it == name } ?: names.firstOrNull { it == name.substringBefore(' ') } ?: names.firstOrNull()

/**
 * Returns the names of [all] for the computer, at most [MAX_CAMERAS]. The
 * open camera [current] is always in the list, so the settings keep it.
 */
fun cameraList(all: List<String>, current: String): List<String> {
    val list = all.take(MAX_CAMERAS)
    if (current in list || current !in all) return list.ifEmpty { listOf(current) }
    return list.dropLast(1) + current
}

/** Reports whether [name] has the shape of a camera name, such as "back" or "front 0.6x". */
fun isCameraName(name: String): Boolean = CAMERA_NAME.matches(name)

private val CAMERA_NAME = Regex("^(back|front)( [0-9]+(\\.[0-9])?x?)?$")

/** The cameras of 1 direction: [title] is "Rear" or "Front", and each lens is its name and its button text. */
data class CameraGroup(val title: String, val lenses: List<Pair<String, String>>)

/**
 * Sorts camera names into a "Rear" and a "Front" group. The main lens of a
 * direction shows as "1x" when the direction has more lenses, and the
 * other lenses show their zoom, such as "0.6x". A name of another shape
 * goes into a group of its own, titled by the name.
 */
fun cameraGroups(cameras: List<String>): List<CameraGroup> {
    val titles = mapOf("back" to "Rear", "front" to "Front")
    val byFacing = cameras.groupBy { it.substringBefore(' ') }
    return byFacing.map { (facing, names) ->
        val lenses = names.map { name ->
            val rest = name.substringAfter(' ', "")
            name to when {
                rest.isNotEmpty() -> rest
                names.size > 1 -> "1x"
                else -> titles[facing] ?: cameraTitle(name)
            }
        }
        CameraGroup(titles[facing] ?: cameraTitle(facing), lenses)
    }.sortedBy { if (it.title == "Rear") 0 else if (it.title == "Front") 1 else 2 }
}

/** Returns the button text of a camera name, such as "Back 3x". */
fun cameraTitle(name: String): String = name.replaceFirstChar { it.uppercase() }
