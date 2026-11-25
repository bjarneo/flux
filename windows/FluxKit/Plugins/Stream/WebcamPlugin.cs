using System.Text.Json.Nodes;

namespace FluxKit;

// The UI state of the webcam.
public sealed class WebcamModel : Model
{
    StreamStatus status = StreamStatus.None;
    WebcamConfig config = new();
    WebcamCaps caps = new();
    ValueList<CameraInfo> cameras = ValueList<CameraInfo>.Empty;
    string? cameraError;
    object? preview;
    bool sendsMicrophone;

    // The phase of the stream, its computer, and its message or error.
    public StreamStatus Status
    {
        get => status;
        internal set => Set(ref status, value);
    }

    // The settings. WebcamPlugin.Update changes them.
    public WebcamConfig Config
    {
        get => config;
        internal set => Set(ref config, value);
    }

    // What the camera and the encoder support. The UI limits its controls to it.
    public WebcamCaps Caps
    {
        get => caps;
        internal set => Set(ref caps, value);
    }

    // The cameras of this computer.
    public ValueList<CameraInfo> Cameras
    {
        get => cameras;
        internal set => Set(ref cameras, value);
    }

    // A problem with the camera itself, or null.
    public string? CameraError
    {
        get => cameraError;
        internal set => Set(ref cameraError, value);
    }

    // A small copy of the frames while the camera runs and a view shows the
    // preview: the result of IFrameRenderer.Preview, or null.
    public object? Preview
    {
        get => preview;
        internal set => Set(ref preview, value);
    }

    // "Also send the microphone": the microphone streams to the computer
    // while the webcam is live.
    public bool SendsMicrophone
    {
        get => sendsMicrophone;
        internal set => Set(ref sendsMicrophone, value);
    }
}

// flux.webcam: the camera of this computer as a virtual camera on the
// computer, with the protocol of the Android app. This computer listens,
// announces the port with "start", and writes H.264 to the computer that
// connects. 1 stream runs at a time. WebcamPlugin.swift of the Mac app has
// the same rules.
public sealed class WebcamPlugin : IFluxPlugin
{
    // The largest digital zoom.
    internal const double ZoomMax = 4;

    // The digital exposure range, in EV, and its step.
    internal const double ExposureLimit = 2;
    internal const double ExposureStep = 0.1;

    // The shortest time between 2 config messages to the computer, while a
    // slider moves.
    internal static readonly TimeSpan ConfigInterval = TimeSpan.FromMilliseconds(120);

    internal const string MicrophoneKey = "webcam.withMicrophone";

    // The error when the camera permission of Windows is off.
    public const string CameraAccessText = "Flux has no access to the camera. Allow Flux in Settings, Privacy & security, Camera.";

    // The error when no camera is available.
    public const string NoCameraText = "This computer has no usable camera";

    readonly ICameraSource? cameras;
    readonly IFrameRenderer? renderer;
    readonly IVideoEncoderFactory? encoders;
    FluxCore? core;
    WebcamSettings? settings;
    WebcamPipeline? pipeline;

    sealed class Session(string deviceId)
    {
        public string DeviceId { get; } = deviceId;
        public PayloadServer? Server { get; set; }
        public VideoSink? Sink { get; set; }

        // True after the computer got "start", so that it can take "config".
        public bool Announced { get; set; }
    }

    // Guards the fields below. Each start and each end moves attempt
    // forward, so that the work of an old stream does nothing.
    readonly Lock gate = new();
    Session? session;
    int attempt;
    StreamStatus status = StreamStatus.None;
    WebcamConfig applied = new();
    bool sendPending;

    // True while the webcam runs a microphone stream that it started. Only
    // the UI thread uses it.
    bool microphoneByWebcam;

    // The app gives the camera, the renderer, and the encoder. Without all 3,
    // this computer does not list flux.webcam and starts no webcam.
    public WebcamPlugin(ICameraSource? cameras = null, IFrameRenderer? renderer = null, IVideoEncoderFactory? encoders = null)
    {
        this.cameras = cameras;
        this.renderer = renderer;
        this.encoders = encoders;
        Supported = cameras is not null && renderer is not null && encoders is not null;
        Incoming = Supported ? [PacketType.Webcam] : [];
        Outgoing = Supported ? [PacketType.Webcam] : [];
    }

    public WebcamModel Model { get; } = new();

    // True when the app gave the camera, the renderer, and the encoder.
    public bool Supported { get; }

    public IReadOnlyList<string> Incoming { get; }
    public IReadOnlyList<string> Outgoing { get; }
    public IReadOnlyList<string> HandledTypes { get; } = [PacketType.Webcam];

