using System.Diagnostics;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using FluxKit;
using Windows.Media.Ocr;

namespace Flux;

// What a camera mode needs from the camera now: nothing, the preview, or the
// preview with a live search for codes, text, or a page.
public enum CameraUse
{
    Off,
    Preview,
    Codes,
    Text,
    Document,
}

// The camera of 1 camera window: the access, the camera list, the running
// camera, the live preview, the outlines that the live search finds, and the
// stills. It reads the frames of WindowsCameras, the cameras of the webcam
// stream. CameraController.swift and StillCamera.swift of the Mac app have
// the same jobs. The public members run on the UI thread.
public sealed class CameraFeed : Model, IFrameSink, IDisposable
{
    // The camera that the camera modes use. The webcam keeps its own choice.
    internal const string CameraKey = "camera.modesDevice";

    // The short side of the camera format.
    const int ShortSide = 1080;

    // The largest side of the preview and of the frames of the live search.
    const int LiveSide = 1280;

    // The time of the last search before the first search. It is far enough
    // in the past for each interval, and a subtraction from it does not overflow.
    static readonly TimeSpan Never = TimeSpan.FromHours(-1);

    readonly ICameraSource source;
    readonly FluxSettings settings;
    readonly Dispatcher ui;
    readonly Stopwatch clock = Stopwatch.StartNew();

    // UI thread.
    IReadOnlyList<CameraInfo> cameras = [];
    CameraInfo? current;
    bool listed;
    bool running;
    string? error;
    bool denied;
    ValueList<ValueList<ScanPoint>> outlines = ValueList<ValueList<ScanPoint>>.Empty;
    int frameWidth;
    int frameHeight;
    WriteableBitmap? preview;
    CameraUse use = CameraUse.Off;
    bool visible = true;
    bool disposed;
    IDisposable? session;
    string? sessionId;
    bool opening;

    // Guards the fields that the camera thread reads.
    readonly Lock gate = new();
    CameraUse target = CameraUse.Off;
    bool previewBusy;
    bool analyzing;
    TimeSpan lastSearch = Never;
    TaskCompletionSource<BgraImage>? still;
    byte[] previewPixels = [];
    int previewWidth;
    int previewHeight;
    OcrEngine? engine;

    public CameraFeed(ICameraSource source, FluxSettings settings)
    {
        this.source = source;
        this.settings = settings;
        ui = Dispatcher.CurrentDispatcher;
        source.DevicesChanged += DevicesChanged;
        denied = source.AccessDenied;
    }

    // Receives the codes with a value in a live frame, and the frame, on the UI thread.
    public event Action<IReadOnlyList<FoundCode>, BgraImage>? CodesFound;

    // The cameras of this computer, built-in cameras first.
    public IReadOnlyList<CameraInfo> Cameras
    {
        get => cameras;
        private set
        {
            cameras = value;
            Changed();
        }
    }

    // True after the first list of the cameras.
    public bool Listed
    {
        get => listed;
        private set => Set(ref listed, value);
    }

    // The camera that runs or ran last.
    public CameraInfo? Current
    {
        get => current;
        private set => Set(ref current, value);
    }

    public bool Running
    {
        get => running;
        private set => Set(ref running, value);
    }

    // Why the camera does not start, or null.
    public string? Error
    {
        get => error;
        private set => Set(ref error, value);
    }

    // True when the privacy settings of Windows do not let Flux use the camera.
    public bool Denied
    {
        get => denied;
        private set => Set(ref denied, value);
    }

    // The outlines of the codes, text, or page that the live search sees,
    // in normalized frame coordinates with the origin at the top left corner.
    public ValueList<ValueList<ScanPoint>> Outlines
    {
        get => outlines;
        private set => Set(ref outlines, value);
    }

    // The size of the frames, in pixels.
    public int FrameWidth => frameWidth;
    public int FrameHeight => frameHeight;

    // The live preview. The camera writes each frame into the same bitmap.
    public ImageSource? Preview
    {
        get => preview;
        private set
        {
            preview = value as WriteableBitmap;
            Changed();
        }
    }

    // The camera that the user picked, or null for the first camera.
    public string? SelectedId => current?.Device.DeviceId ?? settings.String(CameraKey);

    // Lists the cameras and reads the access. The window calls it when it opens.
    public void Start()
    {
        RefreshAccess();
        _ = ListAsync();
    }

    async Task ListAsync()
    {
        IReadOnlyList<CameraDevice> devices;
        try
        {
            devices = await Task.Run(source.Devices);
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            FluxLog.Info("camera", $"cannot list the cameras: {e.Message}");
            devices = [];
        }
        if (disposed)
        {
            return;
        }
        Cameras = CameraNames.Name(devices);
        // A camera that is gone falls back to the first camera.
        if (current is { } c && !cameras.Any(x => x.Device.DeviceId == c.Device.DeviceId))
        {
            Current = null;
        }
        Listed = true;
        _ = ReconcileAsync();
    }

