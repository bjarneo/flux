package org.omarchy.flux.theme

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/*
 * The color math of the theme engine. A color is an Int in the form
 * 0xRRGGBB. The functions ignore the alpha byte. They use no Android class,
 * so the unit tests run them on the JVM.
 */

/** The color without its alpha byte. */
internal fun opaque(rgb: Int): Int = rgb and 0xFFFFFF

private fun channel(rgb: Int, shift: Int): Int = (rgb shr shift) and 0xFF

/** Decodes 1 sRGB channel, from 0 to 255, to linear light. */
private fun linear(c: Int): Double {
    val v = c / 255.0
    return if (v <= 0.04045) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
}

/** Encodes linear light to 1 sRGB channel, from 0 to 255. */
private fun encode(v: Double): Int {
    val c = v.coerceIn(0.0, 1.0)
    val s = if (c <= 0.0031308) c * 12.92 else 1.055 * c.pow(1 / 2.4) - 0.055
    return (s * 255).roundToInt().coerceIn(0, 255)
}

/** The relative luminance of WCAG 2.2, from 0 for black to 1 for white. */
fun luminance(rgb: Int): Double =
    0.2126 * linear(channel(rgb, 16)) + 0.7152 * linear(channel(rgb, 8)) + 0.0722 * linear(channel(rgb, 0))

/** The contrast ratio of WCAG 2.2, from 1 to 21. The order of the colors does not matter. */
fun contrast(a: Int, b: Int): Double = ratio(luminance(a), luminance(b))

private fun ratio(la: Double, lb: Double): Double =
    if (la > lb) (la + 0.05) / (lb + 0.05) else (lb + 0.05) / (la + 0.05)

/** The color at [t] on the line from [a] to [b] in sRGB. [t] = 0 gives [a], and [t] = 1 gives [b]. */
fun mix(a: Int, b: Int, t: Double): Int {
    fun m(shift: Int): Int {
        val x = channel(a, shift)
        return (x + (channel(b, shift) - x) * t).roundToInt().coerceIn(0, 255) shl shift
    }
    return m(16) or m(8) or m(0)
}

/** A color in OKLCH: the lightness [l] from 0 to 1, the chroma [c], and the hue [h] in radians. */
data class Oklch(val l: Double, val c: Double, val h: Double)

/** Converts a color to OKLCH. */
fun oklch(rgb: Int): Oklch {
    val r = linear(channel(rgb, 16))
    val g = linear(channel(rgb, 8))
    val b = linear(channel(rgb, 0))
    val l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    val m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    val s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    val lab = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    val a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    val bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return Oklch(lab, hypot(a, bb), atan2(bb, a))
}

/**
 * The distance of 2 colors in OKLAB, from 0 for the same color. 0.02 is
 * about the smallest difference that people see. 0.1 is a clear
 * difference.
 */
fun distance(a: Int, b: Int): Double {
    val x = oklch(a)
    val y = oklch(b)
    val da = x.c * cos(x.h) - y.c * cos(y.h)
    val db = x.c * sin(x.h) - y.c * sin(y.h)
    return sqrt((x.l - y.l).pow(2) + da * da + db * db)
}

/** Converts OKLAB to linear sRGB. The values can be outside 0 to 1. */
private fun linearRgb(l: Double, a: Double, b: Double): DoubleArray {
    val l3 = (l + 0.3963377774 * a + 0.2158037573 * b).pow(3)
    val m3 = (l - 0.1055613458 * a - 0.0638541728 * b).pow(3)
    val s3 = (l - 0.0894841775 * a - 1.2914855480 * b).pow(3)
    return doubleArrayOf(
        4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
        -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
        -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3,
    )
}

private const val GAMUT_EPSILON = 1e-4

private fun inGamut(v: DoubleArray): Boolean = v.all { it >= -GAMUT_EPSILON && it <= 1 + GAMUT_EPSILON }

/**
 * Converts OKLCH to a color. A color outside sRGB loses chroma until it
 * fits. The lightness and the hue stay.
 */
