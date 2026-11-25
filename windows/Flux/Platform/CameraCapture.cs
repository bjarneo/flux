using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using FluxKit;
using Windows.Devices.Enumeration;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;

namespace Flux;

// The cameras of this computer with MediaCapture of Windows. A frame reader
// gives each frame in BGRA, and Windows decodes and converts the format of
// the camera. A device watcher reports the cameras that come and go.
// CameraSource.swift of the Mac app does the same work with AVFoundation.
public sealed class WindowsCameras : ICameraSource
{
    readonly Lock gate = new();
    IReadOnlyList<CameraDevice>? known;
    DeviceWatcher? watcher;
    bool enumerated;

    public event Action? DevicesChanged;

    public IReadOnlyList<CameraDevice> Devices()
    {
        lock (gate)
        {
            if (known is { } list)
            {
                return list;
            }
        }
        var found = Find();
        lock (gate)
        {
            known ??= found;
            Watch();
            return known;
        }
    }

    // The privacy settings of Windows let all desktop apps use the camera, or none.
    public bool AccessDenied => Privacy.Denied(Privacy.Camera);

    public async Task<IDisposable> OpenAsync(CameraDevice device, int shortSide, IFrameSink frames)
    {
        var session = new CameraSession(device, frames);
        try
        {
            await session.StartAsync(shortSide).ConfigureAwait(false);
        }
        catch (Exception e) when (e is COMException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or StreamException)
        {
            session.Dispose();
            throw CameraSession.UserError(device, e);
        }
        return session;
    }

    // The enabled video capture devices. The search completes on a thread of
    // the pool, so a wait on the UI thread does not block it.
    static IReadOnlyList<CameraDevice> Find()
    {
        var found = Task.Run(async () => await DeviceInformation.FindAllAsync(DeviceClass.VideoCapture)).GetAwaiter().GetResult();
        // A camera in the case of the computer has a panel, such as the front.
        return found.Where(d => d.IsEnabled)
            .Select(d => new CameraDevice(d.Id, d.Name, d.EnclosureLocation is { } place && place.Panel != Panel.Unknown))
            .ToArray();
    }

    // Starts the watcher once. The gate is held.
    void Watch()
    {
        if (watcher is not null)
        {
            return;
        }
        try
        {
            var w = DeviceInformation.CreateWatcher(DeviceClass.VideoCapture);
            w.Added += (_, _) => Changed();
            w.Removed += (_, _) => Changed();
            w.Updated += (_, _) => Changed();
            w.EnumerationCompleted += (_, _) =>
            {
                lock (gate)
                {
                    enumerated = true;
                }
            };
            w.Start();
            watcher = w;
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            FluxLog.Info("stream", $"cannot watch the cameras: {e.Message}");
        }
    }

    // Reads the cameras again after a change. The first events of the watcher
    // list the cameras that Flux knows already.
    void Changed()
    {
        lock (gate)
        {
            if (!enumerated)
            {
                return;
            }
        }
        _ = Task.Run(() =>
        {
            try
            {
                var found = Find();
                lock (gate)
                {
                    if (known is { } old && old.SequenceEqual(found))
                    {
                        return;
                    }
                    known = found;
                }
                DevicesChanged?.Invoke();
            }
            catch (Exception e) when (e is COMException or InvalidOperationException)
            {
                FluxLog.Info("stream", $"cannot list the cameras: {e.Message}");
            }
        });
    }
}

// 1 open camera: MediaCapture, the color source in the format for the
// stream, and a frame reader in BGRA. Each frame goes to the sink on a
// thread of the reader, 1 frame at a time. A frame that comes while the last
// frame is busy drops.
sealed class CameraSession(CameraDevice device, IFrameSink frames) : IDisposable
{
    readonly FrameRing ring = new(3);
    MediaCapture? capture;
    MediaFrameReader? reader;
    int busy;
    volatile bool stopped;

    // The camera with the ID is used by another app, or is gone.
    const int InUse = unchecked((int)0xC00D3704);
    const int Preempted = unchecked((int)0xC00D3EA3);
    const int Invalidated = unchecked((int)0xC00D3EA2);
    const int NoDevices = unchecked((int)0xC00DABE0);

    public static StreamException UserError(CameraDevice device, Exception e) => e switch
    {
        StreamException s => s,
        UnauthorizedAccessException => new StreamException(WebcamPlugin.CameraAccessText, e),
        COMException { HResult: InUse or Preempted } => new StreamException($"Another app uses {device.Name}", e),
        COMException { HResult: Invalidated or NoDevices } => new StreamException($"{device.Name} is not connected", e),
        _ => new StreamException($"{device.Name} did not start: {e.Message}", e),
    };

