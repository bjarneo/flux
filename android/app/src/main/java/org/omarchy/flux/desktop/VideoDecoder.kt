package org.omarchy.flux.desktop

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import androidx.annotation.RequiresApi
import java.nio.ByteBuffer

private const val TAG = "FluxDesktop"

/** The wait for a free input buffer, in microseconds. */
private const val INPUT_WAIT_US = 10_000L

/**
 * A hardware H.264 decoder that shows each frame on [surface] as soon as it
 * is decoded. [config] holds the SPS and the PPS. [onSize] gets the video
 * size when the decoder reads it from the stream.
 */
class VideoDecoder(
    surface: Surface,
    width: Int,
    height: Int,
    config: Pair<ByteArray, ByteArray>,
    private val onSize: (Int, Int) -> Unit,
) {
    private val codec: MediaCodec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    @Volatile private var running = true
    private val render: Thread
    private var frames = 0L

    init {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(config.first))
            setByteBuffer("csd-1", ByteBuffer.wrap(config.second))
            // Realtime priority, and no frames held back for smooth playback.
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && lowLatency()) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        try {
            codec.configure(format, surface, null, 0)
            codec.start()
        } catch (e: Exception) {
            codec.release()
            throw e
        }
        render = Thread(::renderLoop, "flux-desktop-render").apply { isDaemon = true }
        render.start()
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun lowLatency(): Boolean = runCatching {
        codec.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
            .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
    }.getOrDefault(false)

    /**
     * Queues 1 frame, the first [length] bytes of [data]. It waits while the
     * decoder has no free input buffer. It returns false after [release].
     */
    fun feed(data: ByteArray, length: Int, key: Boolean): Boolean {
        while (running) {
            val index = codec.dequeueInputBuffer(INPUT_WAIT_US)
            if (index < 0) continue
            val buffer = codec.getInputBuffer(index) ?: return false
            if (buffer.capacity() < length) {
                Log.w(TAG, "dropped a frame of $length bytes, the input buffer holds ${buffer.capacity()}")
                codec.queueInputBuffer(index, 0, 0, 0, 0)
                return true
            }
            buffer.clear()
            buffer.put(data, 0, length)
            // The time only orders the frames. Each frame shows when it is decoded.
            val time = frames++ * 33_333
            codec.queueInputBuffer(index, 0, length, time, if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            return true
        }
        return false
    }

    private fun renderLoop() {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val index = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> reportSize(codec.outputFormat)
                    index >= 0 -> codec.releaseOutputBuffer(index, true)
                }
            }
        } catch (e: Exception) {
            if (running) Log.i(TAG, "decoder stopped: ${e.message}")
        }
    }

    /** Reports the size of the picture, without the rows and columns that the crop removes. */
    private fun reportSize(f: MediaFormat) {
        fun int(key: String): Int? = if (f.containsKey(key)) f.getInteger(key) else null
        val left = int("crop-left")
        val right = int("crop-right")
        val top = int("crop-top")
        val bottom = int("crop-bottom")
        val w = if (left != null && right != null) right - left + 1 else int(MediaFormat.KEY_WIDTH) ?: return
        val h = if (top != null && bottom != null) bottom - top + 1 else int(MediaFormat.KEY_HEIGHT) ?: return
        if (w > 0 && h > 0) onSize(w, h)
    }

    /** Stops the decoder and its render thread. */
    fun release() {
        running = false
        if (Thread.currentThread() !== render) runCatching { render.join(500) }
        runCatching { codec.stop() }
        runCatching { codec.release() }
    }
}