    void DevicesChanged() => ui.BeginInvoke(() =>
    {
        if (!disposed)
        {
            _ = ListAsync();
        }
    });

    public void Select(string deviceId)
    {
        settings.Set(CameraKey, deviceId);
        Current = cameras.FirstOrDefault(c => c.Device.DeviceId == deviceId);
        _ = ReconcileAsync();
    }

    // Starts, changes, or stops the camera for what the mode needs.
    public void Set(CameraUse value)
    {
        if (value == use)
        {
            return;
        }
        use = value;
        lock (gate)
        {
            target = value;
            lastSearch = Never;
        }
        Outlines = ValueList<ValueList<ScanPoint>>.Empty;
        _ = ReconcileAsync();
    }

    // Stops the camera while the window is minimized, and starts it again
    // for the same use when the window shows.
    public void SetVisible(bool value)
    {
        if (value == visible)
        {
            return;
        }
        visible = value;
        Outlines = ValueList<ValueList<ScanPoint>>.Empty;
        _ = ReconcileAsync();
    }

    // Starts the camera again after an error, with a new list of the cameras.
    public void Retry()
    {
        Error = null;
        _ = ListAsync();
    }

    // Reads the access again, for example after the user returns from the settings of Windows.
    public void RefreshAccess()
    {
        var now = source.AccessDenied;
        if (now == denied)
        {
            return;
        }
        Denied = now;
        _ = ReconcileAsync();
    }

    // The camera that the use wants now, or null.
    CameraInfo? Wanted()
    {
        if (use == CameraUse.Off || !visible || denied || disposed)
        {
            return null;
        }
        var id = settings.String(CameraKey);
        return cameras.FirstOrDefault(c => c.Device.DeviceId == id) ?? cameras.FirstOrDefault();
    }

    // Brings the camera to the wanted state. Only 1 run at a time opens a
    // camera, and it opens again when the wish changed during the open.
    async Task ReconcileAsync()
    {
        if (opening)
        {
            return;
        }
        opening = true;
        try
        {
            while (true)
            {
                var want = Wanted();
                if (want?.Device.DeviceId == sessionId)
                {
                    break;
                }
                // A mode asks for a still and then stops the camera. The
                // camera stops after the still.
                Task? pending;
                lock (gate)
                {
                    pending = session is null ? null : still?.Task;
                }
                if (pending is not null)
                {
                    await Task.WhenAny(pending);
                    continue;
                }
                CloseSession();
                if (want is null)
                {
                    break;
                }
                try
                {
                    var opened = await source.OpenAsync(want.Device, ShortSide, this);
                    if (disposed)
                    {
                        opened.Dispose();
                        break;
                    }
                    session = opened;
                    sessionId = want.Device.DeviceId;
                    Current = want;
                    Error = null;
                }
                catch (StreamException e)
                {
                    Error = e.Message;
                    break;
                }
            }
        }
        finally
        {
            opening = false;
            Running = session is not null;
        }
    }

    void CloseSession()
    {
        if (session is not { } s)
        {
            return;
        }
        session = null;
        sessionId = null;
        s.Dispose();
        lock (gate)
        {
            still?.TrySetException(new CameraException("The camera stopped"));
            still = null;
        }
        Running = false;
    }

