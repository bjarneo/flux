namespace FluxKit;

// flux.mic: this computer as a microphone for the computer, 1 stream at a
// time. This computer records 48 kHz mono PCM and writes it to the computer,
// which plays it into the source Flux Microphone. MicPlugin.swift of the Mac
// app has the same rules.
public sealed class MicPlugin : IFluxPlugin
{
    // The setting with the chosen input ID.
    internal const string InputKey = "mic.input";

    // The error when no microphone input exists.
    public const string NoMicrophoneText = "This computer has no microphone";

    // The error when the microphone permission of Windows is off.
    public const string DeniedText = "Allow the microphone for Flux in Settings > Privacy & security > Microphone";

    readonly IMicSource? source;
    FluxCore? core;

    // Guards the fields below. Each start and each end moves attempt
    // forward, so that the work of an old stream does nothing.
    readonly Lock gate = new();
    int attempt;
    string? deviceId;
    PayloadServer? server;
    TlsStream? stream;
    IMicCapture? capture;
    CancellationTokenSource? cancel;
    StreamStatus status = StreamStatus.None;

    // Without a source, this computer does not list flux.mic and starts no
    // microphone.
    public MicPlugin(IMicSource? source = null)
    {
        this.source = source;
        Incoming = source is null ? [] : [PacketType.Mic];
        Outgoing = source is null ? [] : [PacketType.Mic];
    }

    public MicModel Model { get; } = new();

    // True when the app gave a microphone source.
    public bool Supported => source is not null;

    public IReadOnlyList<string> Incoming { get; }
    public IReadOnlyList<string> Outgoing { get; }
    public IReadOnlyList<string> HandledTypes { get; } = [PacketType.Mic];

    // The payload ports of the listener. Tests use their own ports.
    internal (int First, int Last) PayloadPorts { get; set; } = (PayloadServer.FirstPort, PayloadServer.LastPort);

    // How long this computer waits for the computer to connect.
    internal TimeSpan ConnectTimeout { get; set; } = TimeSpan.FromSeconds(10);

    // The state of the stream now, on any thread. The model gets it later.
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

    // The microphone permission of Flux now.
    public MicPermission Permission
    {
        get
        {
            try
            {
                return source?.Permission ?? MicPermission.Denied;
            }
            catch (Exception e) when (StreamErrors.Expected(e))
            {
                return MicPermission.Denied;
            }
        }
    }

    public void Attach(FluxCore core)
    {
        this.core = core;
        var input = core.Settings.String(InputKey) ?? "";
        core.Host.Post(() => Model.Input = input);
        if (source is null)
        {
            return;
        }
        source.InputsChanged += () => core.Host.Post(InputsChanged);
        core.Host.Post(() =>
        {
            Model.Permission = Permission;
            InputsChanged();
        });
    }

    // Texts

    // The error when the Flux of the computer has no microphone support.
    internal static string UpdateText(string computer) => $"Update Flux on {computer} to use this computer as a microphone";

    // Actions

    // Starts a stream to the computer. A running stream stops first.
    public void Start(string deviceId)
    {
        if (core is not { } c || source is not { } s)
        {
            return;
        }
        Stop();
        var name = c.WithDevice(deviceId, d => d.Name) ?? "the computer";
        int id;
        CancellationToken token;
        lock (gate)
        {
            this.deviceId = deviceId;
            attempt++;
            id = attempt;
            cancel = new CancellationTokenSource();
            token = cancel.Token;
            Show(new StreamStatus(StreamPhase.Connecting, $"Waiting for {name}…", deviceId));
        }
        _ = Task.Run(() => RunAsync(c, s, deviceId, name, id, token));
    }

    // Stops the stream and tells the computer.
    public void Stop()
    {
        int id;
        lock (gate)
        {
            id = attempt;
        }
        End(StreamStatus.None, notify: true, id);
    }

    // Records from the input with the ID from now on. Empty means the default
    // input of Windows. A running stream moves to the input without a stop.
    // Call it on the UI thread.
    public void SelectInput(string id)
    {
        Model.Input = id;
        core?.Settings.Set(InputKey, id);
        SwitchCapture();
    }

    // Reads the microphone permission again, for example after the user
    // returns from the Settings app. Call it on the UI thread.
    public void RefreshPermission() => Model.Permission = Permission;

