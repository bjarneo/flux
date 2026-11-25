namespace FluxKit;

// The audio output of the remote desktop. The Windows app implements it, for
// example with WASAPI. DesktopAudio calls it on the thread that reads the
// stream, so each call must return at once.
public interface IDesktopAudioOutput
{
    // Queues 1 frame of interleaved stereo samples at 48 kHz, from -1 to 1,
    // at the volume from 0 to 1. The output calls played after the frame
    // played, or when it drops the frame. It returns false when it cannot
    // play, for example without an audio device.
    bool Play(float[] samples, float volume, Action played);

    // Stops the sound and drops the queued frames.
    void Stop();
}

// Plays a bounded queue of stereo PCM frames of the remote desktop. Audio
// never delays the video: a full queue drops the frame. DesktopAudio.swift
// of the Mac app has the same rules.
public sealed class DesktopAudio(IDesktopAudioOutput? output)
{
    // The largest audio frame: 20 ms of stereo 16-bit samples at 48 kHz.
    public const int MaxFrameBytes = 3840;

    // The most frames that wait in the output.
    public const int MaxPending = 8;

    readonly Lock gate = new();
    int pending;
    // Each stop moves the generation forward, so that the callbacks of an
    // old stream do nothing.
    int generation;
    float volume = 1;
    // True after the output failed, until the next stop.
    bool failed;

    // Sets the volume from 0 to 1 for the next frames.
    public void SetVolume(float value)
    {
        if (!float.IsFinite(value))
        {
            return;
        }
        lock (gate)
        {
            volume = Math.Clamp(value, 0, 1);
        }
    }

    // The frames that wait in the output.
    internal int Pending
    {
        get
        {
            lock (gate)
            {
                return pending;
            }
        }
    }

    // Plays 1 frame of signed 16-bit little-endian stereo PCM. A frame of
    // another size, or a full queue, drops the frame.
    internal void Feed(byte[] bytes)
    {
        if (output is null || bytes.Length == 0 || bytes.Length > MaxFrameBytes || bytes.Length % 4 != 0)
        {
            return;
        }
        int token;
        float level;
        lock (gate)
        {
            if (failed || pending >= MaxPending)
            {
                return;
            }
            pending++;
            token = generation;
            level = volume;
        }
        if (!output.Play(Samples(bytes), level, () => Release(token)))
        {
            lock (gate)
            {
                if (token == generation && !failed)
                {
                    failed = true;
                    FluxLog.Error("desktop", "desktop audio failed: the audio output cannot play");
                }
            }
            Release(token);
        }
    }

    // Stops the sound. The next frame starts the output again.
    internal void Stop()
    {
        lock (gate)
        {
            generation++;
            pending = 0;
            failed = false;
        }
        output?.Stop();
    }

    void Release(int token)
    {
        lock (gate)
        {
            if (token == generation)
            {
                pending = Math.Max(0, pending - 1);
            }
        }
    }

    // The samples of signed 16-bit little-endian PCM, from -1 to 1.
    internal static float[] Samples(ReadOnlySpan<byte> pcm)
    {
        var samples = new float[pcm.Length / 2];
        for (var i = 0; i < samples.Length; i++)
        {
            samples[i] = (short)(pcm[i * 2] | pcm[i * 2 + 1] << 8) / 32768f;
        }
        return samples;
    }
}
