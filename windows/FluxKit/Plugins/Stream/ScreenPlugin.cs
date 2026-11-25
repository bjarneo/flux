namespace FluxKit;

// One display of this computer. Id is the ID of the system, such as the
// device name of the monitor. Width and Height are the size in pixels.
public sealed record DisplayInfo(string Id, string Name, int Width, int Height);

// The displays of this computer. The WPF app implements it with
// Windows.Graphics.Capture, and tests use a fake. FluxKit calls the members
// on the UI thread and on threads of the pool. A timer reads PixelSize each
// second while a mirror runs.
public interface IScreenSource
{
    // The displays that Flux can mirror, the main display first.
    IReadOnlyList<DisplayInfo> Displays();

    // The current size of a display in pixels, or null when it is gone.
    (int Width, int Height)? PixelSize(string displayId);

    // False when Windows does not let Flux record the screen.
    bool HasAccess { get; }

    // Finds the display for the capture. Each frame goes to frames.Frame,
    // with the rotation 0, and a stop after the start goes to frames.Failed.
    // It throws StreamException with a message for the user when the display
    // is gone or Flux cannot record the screen.
    Task<IScreenCapture> PrepareAsync(string displayId, IFrameSink frames);
}

// The capture of 1 display. Dispose stops it, and does not block.
public interface IScreenCapture : IDisposable
{
    // Starts the capture at width x height pixels and 30 frames per second,
    // with the cursor. The frames have this size: the app scales the image
    // of the display to it. Windows sends no frame while the screen does not
    // change. The encoder then repeats the last frame.
    Task StartAsync(int width, int height);

    // Changes the frame size of the running capture.
    Task ResizeAsync(int width, int height);
}

// The UI state of the screen mirror.
public sealed class ScreenModel : Model
{
    StreamStatus status = StreamStatus.None;
    ValueList<DisplayInfo> displays = ValueList<DisplayInfo>.Empty;
    string? display;
    bool hasAccess = true;

    // The phase of the mirror, its computer, and its message or error.
    public StreamStatus Status
    {
        get => status;
        internal set => Set(ref status, value);
    }

    public ValueList<DisplayInfo> Displays
    {
        get => displays;
        internal set => Set(ref displays, value);
    }

    // The ID of the display to mirror. ScreenPlugin.Select changes it.
    public string? Display
    {
        get => display;
        internal set => Set(ref display, value);
    }

    // False when Windows does not let Flux record the screen.
    public bool HasAccess
    {
        get => hasAccess;
        internal set => Set(ref hasAccess, value);
    }
}

// flux.screen: a display of this computer in a window on the computer, with
// the protocol of the Android app. This computer listens, announces the
// port and the frame size with "start", and writes H.264 to the computer
// that connects. A change of the display resolution gives a new encoder on
// the same stream, and the computer reads the new size from the next key
// frame. ScreenPlugin.swift of the Mac app has the same rules.
public sealed class ScreenPlugin : IFluxPlugin
{
    internal const string DisplayKey = "screen.display";

    // The time between 2 checks of the display size.
    internal static readonly TimeSpan WatchInterval = TimeSpan.FromSeconds(1);

    readonly IScreenSource? screens;
    readonly IVideoEncoderFactory? encoders;
    FluxCore? core;

    sealed class Session(string deviceId, string display)
    {
        public string DeviceId { get; } = deviceId;
        public string Display { get; } = display;
        public PayloadServer? Server { get; set; }
        public VideoSink? Sink { get; set; }
        public IScreenCapture? Capture { get; set; }
        public H264Encoder? Encoder { get; set; }
        public Timer? Watch { get; set; }
    }

    // Guards the fields below. Each start and each end moves attempt
    // forward, so that the work of an old mirror does nothing.
    readonly Lock gate = new();
    Session? session;
    int attempt;
    StreamStatus status = StreamStatus.None;
    string? display;

    // The app gives the screen capture and the encoder. Without both, this
    // computer does not list flux.screen and starts no mirror.
    public ScreenPlugin(IScreenSource? screens = null, IVideoEncoderFactory? encoders = null)
    {
        this.screens = screens;
        this.encoders = encoders;
        Supported = screens is not null && encoders is not null;
        Incoming = Supported ? [PacketType.Screen] : [];
        Outgoing = Supported ? [PacketType.Screen] : [];
    }

    public ScreenModel Model { get; } = new();

