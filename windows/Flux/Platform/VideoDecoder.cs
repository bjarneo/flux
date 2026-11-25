using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using FluxKit;

namespace Flux;

// A decoded picture in NV12: the Y plane with Stride bytes in each row and
// PlaneHeight rows, then the plane of the interleaved U and V samples. The
// picture to show is the rectangle Left, Top, Width, Height. Data belongs
// to the decoder and changes after the call that gives the picture.
public sealed record Nv12Picture(byte[] Data, int Stride, int PlaneHeight, int Left, int Top, int Width, int Height, bool Bt709, bool FullRange);

// Turns NV12 into 32-bit BGR for a WriteableBitmap.
public static class Nv12
{
    // Writes the picture into pixels with Width * 4 bytes in each row. The
    // rows go in parallel blocks of 16, so that a 4K frame takes a few
    // milliseconds.
    public static void ToBgr(Nv12Picture p, byte[] pixels)
    {
        // The factors times 256. Limited range puts black at 16 and white at 235.
        var (ky, black) = p.FullRange ? (256, 0) : (298, 16);
        var (rv, gu, gv, bu) = (p.Bt709, p.FullRange) switch
        {
            (true, false) => (459, 55, 136, 541),
            (true, true) => (403, 48, 120, 475),
            (false, true) => (359, 88, 183, 454),
            _ => (409, 100, 208, 516),
        };
        var data = p.Data;
        var uvStart = p.Stride * p.PlaneHeight;
        var blocks = (p.Height + 15) / 16;
        Parallel.For(0, blocks, block =>
        {
            var end = Math.Min(p.Height, block * 16 + 16);
            for (var row = block * 16; row < end; row++)
            {
                var ySource = (p.Top + row) * p.Stride + p.Left;
                var uvSource = uvStart + (p.Top + row) / 2 * p.Stride;
                var at = row * p.Width * 4;
                for (var x = 0; x < p.Width; x++)
                {
                    var y = (data[ySource + x] - black) * ky;
                    var uv = uvSource + ((p.Left + x) & ~1);
                    var u = data[uv] - 128;
                    var v = data[uv + 1] - 128;
                    pixels[at] = Clamp((y + bu * u + 128) >> 8);
                    pixels[at + 1] = Clamp((y - gu * u - gv * v + 128) >> 8);
                    pixels[at + 2] = Clamp((y + rv * v + 128) >> 8);
                    pixels[at + 3] = 255;
                    at += 4;
                }
            }
        });
    }

    static byte Clamp(int v) => (byte)(v < 0 ? 0 : v > 255 ? 255 : v);
}

// The H.264 decoder of Media Foundation: frames in Annex-B form in, NV12
// pictures out. Use it on 1 thread. Open throws NotSupportedException when
// Windows has no Media Foundation or no H.264 decoder, for example Windows
// Server without the Media Foundation feature.
public sealed class H264Decoder : IDisposable
{
    // The time of 1 frame at 60 frames each second, in units of 100 ns. The
    // decoder shows each frame at once, so the times only count up.
    const long FrameTime = 166_667;

    // The most turns of 1 pull, so that a decoder that keeps asking for a
    // new format cannot hold the thread.
    const int MaxTurns = 32;

    readonly IMFTransform transform;
    // The sample and the buffer that take the pictures, when the decoder
    // does not give its own samples.
    IntPtr outputSample;
    IMFMediaBuffer? outputBuffer;
    bool givesSamples;
    bool hasFormat;
    int stride;
    int planeHeight;
    int left;
    int top;
    int width;
    int height;
    bool bt709;
    bool fullRange;
    byte[] copy = [];
    long time;
    bool disposed;

    H264Decoder(IMFTransform transform) => this.transform = transform;

    // The size of the pictures, or 0 before the first picture.
    public int Width => hasFormat ? width : 0;
    public int Height => hasFormat ? height : 0;

