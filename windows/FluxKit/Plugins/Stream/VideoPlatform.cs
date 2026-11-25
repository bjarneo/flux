namespace FluxKit;

// One video frame of the camera, the renderer, or the screen capture.
// FluxKit does not read the pixels. It only routes the frame. The app gives
// its own type, such as a Media Foundation sample or a Direct3D texture.
//
// The encoder gets the last frame again after 100 ms without a new frame,
// see H264Encoder. A frame that goes to an encoder must stay valid until the
// next frame goes to that encoder, or until the encoder ends.
public interface IVideoFrame
{
    int Width { get; }
    int Height { get; }
}

// The settings of 1 H.264 encoder.
public sealed record VideoEncoderSettings(int Width, int Height, int Bitrate)
{
    public int Fps => WebcamPackets.Fps;

    // The longest time between 2 key frames.
    public static readonly TimeSpan KeyFrameInterval = TimeSpan.FromSeconds(1);
}

// Makes the H.264 encoders of the webcam and of the screen mirror. The WPF
// app implements it with a Media Foundation encoder, and tests use a fake.
public interface IVideoEncoderFactory
{
    // Makes an encoder with the settings of the Android encoder: Main profile
    // at level 4.1, variable bitrate, 30 frames per second, a key frame each
    // second, no frame reordering, BT.709 colors, and low latency. An encoder
    // that rejects the profile or the level uses its defaults. The encoder
    // writes its output to output, in the order of the frames, on any
    // thread. It throws StreamException, or an ExternalException of Media
    // Foundation, when it cannot make the encoder.
    IVideoEncoder Create(VideoEncoderSettings settings, EncodedVideo output);
}

// 1 H.264 encoder of the app. FluxKit calls Encode from 1 thread at a time.
// Dispose writes the frames in flight to the output and stops the encoder.
public interface IVideoEncoder : IDisposable
{
    // Encodes 1 frame of the size of the settings. With keyFrame, the frame
    // becomes an IDR frame. It can write the output before it returns. It
    // throws StreamException or an ExternalException when the encoder fails.
    void Encode(IVideoFrame frame, bool keyFrame);
}

// Where an encoder of the app writes its output. FluxKit makes it. It puts
// SPS and PPS in front of each IDR frame, drops the frames before the first
// IDR frame, and writes the stream to the computer.
public sealed class EncodedVideo
{
    readonly Lock gate = new();
    readonly AnnexBFramer framer = new();
    readonly Action<byte[]> output;
    readonly Action<string> failed;

    internal EncodedVideo(Action<byte[]> output, Action<string> failed)
    {
        this.output = output;
        this.failed = failed;
    }

    // Takes SPS and PPS, in Annex-B form or as 1 NAL unit without a start
    // code. With Media Foundation, they are MF_MT_MPEG_SEQUENCE_HEADER of the
    // output type. They go out in front of the next IDR frame that does not
    // have them.
    public void ParameterSets(ReadOnlySpan<byte> data)
    {
        lock (gate)
        {
            framer.OnConfig(data);
        }
    }

    // Takes 1 access unit in Annex-B form. keyFrame is true for an IDR frame.
    // A frame without a start code gets one.
    public void AccessUnit(ReadOnlySpan<byte> data, bool keyFrame)
    {
        byte[]? bytes;
        lock (gate)
        {
            bytes = framer.OnFrame(data, keyFrame);
        }
        if (bytes is not null)
        {
            output(bytes);
        }
    }

    // Takes 1 access unit in the MP4 form: each NAL unit has a big-endian
    // length of headerLength bytes in front. An access unit whose lengths do
    // not fit is dropped.
    public void LengthPrefixed(ReadOnlySpan<byte> data, int headerLength, bool keyFrame)
    {
        var bytes = data.ToArray();
        if (AnnexB.ConvertLengthPrefixed(ref bytes, headerLength))
        {
            AccessUnit(bytes, keyFrame);
        }
    }

    // Ends the stream with a message for the user, after the encoder failed.
    public void Fail(string message) => failed(message);
}

// Where a camera or a screen capture sends its frames. FluxKit makes it and
// gives it to the capture. The capture calls it on its own thread, 1 call
// at a time.
public interface IFrameSink
{
    // Takes 1 frame. rotation is the clockwise rotation in degrees that makes
    // the frame upright, a multiple of 90. A screen capture gives 0.
    void Frame(IVideoFrame frame, int rotation);

    // Reports that the capture stopped after it started, with a message for
    // the user.
    void Failed(string message);
}
