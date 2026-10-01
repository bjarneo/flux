package org.omarchy.flux.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The album art of the media screen. A player on the computer reports a
 * web address for its art, and the phone loads it over https. The phone
 * keeps the last images in memory, so a return to the screen does not load
 * them again.
 */
internal object AlbumArt {
    private const val TAG = "FluxArt"

    /** The largest image file that the phone loads. */
    private const val MAX_BYTES = 4 * 1024 * 1024

    /** The largest side of the image in memory, in pixels. */
    private const val MAX_SIDE = 1024

    private const val TIMEOUT_MS = 8_000

    private val cache = LruCache<String, ImageBitmap>(4)

    fun cached(url: String): ImageBitmap? = cache.get(url)

    /** Loads the image at [url], or returns null when it cannot. It runs on the IO dispatcher. */
    suspend fun load(url: String): ImageBitmap? = withContext(Dispatchers.IO) {
        cache.get(url)?.let { return@withContext it }
        val image = runCatching { fetch(url) }
            .onFailure { Log.i(TAG, "album art not loaded: ${it.message}") }
            .getOrNull()
        image?.also { cache.put(url, it) }
    }

    private fun fetch(url: String): ImageBitmap? {
        val c = URL(url).openConnection() as? HttpsURLConnection ?: return null
        try {
            c.connectTimeout = TIMEOUT_MS
            c.readTimeout = TIMEOUT_MS
            c.useCaches = false
            c.setRequestProperty("Accept", "image/*")
            if (c.responseCode != HttpsURLConnection.HTTP_OK) return null
            val bytes = c.inputStream.use { readLimited(it) } ?: return null
            return decode(bytes)?.asImageBitmap()
        } finally {
            c.disconnect()
        }
    }

    /** Reads at most [MAX_BYTES], or returns null for a larger file. */
    private fun readLimited(input: InputStream): ByteArray? {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(16 * 1024)
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            if (out.size() + n > MAX_BYTES) return null
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    /** Decodes the image at a size of at most [MAX_SIDE] pixels on its longest side. */
    private fun decode(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_SIDE) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }
}

/** The album art at [url], or null while it loads, when it fails, and for an empty [url]. */
@Composable
internal fun rememberAlbumArt(url: String): State<ImageBitmap?> =
    produceState(if (url.isEmpty()) null else AlbumArt.cached(url), url) {
        value = if (url.isEmpty()) null else AlbumArt.load(url)
    }
