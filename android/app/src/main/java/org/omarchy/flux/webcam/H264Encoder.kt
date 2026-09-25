package org.omarchy.flux.webcam

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Surface
import java.io.OutputStream

private const val TAG = "FluxWebcam"

/**
 * A hardware H.264 encoder with a Surface input. A drain thread writes the
 * encoded stream in Annex-B form to [out]. When a write fails, for example
 * because the computer closed the connection, [onError] runs once.
 */
class H264Encoder(
    private val width: Int,
    private val height: Int,
    private val bitrate: Int,
    private val out: OutputStream,
    private val onError: (String) -> Unit,
) {
    private val codec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    val inputSurface: Surface
    @Volatile private var running = true
    private val framer = AnnexBFramer()
    private val drain: Thread

    init {
        try {
            val video = codec.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).videoCapabilities
            if (video != null && !video.isSizeSupported(width, height)) error("This phone cannot encode $width × $height video")
        } catch (e: Exception) {
            codec.release()
            throw e
        }
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, WebcamPackets.FPS)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileMain)
            setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel41)
            // Realtime priority, and a repeated frame after 100 ms of a still
            // scene, so the virtual camera on the computer keeps getting frames.
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000L)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        try {
            try {
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            } catch (e: Exception) {
                // Some encoders reject the profile or the level. Try the defaults.
                Log.i(TAG, "encoder rejected main profile, using defaults: ${e.message}")
                format.removeKey(MediaFormat.KEY_PROFILE)
                format.removeKey(MediaFormat.KEY_LEVEL)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) format.removeKey(MediaFormat.KEY_LOW_LATENCY)
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            }
            inputSurface = codec.createInputSurface()
            codec.start()
        } catch (e: Exception) {
            codec.release()
            throw e
        }
        drain = Thread(::drainLoop, "flux-webcam-encoder").apply { isDaemon = true }
        drain.start()
    }

    /** Asks for an IDR frame now, for example when the computer starts to read. */
    fun requestKeyFrame() {
        runCatching { codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }) }
    }

    private fun drainLoop() {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val index = codec.dequeueOutputBuffer(info, 10_000)
                if (index < 0) continue
                val buffer = codec.getOutputBuffer(index)
                if (buffer != null && info.size > 0) {
                    val data = ByteArray(info.size)
                    buffer.position(info.offset)
                    buffer.get(data, 0, info.size)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        framer.onConfig(data)
                    } else {
                        val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                        framer.onFrame(data, key)?.let { out.write(it) }
                    }
                }
                codec.releaseOutputBuffer(index, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        } catch (e: Exception) {
            if (running) {
                Log.i(TAG, "stream ended: ${e.message}")
                running = false
                onError("The connection to the computer closed")
            }
        }
    }

    /** Stops the encoder and the drain thread. It does not close [out]. */
    fun release() {
        running = false
        // The drain thread itself can end the stream. It must not wait for itself.
        if (Thread.currentThread() !== drain) runCatching { drain.join(500) }
        runCatching { codec.stop() }
        runCatching { codec.release() }
        runCatching { inputSurface.release() }
    }
}