    // Asks for the permission when Windows did not ask yet. It returns true
    // when Flux can record.
    internal async Task<bool> AuthorizeAsync()
    {
        if (source is null)
        {
            return false;
        }
        bool granted;
        try
        {
            granted = source.Permission switch
            {
                MicPermission.Granted => true,
                MicPermission.Undetermined => await source.AuthorizeAsync().ConfigureAwait(false),
                _ => false,
            };
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            FluxLog.Info("mic", $"cannot ask for the microphone: {e.Message}");
            granted = false;
        }
        core?.Host.Post(RefreshPermission);
        return granted;
    }

    // Packets

    // The core lock is held.
    public void Handle(Packet packet, Device device)
    {
        if (MicReply.Parse(packet) is not { } reply || AttemptFor(device) is not { } id)
        {
            return;
        }
        var name = device.Name;
        switch (reply)
        {
            case MicReply.Live live:
                lock (gate)
                {
                    if (attempt == id)
                    {
                        Show(new StreamStatus(StreamPhase.Live, $"Live on {name} as {live.Source}", device.Id));
                    }
                }
                break;
            case MicReply.Failed failed:
                End(new StreamStatus(StreamPhase.Error, failed.Message, device.Id), notify: false, id);
                break;
            case MicReply.Stop:
                End(new StreamStatus(StreamPhase.Idle, $"Stopped on {name}", device.Id), notify: false, id);
                break;
        }
    }

    public void OnDisconnected(Device device)
    {
        if (AttemptFor(device) is not { } id)
        {
            return;
        }
        End(new StreamStatus(StreamPhase.Error, $"The connection to {device.Name} closed", device.Id), notify: false, id);
    }

    // The attempt of the stream to the device, or null when no stream goes there.
    int? AttemptFor(Device device)
    {
        lock (gate)
        {
            return deviceId == device.Id ? attempt : null;
        }
    }

    // Stream

    async Task RunAsync(FluxCore core, IMicSource source, string deviceId, string name, int id, CancellationToken token)
    {
        try
        {
            if (!await AuthorizeAsync().ConfigureAwait(false))
            {
                throw new StreamException(DeniedText);
            }
            var certificate = StreamPeer.Certificate(core, deviceId, name, PacketType.Mic, UpdateText(name));
            var connected = await ConnectAsync(core, deviceId, name, certificate, id).ConfigureAwait(false);
            bool keep;
            lock (gate)
            {
                keep = attempt == id;
                if (keep)
                {
                    server = null;
                    stream = connected;
                    Show(new StreamStatus(StreamPhase.Starting, $"Starting Flux Microphone on {name}…", deviceId));
                }
            }
            if (!keep)
            {
                await connected.DisposeAsync().ConfigureAwait(false);
                return;
            }
            await RecordAsync(core, source, connected, name, id, token).ConfigureAwait(false);
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            if (!Current(id))
            {
                return;
            }
            FluxLog.Info("mic", $"microphone stopped: {e.Message}");
            var message = e is StreamException ? e.Message : $"The connection to {name} closed";
            End(new StreamStatus(StreamPhase.Error, message, deviceId), notify: true, id);
        }
    }

    // Opens a listener, sends flux.mic "start" with its port, and waits for
    // the computer.
    async Task<TlsStream> ConnectAsync(FluxCore core, string deviceId, string name, byte[] certificate, int id)
    {
        var opened = PayloadServer.Open(core.Tls, certificate, PayloadPorts.First, PayloadPorts.Last);
        lock (gate)
        {
            if (attempt != id)
            {
                opened.Dispose();
                throw new OperationCanceledException();
            }
            server = opened;
        }
        if (!core.Send(MicPackets.Start(opened.Port), deviceId))
        {
            opened.Dispose();
            throw new StreamException($"Not connected to {name}");
        }
        return await StreamPeer.AcceptAsync(opened, ConnectTimeout, name).ConfigureAwait(false);
    }

