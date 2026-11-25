using System.Diagnostics;
using System.Runtime.InteropServices;
using FluxKit;

namespace Flux;

// Makes the H.264 encoders of the webcam and the screen mirror with the
// H.264 encoder of Media Foundation.
public sealed class MediaFoundationEncoders : IVideoEncoderFactory
{
    public IVideoEncoder Create(VideoEncoderSettings settings, EncodedVideo output) => MediaFoundationEncoder.Open(settings, output);
}

// The H.264 encoder of Media Foundation: BGRA frames in, Annex-B access
// units out. It uses the software encoder of Windows, which works in the
// order of the calls. The hardware encoders of the graphics drivers work
// asynchronously and want Direct3D surfaces, so Flux does not use them yet.
// The settings are the settings of the Android encoder: Main profile at
// level 4.1, a variable bitrate, 30 frames per second, a key frame each
// second, no B-frames, BT.709 colors in limited range, and low latency.
// FluxKit calls Encode from 1 thread at a time.
public sealed class MediaFoundationEncoder : IVideoEncoder
{
    // The most turns of 1 pull, so that an encoder that keeps asking for a
    // new format cannot hold the thread.
    const int MaxTurns = 32;

    readonly IMFTransform transform;
    readonly ICodecAPI? codec;
    readonly VideoEncoderSettings settings;
    readonly EncodedVideo output;
    readonly byte[] nv12;
    readonly long frameTime;
    readonly long started = Stopwatch.GetTimestamp();
    IntPtr outputSample;
    IMFMediaBuffer? outputBuffer;
    bool givesSamples;
    long lastTime = -1;
    // A key frame that did not go out, because the frame changed during
    // its conversion. The next frame takes it.
    bool keyPending;
    bool disposed;

    MediaFoundationEncoder(IMFTransform transform, VideoEncoderSettings settings, EncodedVideo output)
    {
        this.transform = transform;
        this.settings = settings;
        this.output = output;
        codec = transform as ICodecAPI;
        nv12 = new byte[settings.Width * settings.Height * 3 / 2];
        frameTime = 10_000_000L / Math.Max(1, settings.Fps);
    }

    // Makes an encoder. It throws StreamException when Windows has no Media
    // Foundation or no H.264 encoder, for example Windows Server without the
    // Media Foundation feature.
    public static MediaFoundationEncoder Open(VideoEncoderSettings settings, EncodedVideo output)
    {
        if (settings.Width <= 0 || settings.Height <= 0 || settings.Width % 2 != 0 || settings.Height % 2 != 0)
        {
            throw new StreamException($"The encoder cannot take {settings.Width}x{settings.Height} frames");
        }
        try
        {
            Marshal.ThrowExceptionForHR(MF.MFStartup(MF.Version, 0));
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException or COMException)
        {
            throw new StreamException("Windows has no Media Foundation", e);
        }
        IMFTransform? transform = null;
        try
        {
            var type = Type.GetTypeFromCLSID(MF.H264EncoderClass, throwOnError: true)!;
            transform = (IMFTransform)Activator.CreateInstance(type)!;
            var encoder = new MediaFoundationEncoder(transform, settings, output);
            encoder.Setup();
            return encoder;
        }
        catch (Exception e) when (e is COMException or InvalidCastException or InvalidComObjectException or ArgumentException or NotImplementedException
                                       or UnauthorizedAccessException or InvalidOperationException)
        {
            if (transform is not null)
            {
                Marshal.ReleaseComObject(transform);
            }
            _ = MF.MFShutdown();
            throw new StreamException("Windows has no H.264 encoder", e);
        }
    }

    void Setup()
    {
        // The software encoder reads its rate control before the formats.
        Set(CodecApi.RateControlMode, CodecApi.UInt32(CodecApi.UnconstrainedVbr));
        Set(CodecApi.MeanBitRate, CodecApi.UInt32((uint)settings.Bitrate));
        Set(CodecApi.GopSize, CodecApi.UInt32((uint)(settings.Fps * VideoEncoderSettings.KeyFrameInterval.TotalSeconds)));
        Set(CodecApi.BPictureCount, CodecApi.UInt32(0));
        Set(CodecApi.LowLatencyMode, CodecApi.Bool(true));
        try
        {
            transform.GetAttributes(out var attributes);
            attributes.SetUINT32(MF.LowLatency, 1);
            Marshal.ReleaseComObject(attributes);
        }
        catch (Exception e) when (e is COMException or NotImplementedException)
        {
            FluxLog.Info("stream", "the H.264 encoder has no low latency attribute");
        }
        // An encoder that rejects the colors, the profile, or the level uses
        // its defaults.
        if (SetOutput(profile: true, colors: true) < 0 && SetOutput(profile: true, colors: false) < 0)
        {
            FluxLog.Info("stream", "the H.264 encoder uses its default profile and level");
            Marshal.ThrowExceptionForHR(SetOutput(profile: false, colors: false));
        }
        try
        {
            SetInput(colors: true);
        }
        catch (COMException)
        {
            SetInput(colors: false);
        }
        ReadParameterSets();
        transform.GetOutputStreamInfo(0, out var info);
        givesSamples = (info.Flags & MF.ProvidesSamples) != 0;
        if (!givesSamples)
        {
            Marshal.ThrowExceptionForHR(MF.MFCreateSample(out outputSample));
            var sample = (IMFSample)Marshal.GetObjectForIUnknown(outputSample);
            try
            {
                Marshal.ThrowExceptionForHR(MF.MFCreateMemoryBuffer(Math.Max(info.Size, settings.Width * settings.Height * 2), out var buffer));
                sample.AddBuffer(buffer);
                outputBuffer = buffer;
            }
            finally
            {
                Marshal.ReleaseComObject(sample);
            }
        }
        transform.ProcessMessage(MF.BeginStreaming, IntPtr.Zero);
        transform.ProcessMessage(MF.StartOfStream, IntPtr.Zero);
        FluxLog.Info("stream", $"H.264 encoder: {settings.Width}x{settings.Height} at {settings.Bitrate / 1000} kbit/s");
    }