    public async Task StartAsync(int shortSide)
    {
        var c = new MediaCapture();
        capture = c;
        c.Failed += (_, e) =>
        {
            if (!stopped)
            {
                frames.Failed($"{device.Name} stopped: {e.Message}");
            }
        };
        var exclusive = true;
        try
        {
            await c.InitializeAsync(Settings(MediaCaptureSharingMode.ExclusiveControl));
        }
        catch (COMException e) when (e.HResult is InUse or Preempted)
        {
            // Another app holds the camera. Flux can still read it in the
            // format that the other app chose.
            exclusive = false;
            c.Dispose();
            c = new MediaCapture();
            capture = c;
            await c.InitializeAsync(Settings(MediaCaptureSharingMode.SharedReadOnly));
        }
        var source = c.FrameSources.Values
            .Where(s => s.Info.SourceKind == MediaFrameSourceKind.Color)
            .OrderBy(s => s.Info.MediaStreamType == MediaStreamType.VideoRecord ? 0 : s.Info.MediaStreamType == MediaStreamType.VideoPreview ? 1 : 2)
            .FirstOrDefault() ?? throw new StreamException($"{device.Name} gives no color video");
        if (exclusive && Pick(source.SupportedFormats, shortSide) is { } format)
        {
            await source.SetFormatAsync(format);
            FluxLog.Info("stream", $"camera format {format.VideoFormat.Width}x{format.VideoFormat.Height} {format.Subtype}");
        }
        var r = await c.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8);
        reader = r;
        r.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;
        r.FrameArrived += Arrived;
        var status = await r.StartAsync();
        if (status != MediaFrameReaderStartStatus.Success)
        {
            throw new StreamException(status == MediaFrameReaderStartStatus.ExclusiveControlNotAvailable
                ? $"Another app uses {device.Name}"
                : $"{device.Name} did not start");
        }
    }

    MediaCaptureInitializationSettings Settings(MediaCaptureSharingMode sharing) => new()
    {
        VideoDeviceId = device.DeviceId,
        StreamingCaptureMode = StreamingCaptureMode.Video,
        MemoryPreference = MediaCaptureMemoryPreference.Cpu,
        SharingMode = sharing,
    };

    // The smallest format that covers shortSide pixels on its short side at
    // 30 frames per second, or else the largest format. A raw format wins
    // over a compressed format of the same size, because it needs no decoder.
    internal static MediaFrameFormat? Pick(IReadOnlyList<MediaFrameFormat> formats, int shortSide)
    {
        static double Fps(MediaFrameFormat f) => f.FrameRate is { Denominator: > 0 } r ? (double)r.Numerator / r.Denominator : 0;
        static long Area(MediaFrameFormat f) => (long)f.VideoFormat.Width * f.VideoFormat.Height;
        static int Cost(MediaFrameFormat f) => f.Subtype.ToUpperInvariant() switch
        {
            "NV12" or "YUY2" => 0,
            "MJPG" => 1,
            _ => 2,
        };
        var usable = formats.Where(f => f.VideoFormat is { Width: > 0, Height: > 0 }).ToArray();
        var fast = usable.Where(f => Fps(f) >= 29.5).ToArray();
        return fast.Where(f => Math.Min(f.VideoFormat.Width, f.VideoFormat.Height) >= shortSide)
                   .OrderBy(Area).ThenBy(Cost).ThenByDescending(Fps).FirstOrDefault()
               ?? fast.OrderByDescending(Area).ThenBy(Cost).FirstOrDefault()
               ?? usable.OrderByDescending(Area).ThenByDescending(Fps).FirstOrDefault();
    }

    void Arrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        if (stopped || Interlocked.Exchange(ref busy, 1) == 1)
        {
            return;
        }
        try
        {
            using var reference = sender.TryAcquireLatestFrame();
            using var bitmap = reference?.VideoMediaFrame?.SoftwareBitmap;
            if (bitmap is null)
            {
                return;
            }
            using var converted = bitmap.BitmapPixelFormat == BitmapPixelFormat.Bgra8 ? null : SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8);
            var image = converted ?? bitmap;
            var frame = ring.Next(image.PixelWidth, image.PixelHeight);
            try
            {
                image.CopyToBuffer(frame.Pixels.AsBuffer());
            }
            finally
            {
                frame.EndWrite();
            }
            frames.Frame(frame, 0);
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or ObjectDisposedException or ArgumentException)
        {
            // The frame drops. The next frame tries again.
            FluxLog.Debug("stream", $"a camera frame did not read: {e.Message}");
        }
        finally
        {
            Volatile.Write(ref busy, 0);
        }
    }

    // Stops the camera in the background.
    public void Dispose()
    {
        stopped = true;
        var r = reader;
        var c = capture;
        reader = null;
        capture = null;
        _ = Task.Run(async () =>
        {
            try
            {
                if (r is not null)
                {
                    r.FrameArrived -= Arrived;
                    await r.StopAsync();
                    r.Dispose();
                }
                c?.Dispose();
            }
            catch (Exception e) when (e is COMException or InvalidOperationException or ObjectDisposedException)
            {
                FluxLog.Info("stream", $"the camera did not stop cleanly: {e.Message}");
            }
        });
    }
}