    // True when the app gave the screen capture and the encoder.
    public bool Supported { get; }

    public IReadOnlyList<string> Incoming { get; }
    public IReadOnlyList<string> Outgoing { get; }
    public IReadOnlyList<string> HandledTypes { get; } = [PacketType.Screen];

    // The payload ports of the listener. Tests use their own ports.
    internal (int First, int Last) PayloadPorts { get; set; } = (PayloadServer.FirstPort, PayloadServer.LastPort);

    // How long this computer waits for the computer to connect.
    internal TimeSpan ConnectTimeout { get; set; } = TimeSpan.FromSeconds(10);

    // The state of the mirror now, on any thread.
    internal StreamStatus CurrentStatus
    {
        get
        {
            lock (gate)
            {
                return status;
            }
        }
    }

    // The encoder of the mirror, or null. Tests read it.
    internal H264Encoder? Encoder
    {
        get
        {
            lock (gate)
            {
                return session?.Encoder;
            }
        }
    }

    public void Attach(FluxCore core)
    {
        this.core = core;
        lock (gate)
        {
            display = core.Settings.String(DisplayKey);
        }
    }

    // Actions

    // Reads the displays and the permission again. Call it on the UI thread.
    public void Refresh()
    {
        if (screens is null)
        {
            return;
        }
        IReadOnlyList<DisplayInfo> list;
        try
        {
            list = screens.Displays();
            Model.HasAccess = screens.HasAccess;
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            FluxLog.Info("stream", $"cannot list the displays: {e.Message}");
            list = [];
        }
        Model.Displays = ValueList.From(list);
        string? chosen;
        lock (gate)
        {
            chosen = display;
        }
        Model.Display = list.FirstOrDefault(d => d.Id == chosen)?.Id ?? list.FirstOrDefault()?.Id;
    }

    // Picks the display to mirror. It applies to the next mirror. Call it on
    // the UI thread.
    public void Select(string displayId)
    {
        lock (gate)
        {
            display = displayId;
        }
        core?.Settings.Set(DisplayKey, displayId);
        Model.Display = displayId;
    }

    // Mirrors the chosen display to the computer. A running mirror stops first.
    public void Start(string deviceId)
    {
        if (core is not { } c || screens is null)
        {
            return;
        }
        Stop(notify: true, StreamStatus.None);
        var target = Target();
        int id;
        lock (gate)
        {
            attempt++;
            session = new Session(deviceId, target ?? "");
            id = attempt;
        }
        var name = c.WithDevice(deviceId, d => d.Name) ?? "the computer";
        SetStatus(new StreamStatus(StreamPhase.Connecting, $"Waiting for {name}…", deviceId));
        _ = Task.Run(() => RunAsync(c, deviceId, name, target, id));
    }

    // Stops the mirror and tells the computer.
    public void Stop() => Stop(notify: true, new StreamStatus(StreamPhase.Idle, "Stopped on this computer", CurrentStatus.DeviceId));

    // The chosen display when it is connected, else the main display.
    string? Target()
    {
        string? chosen;
        lock (gate)
        {
            chosen = display;
        }
        try
        {
            if (chosen is not null && screens!.PixelSize(chosen) is not null)
            {
                return chosen;
            }
            return screens!.Displays().FirstOrDefault()?.Id;
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            FluxLog.Info("stream", $"cannot list the displays: {e.Message}");
            return null;
        }
    }

    // Packets

    public void Handle(Packet packet, Device device)
    {
        if (ScreenReply.Parse(packet) is not { } reply)
        {
            return;
        }
        int id;
        lock (gate)
        {
            if (session?.DeviceId != device.Id)
            {
                return;
            }
            id = attempt;
        }
        var name = device.Name;
        var deviceId = device.Id;
        switch (reply)
        {
            case ScreenReply.Live:
                bool isLive;
                lock (gate)
                {
                    isLive = attempt == id && status.Active;
                    if (isLive)
                    {
                        status = new StreamStatus(StreamPhase.Live, $"Mirrors to {name}", deviceId);
                    }
                }
                if (isLive)
                {
                    PublishStatus();
                }
                break;
            case ScreenReply.Failed failed:
                _ = Task.Run(() => End(notify: false, new StreamStatus(StreamPhase.Error, failed.Message, deviceId), id));
                break;
            case ScreenReply.Stop:
                _ = Task.Run(() => End(notify: false, new StreamStatus(StreamPhase.Idle, $"Stopped on {name}", deviceId), id));
                break;
        }
    }