    // The payload ports of the listener. Tests use their own ports.
    internal (int First, int Last) PayloadPorts { get; set; } = (PayloadServer.FirstPort, PayloadServer.LastPort);

    // How long this computer waits for the computer to connect.
    internal TimeSpan ConnectTimeout { get; set; } = TimeSpan.FromSeconds(10);

    // The state of the stream now, on any thread.
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

    // The pipeline of the camera. Tests use it.
    internal WebcamPipeline? Pipeline => pipeline;

    // True when the privacy settings of Windows do not let Flux use the camera.
    public bool CameraAccessDenied => cameras?.AccessDenied == true;

    public void Attach(FluxCore core)
    {
        this.core = core;
        if (cameras is null || renderer is null || encoders is null)
        {
            return;
        }
        var available = Available();
        settings = new WebcamSettings(core.Settings, Caps(available));
        applied = settings.Config;
        pipeline = new WebcamPipeline(cameras, renderer, OnPreview, message => Ui(m => m.CameraError = message));
        pipeline.Apply(applied);
        cameras.DevicesChanged += () => PublishCameras(Available());
        PublishCameras(available);
        PublishConfig();
        var sendsMicrophone = core.Settings.Bool(MicrophoneKey, false);
        Ui(m => m.SendsMicrophone = sendsMicrophone);
    }

    // The caps of this computer: the cameras, a digital zoom and exposure,
    // and automatic white balance only, as on the Mac.
    internal static WebcamCaps Caps(IReadOnlyList<CameraInfo> cameras) => new()
    {
        ZoomMax = ZoomMax,
        ExposureMin = -ExposureLimit,
        ExposureMax = ExposureLimit,
        ExposureStep = ExposureStep,
        Cameras = ValueList.From(cameras.Select(c => c.Id)),
    };

    // Texts

    // The error when the Flux of the computer has no webcam support.
    internal static string UpdateText(string computer) => $"Update Flux on {computer} to use this computer as a webcam";

    // Actions

    // Starts a stream to the computer. A running stream stops first.
    public void Start(string deviceId)
    {
        if (core is not { } c || BeginAttempt(deviceId) is not { } started)
        {
            return;
        }
        _ = Task.Run(() => RunAsync(c, deviceId, started.Name, started.Id));
    }

    // Opens a new attempt for deviceId and shows that Flux waits for the
    // computer. It returns the number of the attempt and the name of the
    // computer, or null without a core or a camera. Start then runs the
    // stream. Tests use it to hold a session without the stream task.
    internal (int Id, string Name)? BeginAttempt(string deviceId)
    {
        if (core is null || !Supported)
        {
            return null;
        }
        Stop(notify: true, StreamStatus.None);
        int id;
        lock (gate)
        {
            attempt++;
            session = new Session(deviceId);
            id = attempt;
        }
        var name = core.WithDevice(deviceId, d => d.Name) ?? "the computer";
        SetStatus(new StreamStatus(StreamPhase.Connecting, $"Waiting for {name}…", deviceId));
        Ui(m => m.CameraError = null);
        return (id, name);
    }

    // Stops the stream and tells the computer.
    public void Stop() => Stop(notify: true, StreamStatus.None);

    // Changes the settings. The image changes at once, a new camera switches
    // without a new stream, and a new frame size starts the stream again.
    // For example: webcam.Update(c => c with { Brightness = 0.2 }).
    public void Update(Func<WebcamConfig, WebcamConfig> change)
    {
        if (settings?.Update(change) is { } next)
        {
            Changed(next);
        }
    }

    // Sets the neutral image values. The shape, the quality, and the camera stay.
    public void Reset() => Update(c => c.Reset());

    // Turns "Also send the microphone" on or off. To turn it on, Flux needs
    // the microphone permission. It stays off when Windows denies it.
    public void SetSendsMicrophone(bool on)
    {
        if (!on)
        {
            ApplySendsMicrophone(false);
            return;
        }
        _ = Task.Run(async () =>
        {
            var mic = core?.Plugin<MicPlugin>();
            var granted = mic is not null && await mic.AuthorizeAsync().ConfigureAwait(false);
            if (!granted)
            {
                core?.Toast("Allow the microphone for Flux to send it with the webcam");
            }
            ApplySendsMicrophone(granted);
        });
    }

    void ApplySendsMicrophone(bool on)
    {
        core?.Settings.Set(MicrophoneKey, on);
        Ui(m =>
        {
            m.SendsMicrophone = on;
            SyncMicrophone();
        });
    }

    // Tells the webcam that a view shows the preview, or stopped to show it.
    // Without a view, the frames make no preview images.
    public void SetPreviewShown(bool shown) => pipeline?.SetPreviewShown(shown);

