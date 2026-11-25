package org.omarchy.flux.speaker

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build

/** The most audio that waits in the track, in milliseconds. It is the longest delay that the phone adds. */
internal const val SPEAKER_QUEUE_MS = 100

/** The audio that the track needs before it starts to play, in milliseconds, on Android 12 and later. */
internal const val SPEAKER_START_MS = 40

/** The capacity of the track, in milliseconds. The track uses only [SPEAKER_QUEUE_MS] of it. */
internal const val SPEAKER_CAPACITY_MS = 250

/** The frames of [ms] milliseconds of audio. 1 frame holds 1 sample of each channel. */
internal fun speakerFrames(ms: Int): Int = SpeakerPackets.RATE * ms / 1000

/**
 * Plays the PCM of the computer with a short queue. The track holds at
 * most [SPEAKER_QUEUE_MS] of audio. A write that does not fit drops the
 * rest of its frame, so a burst after a stall of the network adds no
 * lasting delay. After a stall, the track plays silence until audio comes
 * again.
 */
internal class SpeakerPlayer {
    val attributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()

    private val track: AudioTrack

    /** The bytes that did not fit in the queue. */
    var dropped = 0L
        private set

    init {
        val min = AudioTrack.getMinBufferSize(SpeakerPackets.RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        track = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(
                AudioFormat.Builder().setSampleRate(SpeakerPackets.RATE).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build(),
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(maxOf(min, speakerFrames(SPEAKER_CAPACITY_MS) * FRAME_SIZE))
            .build()
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            error("This phone cannot play 48 kHz stereo audio")
        }
        // The track can refuse a size under its minimum, and then takes the minimum.
        track.setBufferSizeInFrames(speakerFrames(SPEAKER_QUEUE_MS))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { track.setStartThresholdInFrames(minOf(speakerFrames(SPEAKER_START_MS), track.bufferSizeInFrames)) }
        }
        track.play()
    }

    /** Queues the first [length] bytes of [data]. The bytes that do not fit go. */
    fun write(data: ByteArray, length: Int) {
        if (length <= 0 || length % FRAME_SIZE != 0) return
        val n = track.write(data, 0, length, AudioTrack.WRITE_NON_BLOCKING)
        if (n in 0 until length) dropped += length - n
        if (n < 0) error("The audio output failed (error $n)")
    }

    /** Sets the volume of the stream, from 0 to 1. Android ducks it by itself for a short sound of another app. */
    fun setVolume(volume: Float) {
        track.setVolume(volume.coerceIn(0f, 1f))
    }

    fun close() {
        runCatching { track.pause() }
        runCatching { track.flush() }
        track.release()
    }

    private companion object {
        /** The bytes of 1 frame: 2 channels of 16 bits. */
        const val FRAME_SIZE = 4
    }
}