    // Records and writes the audio until the stream ends. It throws when the
    // computer closes the connection.
    async Task RecordAsync(FluxCore core, IMicSource source, TlsStream connected, string name, int id, CancellationToken token)
    {
        var queue = new MicQueue();
        var level = new LevelThrottle();
        var feed = new MicFeed(samples =>
        {
            if (queue.Push(Pcm.ToLittleEndian(samples)) && queue.Dropped == 1)
            {
                FluxLog.Info("mic", "dropped audio, because the network is slower than the microphone");
            }
            if (level.Due())
            {
                ShowLevel(Pcm.Peak(samples), id);
            }
        }, message => Fail(message, id));
        try
        {
            if (source.Inputs().Count == 0)
            {
                throw new StreamException(NoMicrophoneText);
            }
            var input = core.Settings.String(InputKey) ?? "";
            var started = await source.StartAsync(input, feed, token).ConfigureAwait(false);
            lock (gate)
            {
                if (attempt == id)
                {
                    capture = started;
                    started = null;
                }
            }
            if (started is not null)
            {
                started.Dispose();
                return;
            }
            // The computer sends nothing. Its side ends when it closes.
            var read = DrainAsync(connected, token);
            var write = WriteAsync(connected, queue, token);
            var first = await Task.WhenAny(read, write).ConfigureAwait(false);
            VideoSink.Observe(first == read ? write : read);
            await first.ConfigureAwait(false);
        }
        finally
        {
            queue.Complete();
        }
        throw new StreamException($"The connection to {name} closed");
    }

    static async Task DrainAsync(TlsStream connected, CancellationToken token)
    {
        var buffer = new byte[1024];
        while (await connected.Stream.ReadAsync(buffer, token).ConfigureAwait(false) > 0)
        {
        }
    }

    static async Task WriteAsync(TlsStream connected, MicQueue queue, CancellationToken token)
    {
        while (await queue.TakeAsync(token).ConfigureAwait(false) is { } chunk)
        {
            await connected.Stream.WriteAsync(chunk, token).ConfigureAwait(false);
        }
    }

    // Moves a running capture to the chosen input.
    void SwitchCapture()
    {
        IMicCapture? running;
        lock (gate)
        {
            running = capture;
        }
        if (running is null)
        {
            return;
        }
        try
        {
            running.Use(Model.Input);
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            FluxLog.Info("mic", $"the microphone input did not change: {e.Message}");
        }
    }

    // Reloads the inputs after a device came or went. A running capture on a
    // device that went away moves to the default input. It runs on the UI
    // thread.
    void InputsChanged()
    {
        try
        {
            Model.Inputs = ValueList.From(source?.Inputs() ?? []);
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            FluxLog.Info("mic", $"cannot list the microphones: {e.Message}");
        }
        SwitchCapture();
    }

    // Ends the stream after the capture failed. The end runs in a task,
    // because it stops the capture, and the capture calls this method.
    void Fail(string message, int id)
    {
        string? target;
        lock (gate)
        {
            target = deviceId;
        }
        _ = Task.Run(() => End(new StreamStatus(StreamPhase.Error, message, target), notify: true, id));
    }

    bool Current(int id)
    {
        lock (gate)
        {
            return attempt == id;
        }
    }

    // Ends the stream of the attempt. With notify, the computer gets flux.mic
    // "stop" when it already got "start".
    void End(StreamStatus next, bool notify, int id)
    {
        string? target;
        PayloadServer? takenServer;
        TlsStream? takenStream;
        IMicCapture? takenCapture;
        CancellationTokenSource? takenCancel;
        lock (gate)
        {
            if (attempt != id)
            {
                return;
            }
            attempt++;
            target = deviceId;
            takenServer = server;
            takenStream = stream;
            takenCapture = capture;
            takenCancel = cancel;
            deviceId = null;
            server = null;
            stream = null;
            capture = null;
            cancel = null;
            Show(next);
        }
        takenCancel?.Cancel();
        takenServer?.Dispose();
        if (takenStream is not null)
        {
            _ = takenStream.DisposeAsync().AsTask();
        }
        try
        {
            takenCapture?.Dispose();
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            FluxLog.Info("mic", $"the microphone did not stop cleanly: {e.Message}");
        }
        if (notify && target is not null && (takenServer is not null || takenStream is not null))
        {
            core?.Send(MicPackets.Stop(), target);
        }
    }

    // Model

    // Shows a status. The gate is held, so the statuses reach the model in
    // order.
    void Show(StreamStatus next)
    {
        status = next;
        core?.Host.Post(() =>
        {
            Model.Status = next;
            if (next.Phase != StreamPhase.Live)
            {
                Model.Level = 0;
            }
        });
    }

    void ShowLevel(float peak, int id)
    {
        lock (gate)
        {
            if (attempt != id)
            {
                return;
            }
            core?.Host.Post(() => Model.Level = peak);
        }
    }
}
