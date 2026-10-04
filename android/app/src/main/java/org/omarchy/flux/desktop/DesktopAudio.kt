package org.omarchy.flux.desktop

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack

/** Plays bounded PCM frames without a wait on the video thread. */
internal class DesktopAudio {
    private val track = AudioTrack.Builder()
        .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
        .setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
        .setTransferMode(AudioTrack.MODE_STREAM)
        .setBufferSizeInBytes(maxOf(3840 * 4, AudioTrack.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)))
        .build()

    init { track.play() }
    fun feed(data: ByteArray, length: Int, volume: Float) {
        if (length !in 4..3840 || length % 4 != 0) return
        track.setVolume(volume.coerceIn(0f, 1f))
        track.write(data, 0, length, AudioTrack.WRITE_NON_BLOCKING)
    }
    fun close() { track.pause(); track.flush(); track.release() }
}