    public static H264Decoder Open()
    {
        try
        {
            Marshal.ThrowExceptionForHR(MF.MFStartup(MF.Version, 0));
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException or COMException)
        {
            throw new NotSupportedException("Windows has no Media Foundation", e);
        }
        IMFTransform? transform = null;
        try
        {
            var type = Type.GetTypeFromCLSID(MF.H264DecoderClass, throwOnError: true)!;
            transform = (IMFTransform)Activator.CreateInstance(type)!;
            var decoder = new H264Decoder(transform);
            decoder.Setup();
            return decoder;
        }
        catch (Exception e) when (e is COMException or InvalidCastException or InvalidComObjectException or ArgumentException or NotImplementedException)
        {
            if (transform is not null)
            {
                Marshal.ReleaseComObject(transform);
            }
            _ = MF.MFShutdown();
            throw new NotSupportedException("Windows has no H.264 decoder", e);
        }
    }

    void Setup()
    {
        try
        {
            // The decoder gives each picture as soon as it can, and holds
            // no frames back for a reorder that the stream does not use.
            transform.GetAttributes(out var attributes);
            attributes.SetUINT32(MF.LowLatency, 1);
            Marshal.ReleaseComObject(attributes);
        }
        catch (COMException)
        {
            FluxLog.Info("desktop", "the H.264 decoder has no low latency mode");
        }
        Marshal.ThrowExceptionForHR(MF.MFCreateMediaType(out var input));
        try
        {
            input.SetGUID(MF.MajorType, MF.Video);
            input.SetGUID(MF.Subtype, MF.H264);
            input.SetUINT32(MF.InterlaceMode, MF.Progressive);
            transform.SetInputType(0, input, 0);
        }
        finally
        {
            Marshal.ReleaseComObject(input);
        }
        // The decoder knows the size only after the first SPS. Without an
        // output format now, the first pull asks for it.
        SetOutput();
        transform.ProcessMessage(MF.BeginStreaming, IntPtr.Zero);
        transform.ProcessMessage(MF.StartOfStream, IntPtr.Zero);
    }

    // Decodes 1 frame and gives each picture that comes out to show. A
    // decoder failure throws COMException.
    public void Decode(byte[] annexB, bool key, Action<Nv12Picture> show)
    {
        var sample = Input(annexB, key);
        try
        {
            var hr = transform.ProcessInput(0, sample, 0);
            if (hr == MF.NotAccepting)
            {
                // The decoder holds pictures. They go out first.
                Pull(show);
                hr = transform.ProcessInput(0, sample, 0);
            }
            Marshal.ThrowExceptionForHR(hr);
        }
        finally
        {
            Marshal.ReleaseComObject(sample);
        }
        Pull(show);
    }

    // Gives the pictures that the decoder still holds, at the end of a stream.
    public void Drain(Action<Nv12Picture> show)
    {
        transform.ProcessMessage(MF.CommandDrain, IntPtr.Zero);
        Pull(show);
    }

    // Drops the frames in the decoder. The next frame must be a key frame.
    public void Flush() => transform.ProcessMessage(MF.CommandFlush, IntPtr.Zero);

    IMFSample Input(byte[] data, bool key)
    {
        Marshal.ThrowExceptionForHR(MF.MFCreateMemoryBuffer(data.Length, out var buffer));
        try
        {
            buffer.Lock(out var at, out _, out _);
            try
            {
                Marshal.Copy(data, 0, at, data.Length);
            }
            finally
            {
                buffer.Unlock();
            }
            buffer.SetCurrentLength(data.Length);
            Marshal.ThrowExceptionForHR(MF.MFCreateSample(out var raw));
            var sample = (IMFSample)Marshal.GetObjectForIUnknown(raw);
            Marshal.Release(raw);
            sample.AddBuffer(buffer);
            sample.SetSampleTime(time);
            sample.SetSampleDuration(FrameTime);
            time += FrameTime;
            if (key)
            {
                sample.SetUINT32(MF.CleanPoint, 1);
            }
            return sample;
        }
        finally
        {
            Marshal.ReleaseComObject(buffer);
        }
    }