    // Returns the next frame of the camera as a still image.
    public async Task<BgraImage> CaptureAsync()
    {
        if (!Running)
        {
            throw new CameraException("The camera is not running");
        }
        var wait = new TaskCompletionSource<BgraImage>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate)
        {
            still?.TrySetCanceled();
            still = wait;
        }
        if (await Task.WhenAny(wait.Task, Task.Delay(TimeSpan.FromSeconds(3))) != wait.Task)
        {
            lock (gate)
            {
                if (still == wait)
                {
                    still = null;
                }
            }
            // A stop of the camera can wait for this still.
            wait.TrySetCanceled();
            throw new CameraException("The camera gave no picture");
        }
        try
        {
            return await wait.Task;
        }
        catch (OperationCanceledException)
        {
            // A newer still took the place of this one.
            throw new CameraException("The camera gave no picture");
        }
    }

    // Frames

    // Takes 1 frame on the thread of the camera. The frame stays valid
    // during the call only.
    public void Frame(IVideoFrame frame, int rotation)
    {
        if (frame is not BgraFrame f || f.Width <= 0 || f.Height <= 0)
        {
            return;
        }
        TaskCompletionSource<BgraImage>? wait;
        CameraUse search;
        bool show;
        var now = clock.Elapsed;
        lock (gate)
        {
            wait = still;
            still = null;
            show = !previewBusy;
            previewBusy |= show;
            search = target;
            if ((search is CameraUse.Codes or CameraUse.Text or CameraUse.Document) && !analyzing && now - lastSearch >= Interval(search))
            {
                analyzing = true;
                lastSearch = now;
            }
            else
            {
                search = CameraUse.Off;
            }
        }
        wait?.TrySetResult(Copy(f, int.MaxValue));
        if (show)
        {
            ShowPreview(f);
        }
        if (search != CameraUse.Off)
        {
            var image = Copy(f, LiveSide);
            _ = Task.Run(() => SearchAsync(search, image));
        }
    }

    // The camera stopped after it started.
    public void Failed(string message) => ui.BeginInvoke(() =>
    {
        if (disposed)
        {
            return;
        }
        CloseSession();
        Error = message;
    });

    // Codes pause the camera as soon as they show, so they get more frames.
    static TimeSpan Interval(CameraUse use) => use switch
    {
        CameraUse.Codes => TimeSpan.FromSeconds(0.1),
        CameraUse.Text => TimeSpan.FromSeconds(0.4),
        _ => TimeSpan.FromSeconds(0.25),
    };

    // A copy of the frame with its largest side at most maxSide. The camera
    // gives opaque pixels, and the copy makes sure of it.
    static BgraImage Copy(BgraFrame f, int maxSide)
    {
        var (w, h) = CameraImages.Fit(f.Width, f.Height, maxSide);
        var pixels = new byte[w * h * 4];
        if (w == f.Width && h == f.Height)
        {
            Buffer.BlockCopy(f.Pixels, 0, pixels, 0, pixels.Length);
        }
        else
        {
            CameraImages.Scale(f.Pixels, f.Width, f.Height, pixels, w, h);
        }
        for (var i = 3; i < pixels.Length; i += 4)
        {
            pixels[i] = 255;
        }
        return new BgraImage(w, h, pixels);
    }

    // Scales the frame into the preview pixels on the thread of the camera,
    // then writes them into the bitmap on the UI thread.
    void ShowPreview(BgraFrame f)
    {
        var (w, h) = CameraImages.Fit(f.Width, f.Height, LiveSide);
        if (previewPixels.Length != w * h * 4)
        {
            previewPixels = new byte[w * h * 4];
        }
        CameraImages.Scale(f.Pixels, f.Width, f.Height, previewPixels, w, h);
        previewWidth = w;
        previewHeight = h;
        var fw = f.Width;
        var fh = f.Height;
        ui.BeginInvoke(DispatcherPriority.Render, () =>
        {
            try
            {
                if (disposed || session is null)
                {
                    return;
                }
                if (preview is null || preview.PixelWidth != previewWidth || preview.PixelHeight != previewHeight)
                {
                    Preview = new WriteableBitmap(previewWidth, previewHeight, 96, 96, PixelFormats.Bgr32, null);
                }
                preview!.WritePixels(new Int32Rect(0, 0, previewWidth, previewHeight), previewPixels, previewWidth * 4, 0);
                if (fw != frameWidth || fh != frameHeight)
                {
                    frameWidth = fw;
                    frameHeight = fh;
                    Changed(nameof(FrameWidth));
                }
            }
            finally
            {
                lock (gate)
                {
                    previewBusy = false;
                }
            }
        });
    }

    // Searches 1 frame off the UI thread and shows what it found.
    async Task SearchAsync(CameraUse search, BgraImage image)
    {
        try
        {
            IReadOnlyList<FoundCode> codes = [];
            var found = new List<ValueList<ScanPoint>>();
            switch (search)
            {
                case CameraUse.Codes:
                    codes = CodeReader.Read(image, live: true);
                    found.AddRange(codes.Select(c => c.Outline));
                    break;
                case CameraUse.Text:
                    engine ??= CameraOcr.Engine();
                    if (engine is not null)
                    {
                        foreach (var line in await CameraOcr.LinesAsync(image, engine))
                        {
                            found.Add(Box(line.Box, image.Width, image.Height));
                        }
                    }
                    break;
                case CameraUse.Document:
                    if (DocumentFinder.Find(image) is { } quad)
                    {
                        found.Add(ValueList.From(quad.Points));
                    }
                    break;
            }
            await ui.InvokeAsync(() =>
            {
                if (disposed || use != search)
                {
                    return;
                }
                Outlines = ValueList.From(found);
                if (codes.Count > 0)
                {
                    CodesFound?.Invoke(codes, image);
                }
            });
        }
        catch (CameraException e)
        {
            FluxLog.Debug("camera", $"a live search did not run: {e.Message}");
        }
        finally
        {
            lock (gate)
            {
                analyzing = false;
            }
        }
    }

    static ValueList<ScanPoint> Box(ScanBox b, int w, int h) => ValueList.From(new[]
    {
        new ScanPoint((double)b.Left / w, (double)b.Top / h), new ScanPoint((double)b.Right / w, (double)b.Top / h),
        new ScanPoint((double)b.Right / w, (double)b.Bottom / h), new ScanPoint((double)b.Left / w, (double)b.Bottom / h),
    });

    // Stops the camera for good when the window closes.
    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        source.DevicesChanged -= DevicesChanged;
        CodesFound = null;
        CloseSession();
    }
}