    // Packets

    // The core lock is held, so the work that stops the camera runs in a task.
    public void Handle(Packet packet, Device device)
    {
        if (WebcamReply.Parse(packet) is not { } reply)
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
            case WebcamReply.Live live:
                bool isLive;
                lock (gate)
                {
                    isLive = attempt == id && status.Active;
                    if (isLive)
                    {
                        status = new StreamStatus(StreamPhase.Live, $"Live on {name} as {live.Label}", deviceId);
                    }
                }
                if (isLive)
                {
                    PublishStatus();
                }
                break;
            case WebcamReply.Failed failed:
                _ = Task.Run(() => End(notify: false, new StreamStatus(StreamPhase.Error, failed.Message, deviceId), id));
                break;
            case WebcamReply.Stop:
                _ = Task.Run(() => End(notify: false, new StreamStatus(StreamPhase.Idle, $"Stopped on {name}", deviceId), id));
                break;
            case WebcamReply.Config config:
                // The body belongs to the packet, so the task gets a copy.
                var partial = config.Partial?.DeepClone() as JsonObject;
                var reset = config.Reset;
                _ = Task.Run(() =>
                {
                    if (settings?.ApplyRemote(reset, partial) is { } next)
                    {
                        Changed(next);
                    }
                });
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
        var closed = new StreamStatus(StreamPhase.Error, $"The connection to {device.Name} closed", device.Id);
        _ = Task.Run(() => End(notify: false, closed, id));
    }

    // Session

    async Task RunAsync(FluxCore core, string deviceId, string name, int id)
    {
        try
        {
            var certificate = StreamPeer.Certificate(core, deviceId, name, PacketType.Webcam, UpdateText(name));
            if (CameraAccessDenied)
            {
                throw new StreamException(CameraAccessText);
            }
            await OpenCameraAsync(id).ConfigureAwait(false);
            var config = settings!.Config;
            var server = PayloadServer.Open(core.Tls, certificate, PayloadPorts.First, PayloadPorts.Last);
            if (!Change(id, s => s.Server = server))
            {
                server.Dispose();
                return;
            }
            if (!core.Send(WebcamPackets.Start(server.Port, config.Width, config.Height), deviceId))
            {
                throw new StreamException($"Not connected to {name}");
            }
            Change(id, s => s.Announced = true);
            core.Send(WebcamPackets.Config(settings.Config, settings.Caps), deviceId);
            var stream = await StreamPeer.AcceptAsync(server, ConnectTimeout, name).ConfigureAwait(false);
            var sink = new VideoSink(stream, config.Bitrate);
            if (!Change(id, s =>
                {
                    s.Server = null;
                    s.Sink = sink;
                }))
            {
                sink.Close();
                return;
            }
            SetStatus(new StreamStatus(StreamPhase.Starting, $"Starting Flux Camera on {name}…", deviceId));
            try
            {
                pipeline!.StartEncoder(encoders!, config.Width, config.Height, config.Bitrate, sink, message =>
                    End(notify: true, new StreamStatus(StreamPhase.Error, message, deviceId), id));
            }
            catch (Exception e) when (StreamErrors.Expected(e))
            {
                throw new StreamException($"The video encoder did not start: {e.Message}", e);
            }
            try
            {
                await sink.RunAsync().ConfigureAwait(false);
            }
            catch (Exception e) when (StreamErrors.Expected(e))
            {
                End(notify: true, new StreamStatus(StreamPhase.Error, "The connection to the computer closed", deviceId), id);
            }
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            if (!Current(id))
            {
                return;
            }
            var message = StreamErrors.Message(e, "The webcam stopped");
            FluxLog.Info("stream", $"webcam start failed: {message}");
            End(notify: true, new StreamStatus(StreamPhase.Error, message, deviceId), id);
        }
    }