    // Takes the pictures out of the decoder until it needs more input.
    void Pull(Action<Nv12Picture> show)
    {
        for (var turn = 0; turn < MaxTurns; turn++)
        {
            var data = new OutputDataBuffer();
            var own = !givesSamples && outputSample != IntPtr.Zero;
            if (own)
            {
                outputBuffer?.SetCurrentLength(0);
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
            if (hr == MF.StreamChange || hr == MF.TypeNotSet)
            {
                // The SPS sets a new size. The pictures need a new format.
                if (!SetOutput())
                {
                    Marshal.ThrowExceptionForHR(hr);
                }
                continue;
            }
            if (hr < 0)
            {
                FluxLog.Error("desktop", $"the H.264 decoder failed with 0x{hr:X8}, own sample {own}, format {hasFormat}");
            }
            Marshal.ThrowExceptionForHR(hr);
            if (!own && data.Sample != IntPtr.Zero)
            {
                var given = (IMFSample)Marshal.GetObjectForIUnknown(data.Sample);
                Marshal.Release(data.Sample);
                try
                {
                    given.ConvertToContiguousBuffer(out var buffer);
                    try
                    {
                        Read(buffer, show);
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
            else if (own && hasFormat && outputBuffer is not null)
            {
                Read(outputBuffer, show);
            }
        }
    }

    void Read(IMFMediaBuffer buffer, Action<Nv12Picture> show)
    {
        buffer.Lock(out var at, out _, out var length);
        try
        {
            if (copy.Length < length)
            {
                copy = new byte[length];
            }
            Marshal.Copy(at, copy, 0, length);
        }
        finally
        {
            buffer.Unlock();
        }
        // A buffer that is shorter than the format holds fewer rows. An even
        // count keeps the last U and V row inside the buffer.
        var rows = stride > 0 ? Math.Min(planeHeight, length * 2 / 3 / stride) & ~1 : 0;
        if (width <= 0 || height <= 0 || rows < top + height || stride < left + width)
        {
            return;
        }
        show(new Nv12Picture(copy, stride, rows, left, top, width, height, bt709, fullRange));
    }

    // Selects NV12 for the pictures and reads the size of the format. It
    // returns false when the decoder offers no NV12 now.
    bool SetOutput()
    {
        for (var i = 0; ; i++)
        {
            if (transform.GetOutputAvailableType(0, i, out var type) < 0 || type is null)
            {
                return false;
            }
            try
            {
                if (type.GetGUID(MF.Subtype, out var subtype) < 0 || subtype != MF.Nv12)
                {
                    continue;
                }
                if (transform.SetOutputType(0, type, 0) < 0)
                {
                    return false;
                }
            }
            finally
            {
                Marshal.ReleaseComObject(type);
            }
            ReadFormat();
            return true;
        }
    }

    void ReadFormat()
    {
        transform.GetOutputCurrentType(0, out var type);
        try
        {
            if (type.GetUINT64(MF.FrameSize, out var size) < 0)
            {
                // The size comes with the first SPS. The decoder still needs
                // an output sample for the pull that reports it.
                hasFormat = false;
                Allocate(0);
                return;
            }
            var w = (int)(size >> 32);
            var h = (int)(size & 0xFFFFFFFF);
            stride = type.GetUINT32(MF.DefaultStride, out var s) >= 0 && s != 0 ? Math.Abs(s) : w;
            planeHeight = h;
            (left, top, width, height) = (0, 0, w, h);
            // The coded size is a multiple of 16, such as 1088 rows for a
            // 1080p stream. The aperture tells the rows that show.
            var area = new byte[16];
            if (type.GetBlob(MF.MinimumDisplayAperture, area, area.Length, out var n) >= 0 && n >= 16)
            {
                var x = BitConverter.ToInt16(area, 2);
                var y = BitConverter.ToInt16(area, 6);
                var cx = BitConverter.ToInt32(area, 8);
                var cy = BitConverter.ToInt32(area, 12);
                if (cx > 0 && cy > 0 && x >= 0 && y >= 0 && x + cx <= w && y + cy <= h)
                {
                    (left, top, width, height) = (x, y, cx, cy);
                }
            }
            // A stream without color tags comes from wf-recorder, which
            // uses the BT.601 matrix of FFmpeg in limited range.
            bt709 = type.GetUINT32(MF.YuvMatrix, out var matrix) >= 0 && matrix == MF.MatrixBt709;
            fullRange = type.GetUINT32(MF.NominalRange, out var range) >= 0 && range == MF.RangeFull;
        }
        finally
        {
            Marshal.ReleaseComObject(type);
        }
        Allocate(stride * planeHeight * 3 / 2);
        hasFormat = true;
        FluxLog.Info("desktop", $"remote desktop: the decoder gives {width}x{height} pictures");
    }

    // Makes the output sample when the decoder needs one from the caller,
    // with room for an NV12 picture of the bytes given, at least the size
    // that the decoder asks for. Before the size is known, the room holds a
    // 1080p picture.
    void Allocate(int bytes)
    {
        transform.GetOutputStreamInfo(0, out var info);
        givesSamples = (info.Flags & MF.ProvidesSamples) != 0;
        ReleaseOutput();
        if (givesSamples)
        {
            return;
        }
        var room = Math.Max(info.Size, bytes > 0 ? bytes : 1920 * 1088 * 3 / 2);
        Marshal.ThrowExceptionForHR(MF.MFCreateSample(out outputSample));
        var sample = (IMFSample)Marshal.GetObjectForIUnknown(outputSample);
        try
        {
            Marshal.ThrowExceptionForHR(MF.MFCreateMemoryBuffer(room, out var buffer));
            sample.AddBuffer(buffer);
            outputBuffer = buffer;
        }
        finally
        {
            Marshal.ReleaseComObject(sample);
        }
    }

    void ReleaseOutput()
    {
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
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        ReleaseOutput();
        Marshal.ReleaseComObject(transform);
        _ = MF.MFShutdown();
    }
}

// Shows the remote desktop: the H.264 decoder of Media Foundation on a
// thread of its own, and the pictures in a WriteableBitmap on the UI
// thread. DesktopVideo calls it on the thread that reads the stream, so
// each call only queues work and returns at once. A full queue makes
// IsReady false, and DesktopVideo then skips to the next key frame. Only
// the newest picture waits for the UI thread, so a slow UI thread drops
// pictures and does not fall behind.
public sealed class MediaFoundationVideo : IDesktopVideoOutput, IDisposable
{
    // The most frames that wait for the decoder.
    const int MaxQueue = 3;

    abstract record Work;

    sealed record DecodeWork(byte[] Data, bool Key) : Work;

    sealed record FlushWork : Work;

    readonly Dispatcher ui;
    readonly Action<BitmapSource?> show;
    readonly Action<string> failed;
    readonly Lock gate = new();
    readonly Queue<Work> queue = new();
    readonly AutoResetEvent wake = new(false);
    (byte[] Sps, byte[] Pps)? sets;
    bool unavailable;
    bool broken;
    bool disposed;
    // The newest picture for the UI thread, and a buffer to use again.
    byte[]? newest;
    int newestWidth;
    int newestHeight;
    byte[]? spare;
    bool posted;
    bool wipe;
    // Only the UI thread uses the bitmap.
    WriteableBitmap? bitmap;

    // show gets the bitmap on the UI thread when the size changes, and null
    // when the picture goes away. failed gets a message on the UI thread
    // when Windows cannot decode H.264.
    public MediaFoundationVideo(Dispatcher ui, Action<BitmapSource?> show, Action<string> failed)
    {
        this.ui = ui;
        this.show = show;
        this.failed = failed;
        new Thread(Run) { IsBackground = true, Name = "Flux video" }.Start();
    }

    public bool Configure(byte[] sps, byte[] pps)
    {
        lock (gate)
        {
            if (unavailable || disposed)
            {
                return false;
            }
            sets = (sps, pps);
            return true;
        }
    }

    public bool IsReady
    {
        get
        {
            lock (gate)
            {
                return !unavailable && !disposed && queue.Count < MaxQueue;
            }
        }
    }

    public bool NeedsFlush
    {
        get
        {
            lock (gate)
            {
                return broken;
            }
        }
    }

    public void Decode(byte[] annexB, bool key)
    {
        lock (gate)
        {
            if (unavailable || disposed || queue.Count >= MaxQueue)
            {
                return;
            }
            queue.Enqueue(new DecodeWork(annexB, key));
        }
        wake.Set();
    }

    public void Flush(bool clear)
    {
        lock (gate)
        {
            queue.Clear();
            broken = false;
            queue.Enqueue(new FlushWork());
            if (clear)
            {
                newest = null;
                wipe = true;
                Post();
            }
        }
        wake.Set();
    }

    public void Dispose()
    {
        lock (gate)
        {
            disposed = true;
            queue.Clear();
        }
        wake.Set();
    }

    void Run()
    {
        H264Decoder decoder;
        try
        {
            decoder = H264Decoder.Open();
        }
        catch (NotSupportedException e)
        {
            FluxLog.Error("desktop", $"remote desktop: {e.Message}: {e.InnerException?.Message}");
            lock (gate)
            {
                unavailable = true;
                queue.Clear();
            }
            ui.BeginInvoke(() => failed(e.Message));
            return;
        }
        using (decoder)
        {
            while (true)
            {
                wake.WaitOne();
                while (true)
                {
                    Work? work;
                    (byte[] Sps, byte[] Pps)? known;
                    lock (gate)
                    {
                        if (disposed)
                        {
                            return;
                        }
                        if (!queue.TryDequeue(out work))
                        {
                            break;
                        }
                        known = sets;
                    }
                    try
                    {
                        switch (work)
                        {
                            case FlushWork:
                                decoder.Flush();
                                break;
                            case DecodeWork d:
                                // The config frame carries the SPS and the
                                // PPS. A key frame without them gets them in
                                // front, so that the decoder can start there.
                                var data = d.Key && known is { } s && !HasSps(d.Data) ? Join(s.Sps, s.Pps, d.Data) : d.Data;
                                decoder.Decode(data, d.Key, Present);
                                break;
                        }
                    }
                    catch (Exception e) when (e is COMException or InvalidComObjectException or ArgumentException or NotImplementedException)
                    {
                        lock (gate)
                        {
                            if (!broken)
                            {
                                FluxLog.Info("desktop", $"remote desktop: the decoder failed: {e.Message}");
                            }
                            broken = true;
                        }
                    }
                }
            }
        }
    }

    // Converts a picture on the decoder thread and hands it to the UI thread.
    void Present(Nv12Picture p)
    {
        var size = p.Width * p.Height * 4;
        byte[] pixels;
        lock (gate)
        {
            pixels = spare is { } s && s.Length == size ? s : new byte[size];
            spare = null;
        }
        Nv12.ToBgr(p, pixels);
        lock (gate)
        {
            if (disposed)
            {
                return;
            }
            if (newest is { } old && old.Length == size)
            {
                spare = old;
            }
            newest = pixels;
            newestWidth = p.Width;
            newestHeight = p.Height;
            wipe = false;
            Post();
        }
    }

    // Asks the UI thread for 1 drawing. The gate is held.
    void Post()
    {
        if (posted)
        {
            return;
        }
        posted = true;
        ui.BeginInvoke(DispatcherPriority.Background, Draw);
    }

    void Draw()
    {
        byte[]? pixels;
        int w;
        int h;
        bool clear;
        lock (gate)
        {
            posted = false;
            pixels = newest;
            newest = null;
            w = newestWidth;
            h = newestHeight;
            clear = wipe;
            wipe = false;
            if (disposed)
            {
                return;
            }
        }
        if (pixels is null)
        {
            if (clear && bitmap is not null)
            {
                bitmap = null;
                show(null);
            }
            return;
        }
        if (bitmap is null || bitmap.PixelWidth != w || bitmap.PixelHeight != h)
        {
            bitmap = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgr32, null);
            show(bitmap);
        }
        bitmap.WritePixels(new Int32Rect(0, 0, w, h), pixels, w * 4, 0);
        lock (gate)
        {
            spare ??= pixels;
        }
    }

    // True when the frame has an SPS.
    internal static bool HasSps(byte[] data)
    {
        for (var i = 0; i + 3 < data.Length; i++)
        {
            if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 && (data[i + 3] & 0x1F) == 7)
            {
                return true;
            }
        }
        return false;
    }

    static byte[] Join(byte[] sps, byte[] pps, byte[] frame)
    {
        var output = new byte[8 + sps.Length + pps.Length + frame.Length];
        output[3] = 1;
        sps.CopyTo(output, 4);
        output[7 + sps.Length] = 1;
        pps.CopyTo(output, 8 + sps.Length);
        frame.CopyTo(output, 8 + sps.Length + pps.Length);
        return output;
    }
}
