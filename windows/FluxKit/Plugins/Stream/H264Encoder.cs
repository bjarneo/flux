using System.Diagnostics;

namespace FluxKit;

// The H.264 encoder of a stream: an encoder of the app with the rules of
// H264Encoder.swift of the Mac app. The first frame is an IDR frame, and so
// is the next frame after RequestKeyFrame. After 100 ms without a new frame
// it encodes the last frame again, so that a still scene keeps feeding the
// computer. It does not repeat while backlogged returns true, so that a slow
// network does not get more frames. The output goes through EncodedVideo, in
// Annex-B form with SPS and PPS in front of each IDR frame.
internal sealed class H264Encoder : IDisposable
{
    public static readonly TimeSpan RepeatAfter = TimeSpan.FromMilliseconds(100);

    readonly IVideoEncoder encoder;
    readonly Func<bool> backlogged;
    readonly Action<string> onError;
    readonly Timer timer;

    // Guards the frames that go to the encoder.
    readonly Lock gate = new();
    IVideoFrame? last;
    long lastSubmit = Stopwatch.GetTimestamp();
    bool forceKey = true;

    // Guards failed and released. An encoder can write its output inside
    // Encode, while gate is held, so the output path takes only this lock.
    readonly Lock stateGate = new();
    bool failed;
    bool released;

    public int Width { get; }
    public int Height { get; }

    // The number of frames that went to the encoder, also the repeats.
    public int Submitted { get; private set; }

    // Makes the encoder of the app. It throws what the factory throws.
    public H264Encoder(IVideoEncoderFactory factory, int width, int height, int bitrate, Func<bool> backlogged,
                       Action<byte[]> output, Action<string> onError)
    {
        Width = width;
        Height = height;
        this.backlogged = backlogged;
        this.onError = onError;
        // The output also takes the frames that Dispose writes, so that the
        // stream stays valid when a new encoder follows on the same stream.
        encoder = factory.Create(new VideoEncoderSettings(width, height, bitrate), new EncodedVideo(output, Fail));
        timer = new Timer(_ => RepeatLast(), null, RepeatAfter, RepeatAfter / 2);
    }

    bool Live
    {
        get
        {
            lock (stateGate)
            {
                return !released && !failed;
            }
        }
    }

    // Encodes 1 frame of Width x Height pixels.
    public void Encode(IVideoFrame frame)
    {
        lock (gate)
        {
            last = frame;
            Submit(frame);
        }
    }

    // Makes the next frame an IDR frame, for example after a camera switch.
    public void RequestKeyFrame()
    {
        lock (gate)
        {
            forceKey = true;
        }
    }

    // Writes the frames in flight and stops the encoder. The second call
    // does nothing.
    public void Dispose()
    {
        lock (stateGate)
        {
            if (released)
            {
                return;
            }
            released = true;
        }
        timer.Dispose();
        lock (gate)
        {
            last = null;
            try
            {
                encoder.Dispose();
            }
            catch (Exception e) when (StreamErrors.Expected(e))
            {
                FluxLog.Info("stream", $"the video encoder did not stop cleanly: {e.Message}");
            }
        }
    }

    void RepeatLast()
    {
        // A repeat adds no new image, so it waits while the network is behind.
        if (backlogged())
        {
            return;
        }
        lock (gate)
        {
            if (last is not { } frame || Stopwatch.GetElapsedTime(lastSubmit) < RepeatAfter)
            {
                return;
            }
            Submit(frame);
        }
    }

    // Gives 1 frame to the encoder of the app. The gate is held.
    void Submit(IVideoFrame frame)
    {
        if (!Live)
        {
            return;
        }
        lastSubmit = Stopwatch.GetTimestamp();
        var key = forceKey;
        forceKey = false;
        Submitted++;
        try
        {
            encoder.Encode(frame, key);
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            Fail($"The video encoder failed: {e.Message}");
        }
    }

    // Reports an error once. The report goes out on another thread, so that
    // its handler never runs inside the encoder or under the gate.
    void Fail(string message)
    {
        lock (stateGate)
        {
            if (failed || released)
            {
                return;
            }
            failed = true;
        }
        FluxLog.Error("stream", message);
        _ = Task.Run(() => onError(message));
    }
}