    public void OnDisconnected(Device device)
    {
        int id;
        lock (gate)
        {
            if (session?.DeviceId != device.Id)
            {
                return;
            }
            id = attempt;
        }
        var closed = new StreamStatus(StreamPhase.Error, "The connection to the computer closed", device.Id);
        _ = Task.Run(() => End(notify: false, closed, id));
    }

    // Session

    async Task RunAsync(FluxCore core, string deviceId, string name, string? target, int id)
    {
        IScreenCapture? prepared = null;
        try
        {
            var certificate = StreamPeer.Certificate(core, deviceId, name, PacketType.Screen, $"Update Flux on {name} to mirror this screen");
            if (target is null || screens!.PixelSize(target) is not { } pixels || MirrorSize.Fit(pixels.Width, pixels.Height) is not { } size)
            {
                throw new StreamException("The display is not connected");
            }
            var frames = new Frames(this, deviceId, id);
            try
            {
                prepared = await screens.PrepareAsync(target, frames).ConfigureAwait(false);
            }
            finally
            {
                PublishAccess();
            }
            var server = PayloadServer.Open(core.Tls, certificate, PayloadPorts.First, PayloadPorts.Last);
            if (!Change(id, s => s.Server = server))
            {
                server.Dispose();
                return;
            }
            if (!core.Send(ScreenPackets.Start(server.Port, size.Width, size.Height), deviceId))
            {
                throw new StreamException($"Not connected to {name}");
            }
            var stream = await StreamPeer.AcceptAsync(server, ConnectTimeout, name).ConfigureAwait(false);
            var sink = new VideoSink(stream, MirrorSize.Bitrate(size.Width, size.Height));
            if (!Change(id, s =>
                {
                    s.Server = null;
                    s.Sink = sink;
                }))
            {
                sink.Close();
                return;
            }
            try
            {
                var encoder = NewEncoder(size.Width, size.Height, sink, deviceId, id);
                var capture = prepared;
                if (!Change(id, s =>
                    {
                        s.Capture = capture;
                        s.Encoder = encoder;
                    }))
                {
                    encoder.Dispose();
                    return;
                }
                // The session owns the capture now.
                prepared = null;
                await capture.StartAsync(size.Width, size.Height).ConfigureAwait(false);
                Watch(target, sink, deviceId, id);
            }
            catch (Exception e) when (StreamErrors.Expected(e) && e is not OperationCanceledException)
            {
                throw new StreamException($"The screen capture failed: {StreamErrors.Message(e, "it stopped")}", e);
            }
            try
            {
                await sink.RunAsync().ConfigureAwait(false);
            }
            catch (Exception e) when (StreamErrors.Expected(e))
            {
                End(notify: false, new StreamStatus(StreamPhase.Error, "The connection to the computer closed", deviceId), id);
            }
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            if (!Current(id))
            {
                return;
            }
            var message = StreamErrors.Message(e, "The screen mirror stopped");
            FluxLog.Info("stream", $"mirror did not start: {message}");
            End(notify: true, new StreamStatus(StreamPhase.Error, message, deviceId), id);
        }
        finally
        {
            prepared?.Dispose();
        }
    }

    H264Encoder NewEncoder(int width, int height, VideoSink sink, string deviceId, int id) =>
        new(encoders!, width, height, MirrorSize.Bitrate(width, height), () => sink.Backlogged, sink.Push,
            message => End(notify: true, new StreamStatus(StreamPhase.Error, message, deviceId), id));

    // Takes 1 frame of the capture. A frame goes to the encoder only when it
    // has the size of the encoder and the network keeps up.
    void Frame(IVideoFrame frame)
    {
        H264Encoder? encoder;
        VideoSink? sink;
        lock (gate)
        {
            encoder = session?.Encoder;
            sink = session?.Sink;
        }
        if (encoder is null || sink is null || sink.Backlogged || frame.Width != encoder.Width || frame.Height != encoder.Height)
        {
            return;
        }
        encoder.Encode(frame);
    }