    // Opens the camera of the settings for attempt id, after the settings
    // took the cameras that this computer has now.
    async Task OpenCameraAsync(int id)
    {
        var available = Available();
        PublishCameras(available);
        if (available.Count == 0)
        {
            throw new StreamException(NoCameraText);
        }
        if (settings!.SetCaps(Caps(available)) is { } next)
        {
            Changed(next);
        }
        var config = settings.Config;
        var camera = available.FirstOrDefault(c => c.Id == config.Camera) ?? available[0];
        if (!Current(id))
        {
            return;
        }
        await pipeline!.OpenCameraAsync(camera, config.Resolution, id).ConfigureAwait(false);
        if (!Current(id))
        {
            pipeline.CloseCamera(id);
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
    // knew about the stream.
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
        pipeline?.StopEncoder();
        pipeline?.CloseCamera(id);
        ended?.Server?.Dispose();
        ended?.Sink?.Close();
        if (notify && ended is { } s && (s.Server is not null || s.Sink is not null))
        {
            core?.Send(WebcamPackets.Stop(), s.DeviceId);
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

    // Applies new settings to the camera, the image, and the stream. The
    // computer gets the full settings after each change.
    void Changed(WebcamConfig next)
    {
        PublishConfig();
        WebcamConfig old;
        string? announcedTo;
        lock (gate)
        {
            old = applied;
            applied = next;
            announcedTo = session is { Announced: true } s ? s.DeviceId : null;
        }
        pipeline?.Apply(next);
        if (old.Camera != next.Camera)
        {
            SwitchCamera(next);
        }
        if (old.RestartsStream(next) && announcedTo is not null)
        {
            // The new "start" carries the new size, and the config follows it.
            Start(announcedTo);
            return;
        }
        ScheduleConfig();
    }

    void SwitchCamera(WebcamConfig config)
    {
        if (pipeline is not { IsCameraOpen: true } p)
        {
            return;
        }
        _ = Task.Run(async () =>
        {
            var available = Available();
            PublishCameras(available);
            if ((available.FirstOrDefault(c => c.Id == config.Camera) ?? available.FirstOrDefault()) is not { } camera)
            {
                return;
            }
            try
            {
                await p.SwitchCameraAsync(camera, config.Resolution).ConfigureAwait(false);
                p.RequestKeyFrame();
                Ui(m => m.CameraError = null);
            }
            catch (Exception e) when (StreamErrors.Expected(e))
            {
                var message = StreamErrors.Message(e, $"{camera.Name} did not start");
                Ui(m => m.CameraError = message);
            }
        });
    }

    void ScheduleConfig()
    {
        lock (gate)
        {
            if (sendPending)
            {
                return;
            }
            sendPending = true;
        }
        _ = Task.Delay(ConfigInterval).ContinueWith(_ => SendConfig(), TaskScheduler.Default);
    }

    // Sends the full settings to the computer, when a stream runs.
    void SendConfig()
    {
        string? target;
        lock (gate)
        {
            sendPending = false;
            target = session is { Announced: true } s ? s.DeviceId : null;
        }
        if (target is null || settings is null)
        {
            return;
        }
        core?.Send(WebcamPackets.Config(settings.Config, settings.Caps), target);
    }

    // The cameras of this computer, with their names in the protocol.
    IReadOnlyList<CameraInfo> Available()
    {
        if (cameras is null)
        {
            return [];
        }
        try
        {
            return CameraNames.Name(cameras.Devices());
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            FluxLog.Info("stream", $"cannot list the cameras: {e.Message}");
            return [];
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

    void PublishStatus() => Ui(m =>
    {
        m.Status = CurrentStatus;
        if (!m.Status.Active)
        {
            m.Preview = null;
        }
        SyncMicrophone();
    });

    void OnPreview(object image) => Ui(m =>
    {
        if (pipeline?.IsCameraOpen == true)
        {
            m.Preview = image;
        }
    });

    // Starts the microphone when the webcam goes live with "Also send the
    // microphone" on, and stops the microphone that it started when the
    // webcam stops or the option turns off. It runs on the UI thread. It
    // reads the state of the microphone plugin and not its model, because
    // a start of the microphone reaches the model later.
    void SyncMicrophone()
    {
        if (core?.Plugin<MicPlugin>() is not { } mic)
        {
            return;
        }
        var s = Model.Status;
        var micStatus = mic.CurrentStatus;
        if (s.Phase == StreamPhase.Live && Model.SendsMicrophone && mic.Permission == MicPermission.Granted &&
            !micStatus.Active && s.DeviceId is { } deviceId)
        {
            mic.Start(deviceId);
            microphoneByWebcam = true;
        }
        else if ((!s.Active || !Model.SendsMicrophone) && microphoneByWebcam)
        {
            microphoneByWebcam = false;
            if (micStatus.Active)
            {
                mic.Stop();
            }
        }
    }

    // Sends the current settings to the model.
    void PublishConfig()
    {
        if (settings is not { } s)
        {
            return;
        }
        Ui(m =>
        {
            m.Config = s.Config;
            m.Caps = s.Caps;
        });
    }

    void PublishCameras(IReadOnlyList<CameraInfo> list)
    {
        var value = ValueList.From(list);
        Ui(m => m.Cameras = value);
    }

    // Runs change on the UI thread, in order.
    void Ui(Action<WebcamModel> change) => core?.Host.Post(() => change(Model));
}