    void Set(Guid api, Variant value)
    {
        if (codec is null || codec.SetValue(api, value) < 0)
        {
            FluxLog.Debug("stream", $"the H.264 encoder did not take the setting {api}");
        }
    }

    // Sets the H.264 format of the output. It returns the result of the encoder.
    int SetOutput(bool profile, bool colors)
    {
        Marshal.ThrowExceptionForHR(MF.MFCreateMediaType(out var type));
        try
        {
            type.SetGUID(MF.MajorType, MF.Video);
            type.SetGUID(MF.Subtype, MF.H264);
            type.SetUINT32(MF.AvgBitrate, settings.Bitrate);
            Common(type, colors);
            if (profile)
            {
                type.SetUINT32(MF.Mpeg2Profile, MF.ProfileMain);
                type.SetUINT32(MF.Mpeg2Level, MF.Level41);
            }
            return transform.SetOutputType(0, type, 0);
        }
        finally
        {
            Marshal.ReleaseComObject(type);
        }
    }

    void SetInput(bool colors)
    {
        Marshal.ThrowExceptionForHR(MF.MFCreateMediaType(out var type));
        try
        {
            type.SetGUID(MF.MajorType, MF.Video);
            type.SetGUID(MF.Subtype, MF.Nv12);
            Common(type, colors);
            transform.SetInputType(0, type, 0);
        }
        finally
        {
            Marshal.ReleaseComObject(type);
        }
    }

    // The size, the rate, square pixels, progressive frames, and with colors
    // the BT.709 colors in limited range.
    void Common(IMFMediaType type, bool colors)
    {
        type.SetUINT64(MF.FrameSize, (long)settings.Width << 32 | (uint)settings.Height);
        type.SetUINT64(MF.FrameRate, (long)settings.Fps << 32 | 1);
        type.SetUINT64(MF.PixelAspectRatio, 1L << 32 | 1);
        type.SetUINT32(MF.InterlaceMode, MF.Progressive);
        if (colors)
        {
            type.SetUINT32(MF.YuvMatrix, MF.MatrixBt709);
            type.SetUINT32(MF.VideoPrimaries, MF.PrimariesBt709);
            type.SetUINT32(MF.TransferFunction, MF.TransferBt709);
            type.SetUINT32(MF.NominalRange, MF.RangeLimited);
        }
    }

    // Gives the SPS and the PPS of the output format to the stream, when the
    // encoder tells them before the first frame.
    void ReadParameterSets()
    {
        transform.GetOutputCurrentType(0, out var type);
        try
        {
            if (type.GetBlobSize(MF.SequenceHeader, out var size) < 0 || size <= 0)
            {
                return;
            }
            var header = new byte[size];
            if (type.GetBlob(MF.SequenceHeader, header, size, out var written) >= 0 && written > 0)
            {
                output.ParameterSets(header.AsSpan(0, written));
            }
        }
        finally
        {
            Marshal.ReleaseComObject(type);
        }
    }