fun rgbOf(c: Oklch): Int {
    fun at(chroma: Double) = linearRgb(c.l, chroma * cos(c.h), chroma * sin(c.h))
    var v = at(c.c)
    if (!inGamut(v)) {
        var lo = 0.0
        var hi = c.c
        repeat(24) {
            val mid = (lo + hi) / 2
            if (inGamut(at(mid))) lo = mid else hi = mid
        }
        v = at(lo)
    }
    return (encode(v[0]) shl 16) or (encode(v[1]) shl 8) or encode(v[2])
}

/** A minimum contrast [ratio] of a color against the color [against]. */
class Need(val against: Int, val ratio: Double) {
    internal val lum = luminance(against)
}

/** True when [rgb] meets each of the [needs]. */
fun meets(rgb: Int, needs: List<Need>): Boolean = needs.all { contrast(rgb, it.against) >= it.ratio }

/** The step of the lightness search, in OKLCH lightness. */
private const val LIGHTNESS_STEP = 0.002

/**
 * The contrast guard. It moves the lightness of [rgb] until the color meets
 * each of the [needs], and it keeps the hue. It takes the smallest move,
 * and it tries the lighter side first when [lighter] is true. A color that
 * meets the needs stays as it is. When no lightness meets every need, the
 * guard returns the color that comes closest.
 */
fun guard(rgb: Int, needs: List<Need>, lighter: Boolean): Int {
    val start = opaque(rgb)
    if (needs.isEmpty()) return start
    fun score(x: Int): Double {
        val lx = luminance(x)
        return needs.minOf { ratio(lx, it.lum) / it.ratio }
    }
    var best = start
    var bestScore = score(start)
    if (bestScore >= 1.0) return start
    val o = oklch(start)
    val sides = if (lighter) intArrayOf(1, -1) else intArrayOf(-1, 1)
    val steps = (1.0 / LIGHTNESS_STEP).toInt() + 1
    for (k in 1..steps) {
        var any = false
        for (side in sides) {
            val l = o.l + side * k * LIGHTNESS_STEP
            if (l < 0.0 || l > 1.0) continue
            any = true
            val x = rgbOf(Oklch(l, o.c, o.h))
            val s = score(x)
            if (s >= 1.0) return x
            if (s > bestScore) {
                best = x
                bestScore = s
            }
        }
        if (!any) break
    }
    return best
}

/**
 * Returns the color at [t] on the line from [base] to [toward], with the
 * luminance of [base]. The result takes the hue of [toward], but each
 * color keeps its contrast against it, as against [base].
 */
fun tint(base: Int, toward: Int, t: Double): Int {
    val o = oklch(mix(base, toward, t))
    val target = luminance(base)
    var lo = 0.0
    var hi = 1.0
    repeat(30) {
        val mid = (lo + hi) / 2
        if (luminance(rgbOf(Oklch(mid, o.c, o.h))) < target) lo = mid else hi = mid
    }
    val a = rgbOf(Oklch(lo, o.c, o.h))
    val b = rgbOf(Oklch(hi, o.c, o.h))
    return if (abs(luminance(a) - target) < abs(luminance(b) - target)) a else b
}

/** Reduces the chroma of a color to [max] at most. The lightness and the hue stay. */
fun limitChroma(rgb: Int, max: Double): Int {
    val o = oklch(rgb)
    return if (o.c <= max) opaque(rgb) else rgbOf(o.copy(c = max))
}

/**
 * Returns a color between [from] and [to] whose contrast against [from] is
 * [target]. When [to] is not far enough from [from], it returns [to].
 */
fun stepTo(from: Int, to: Int, target: Double): Int {
    if (contrast(from, to) <= target) return opaque(to)
    var lo = 0.0
    var hi = 1.0
    repeat(30) {
        val mid = (lo + hi) / 2
        if (contrast(from, mix(from, to, mid)) < target) lo = mid else hi = mid
    }
    return mix(from, to, hi)
}