    // Checks the display size every second. A new size gives a new encoder
    // on the same stream: the old encoder writes its last frames before the
    // new one starts with a key frame, so that the stream stays valid.
    void Watch(string target, VideoSink sink, string deviceId, int id)
    {
        var busy = 0;
        var timer = new Timer(_ =>
        {
            // A check that takes longer than the interval does not overlap
            // the next check.
            if (Interlocked.Exchange(ref busy, 1) == 1)
            {
                return;
            }
            try
            {
                Resize(target, sink, deviceId, id);
            }
            finally
            {
                Volatile.Write(ref busy, 0);
            }
        }, null, Timeout.Infinite, Timeout.Infinite);
        if (!Change(id, s => s.Watch = timer))
        {
            timer.Dispose();
            return;
        }
        timer.Change(WatchInterval, WatchInterval);
    }

    void Resize(string target, VideoSink sink, string deviceId, int id)
    {
        (int Width, int Height)? next;
        try
        {
            next = screens!.PixelSize(target) is { } pixels ? MirrorSize.Fit(pixels.Width, pixels.Height) : null;
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            FluxLog.Info("stream", $"cannot read the display size: {e.Message}");
            return;
        }
        H264Encoder? current;
        IScreenCapture? capture;
        lock (gate)
        {
            current = attempt == id ? session?.Encoder : null;
            capture = attempt == id ? session?.Capture : null;
        }
        if (next is not { } size || current is null || capture is null || (current.Width == size.Width && current.Height == size.Height))
        {
            return;
        }
        var failed = new StreamStatus(StreamPhase.Error, "The screen mirror stopped after the display changed", deviceId);
        try
        {
            var encoder = NewEncoder(size.Width, size.Height, sink, deviceId, id);
            if (!Change(id, s => s.Encoder = encoder))
            {
                encoder.Dispose();
                return;
            }
            current.Dispose();
            _ = Task.Run(async () =>
            {
                try
                {
                    await capture.ResizeAsync(size.Width, size.Height).ConfigureAwait(false);
                }
                catch (Exception e) when (StreamErrors.Expected(e))
                {
                    End(notify: true, failed, id);
                }
            });
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            End(notify: true, failed, id);
        }
    }

    // Stops the current attempt.
    void Stop(bool notify, StreamStatus next)
    {
        int id;
        lock (gate)
        {
            id = attempt;
        }
        End(notify, next, id);
    }

    // Ends attempt id once. With notify, the computer gets "stop" when it
    // knew about the mirror.
    void End(bool notify, StreamStatus next, int id)
    {
        Session? ended;
        lock (gate)
        {
            if (attempt != id)
            {
                return;
            }
            attempt++;
            ended = session;
            session = null;
        }
        if (ended is { } s)
        {
            s.Watch?.Dispose();
            try
            {
                s.Capture?.Dispose();
            }
            catch (Exception e) when (StreamErrors.Expected(e))
            {
                FluxLog.Info("stream", $"the screen capture did not stop cleanly: {e.Message}");
            }
            s.Encoder?.Dispose();
            s.Server?.Dispose();
            s.Sink?.Close();
            if (notify && (s.Server is not null || s.Sink is not null))
            {
                core?.Send(ScreenPackets.Stop(), s.DeviceId);
            }
        }
        SetStatus(next);
    }

    bool Current(int id)
    {
        lock (gate)
        {
            return attempt == id;
        }
    }

    // Changes the session of attempt id. It returns false when a later
    // attempt replaced it.
    bool Change(int id, Action<Session> body)
    {
        lock (gate)
        {
            if (attempt != id || session is not { } s)
            {
                return false;
            }
            body(s);
            return true;
        }
    }

    // UI

    void SetStatus(StreamStatus next)
    {
        lock (gate)
        {
            status = next;
        }
        PublishStatus();
    }

    void PublishStatus() => core?.Host.Post(() => Model.Status = CurrentStatus);

    void PublishAccess()
    {
        if (screens is not { } s)
        {
            return;
        }
        core?.Host.Post(() =>
        {
            try
            {
                Model.HasAccess = s.HasAccess;
            }
            catch (Exception e) when (StreamErrors.Expected(e))
            {
                FluxLog.Info("stream", $"cannot read the screen permission: {e.Message}");
            }
        });
    }

    // The frame sink of the screen capture of attempt id.
    sealed class Frames(ScreenPlugin plugin, string deviceId, int id) : IFrameSink
    {
        public void Frame(IVideoFrame frame, int rotation) => plugin.Frame(frame);

        public void Failed(string message) =>
            _ = Task.Run(() => plugin.End(notify: true, new StreamStatus(StreamPhase.Error, message, deviceId), id));
    }
}