    public void Encode(IVideoFrame frame, bool keyFrame)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (frame is not BgraFrame f)
        {
            throw new NotSupportedException("The H.264 encoder takes only BGRA frames");
        }
        if (f.Width != settings.Width || f.Height != settings.Height)
        {
            throw new StreamException($"The frame is {f.Width}x{f.Height}, and the encoder takes {settings.Width}x{settings.Height}");
        }
        var version = f.Version;
        if ((version & 1) != 0)
        {
            keyPending |= keyFrame;
            return;
        }
        Bgra.ToNv12(f.Pixels, f.Width, f.Height, nv12);
        if (f.Version != version)
        {
            // The producer wrote the frame during the conversion.
            keyPending |= keyFrame;
            return;
        }
        if (keyFrame || keyPending)
        {
            keyPending = false;
            Set(CodecApi.ForceKeyFrame, CodecApi.UInt32(1));
        }
        var sample = Input();
        try
        {
            var hr = transform.ProcessInput(0, sample, 0);
            if (hr == MF.NotAccepting)
            {
                // The encoder holds frames. They go out first.
                Pull();
                hr = transform.ProcessInput(0, sample, 0);
            }
            Marshal.ThrowExceptionForHR(hr);
        }
        finally
        {
            Marshal.ReleaseComObject(sample);
        }
        Pull();
    }

    // The NV12 picture in a new sample, with the time since the start. The
    // repeats of FluxKit come at other times than the camera frames, so the
    // times come from the clock, and they only count up.
    IMFSample Input()
    {
        Marshal.ThrowExceptionForHR(MF.MFCreateMemoryBuffer(nv12.Length, out var buffer));
        try
        {
            buffer.Lock(out var at, out _, out _);
            try
            {
                Marshal.Copy(nv12, 0, at, nv12.Length);
            }
            finally
            {
                buffer.Unlock();
            }
            buffer.SetCurrentLength(nv12.Length);
            Marshal.ThrowExceptionForHR(MF.MFCreateSample(out var raw));
            var sample = (IMFSample)Marshal.GetObjectForIUnknown(raw);
            Marshal.Release(raw);
            sample.AddBuffer(buffer);
            var time = Math.Max(lastTime + 1, Stopwatch.GetElapsedTime(started).Ticks);
            lastTime = time;
            sample.SetSampleTime(time);
            sample.SetSampleDuration(frameTime);
            return sample;
        }
        finally
        {
            Marshal.ReleaseComObject(buffer);
        }
    }

    // Takes the access units out of the encoder until it needs more input.
    void Pull()
    {
        for (var turn = 0; turn < MaxTurns; turn++)
        {
            var data = new OutputDataBuffer();
            var own = !givesSamples && outputBuffer is not null;
            if (own)
            {
                outputBuffer!.SetCurrentLength(0);
                data.Sample = outputSample;
            }
            var hr = transform.ProcessOutput(0, 1, ref data, out _);
            if (data.Events != IntPtr.Zero)
            {
                Marshal.Release(data.Events);
            }
            if (hr == MF.NeedMoreInput)
            {
                return;
            }
            if (hr == MF.StreamChange)
            {
                // The encoder asks to set its output format again.
                if (transform.GetOutputAvailableType(0, 0, out var type) < 0 || type is null)
                {
                    Marshal.ThrowExceptionForHR(hr);
                    return;
                }
                try
                {
                    Marshal.ThrowExceptionForHR(transform.SetOutputType(0, type, 0));
                }
                finally
                {
                    Marshal.ReleaseComObject(type);
                }
                ReadParameterSets();
                continue;
            }
            Marshal.ThrowExceptionForHR(hr);
            if (own)
            {
                Write(outputBuffer!);
            }
            else if (data.Sample != IntPtr.Zero)
            {
                var given = (IMFSample)Marshal.GetObjectForIUnknown(data.Sample);
                Marshal.Release(data.Sample);
                try
                {
                    given.ConvertToContiguousBuffer(out var buffer);
                    try
                    {
                        Write(buffer);
                    }
                    finally
                    {
                        Marshal.ReleaseComObject(buffer);
                    }
                }
                finally
                {
                    Marshal.ReleaseComObject(given);
                }
            }
        }
    }

    // Gives 1 access unit to the stream. The NAL types tell a key frame,
    // because the sample that Flux gives the encoder keeps the attributes of
    // the last frame.
    void Write(IMFMediaBuffer buffer)
    {
        byte[] bytes;
        buffer.Lock(out var at, out _, out var length);
        try
        {
            if (length <= 0)
            {
                return;
            }
            bytes = new byte[length];
            Marshal.Copy(at, bytes, 0, length);
        }
        finally
        {
            buffer.Unlock();
        }
        var types = AnnexB.NalTypes(bytes);
        // An encoder can give the SPS and the PPS without a frame. They then
        // go out in front of the next IDR frame.
        if (types.Contains(AnnexB.NalSps) && !types.Any(t => t is 1 or AnnexB.NalIdr))
        {
            output.ParameterSets(bytes);
            return;
        }
        output.AccessUnit(bytes, types.Contains(AnnexB.NalIdr));
    }

    // Writes the frames in flight to the stream and stops the encoder.
    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        try
        {
            transform.ProcessMessage(MF.EndOfStream, IntPtr.Zero);
            transform.ProcessMessage(MF.CommandDrain, IntPtr.Zero);
            Pull();
            transform.ProcessMessage(MF.EndStreaming, IntPtr.Zero);
        }
        catch (Exception e) when (e is COMException or InvalidComObjectException)
        {
            FluxLog.Info("stream", $"the H.264 encoder did not drain: {e.Message}");
        }
        if (outputBuffer is not null)
        {
            Marshal.ReleaseComObject(outputBuffer);
            outputBuffer = null;
        }
        if (outputSample != IntPtr.Zero)
        {
            Marshal.Release(outputSample);
            outputSample = IntPtr.Zero;
        }
        // The codec interface is the same object as the transform.
        Marshal.ReleaseComObject(transform);
        _ = MF.MFShutdown();
    }
}
