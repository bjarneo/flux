package org.omarchy.flux.core

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.IOException
import kotlin.math.roundToInt

/**
 * The longest side of an image that the phone pastes into a live terminal,
 * in pixels. A screenshot keeps legible text at this size, and the agents
 * scale a larger image down anyway.
 */
const val TERMINAL_IMAGE_SIDE = 2048

/** The largest image that the phone decodes for a paste, in pixels. A 200 MP photo fits. */
const val TERMINAL_IMAGE_MAX_SOURCE = 260_000_000L

/**
 * The size of a pasted image of [width] by [height] pixels. A larger image
 * gets smaller with the same aspect, so that its long side is [max].
 */
fun terminalImageSize(width: Int, height: Int, max: Int = TERMINAL_IMAGE_SIDE): Pair<Int, Int> {
    val long = maxOf(width, height)
    if (long <= max) return width to height
    val scale = max.toDouble() / long
    return maxOf(1, (width * scale).roundToInt()) to maxOf(1, (height * scale).roundToInt())
}

/**
 * Decodes the image at [uri] and encodes it as a PNG for a paste into a
 * live terminal. fluxd accepts only PNG, so it never decodes the pixels of
 * an image from a phone. ImageDecoder turns a photo upright from its EXIF
 * orientation and reads PNG, JPEG, GIF, WebP, and HEIF. A GIF gives its
 * first frame. The decoder scales a large image down while it reads it, so
 * a large photo does not fill the memory. It throws an IOException for an
 * image that it cannot read or that is too large.
 */
fun terminalPng(resolver: ContentResolver, uri: Uri): ByteArray {
    val source = ImageDecoder.createSource(resolver, uri)
    val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
        val w = info.size.width
        val h = info.size.height
        if (w <= 0 || h <= 0 || w.toLong() * h > TERMINAL_IMAGE_MAX_SOURCE) {
            throw IOException("the image has $w by $h pixels")
        }
        val (tw, th) = terminalImageSize(w, h)
        if (tw != w || th != h) decoder.setTargetSize(tw, th)
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
    }
    try {
        val out = ByteArrayOutputStream()
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) throw IOException("the PNG encoder failed")
        return out.toByteArray()
    } finally {
        bitmap.recycle()
    }
}
