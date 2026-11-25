using System.Collections.Immutable;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text.Json.Nodes;

namespace FluxKit;

// The phase of the remote desktop stream.
public enum DesktopPhase
{
    Idle,
    Connecting,
    Live,
    Error,
}

// The state of the remote desktop stream for the UI.
public sealed record DesktopStatus(DesktopPhase Phase = DesktopPhase.Idle, string Message = "", string? DeviceId = null, string Monitor = "")
{
    public ValueList<string> Monitors { get; init; } = ValueList<string>.Empty;

    // The size of the video, or 0 before the computer tells it.
    public int Width { get; init; }
    public int Height { get; init; }

    public bool Active => Phase is DesktopPhase.Connecting or DesktopPhase.Live;
}

// The UI state of the remote desktop and the Omarchy panel.
public sealed class DesktopModel : Model
{
    DesktopStatus status = new();
    ImmutableDictionary<string, DesktopShortcutsState> shortcuts = ImmutableDictionary<string, DesktopShortcutsState>.Empty;
    ValueList<string> pins = ValueList.From(DesktopShortcuts.DefaultPins);
    FluxSettings? settings;

    public DesktopStatus Status
    {
        get => status;
        internal set => Set(ref status, value);
    }

    // The key bindings, the workspaces, and the windows of each computer.
    public ImmutableDictionary<string, DesktopShortcutsState> Shortcuts
    {
        get => shortcuts;
        internal set => Set(ref shortcuts, value);
    }

    // The descriptions of the shortcuts that the Omarchy panel pins. The
    // settings keep them.
    public ValueList<string> Pins
    {
        get => pins;
        set
        {
            if (Set(ref pins, value))
            {
                settings?.Set(DesktopPlugin.PinsKey, new JsonArray(value.Select(p => (JsonNode)p).ToArray()));
            }
        }
    }

    // The state of the Omarchy panel of a computer, or null before its
    // first answer.
    public DesktopShortcutsState? ShortcutsOf(string deviceId) => shortcuts.GetValueOrDefault(deviceId);

    // Pins the shortcut to the panel, or unpins it.
    public void TogglePin(DesktopShortcut s)
    {
        var list = pins.ToList();
        if (!list.Remove(s.Description))
        {
            list.Add(s.Description);
        }
        Pins = ValueList.From(list);
    }

    internal void Load(FluxSettings from)
    {
        var saved = from.Node(DesktopPlugin.PinsKey) is JsonArray a ? Json.Strings(a) : null;
        settings = null;
        Pins = ValueList.From(saved ?? DesktopShortcuts.DefaultPins);
        settings = from;
    }
}

// A failure of the remote desktop with a message for the user.
internal sealed class DesktopError(string message) : Exception(message);

// flux.desktop and flux.shortcuts: the screen of a computer in a window on
// this computer, 1 stream at a time. This computer opens a TLS listener,
// the Omarchy computer connects and streams 1 monitor, and Video shows the
// frames. The computer shows its screen only while remote_desktop is on.
// The mouse and the keys go through RemoteInputPlugin. The Omarchy panel
// sends flux.shortcuts, and the answers go to the model.
// DesktopPlugin.swift of the Mac app has the same rules.
public sealed class DesktopPlugin : IFluxPlugin
{
    internal const string PinsKey = "desktop.pinnedShortcuts";

    // How long this computer waits for the Omarchy computer to connect.
    internal static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(15);

    // The error when the video decoder refuses the stream.
    internal const string CannotShowText = "This computer cannot show the stream";

    readonly DesktopAudio audio;
    readonly Lock gate = new();
    FluxCore? core;
    // Guarded by gate. Each start and each end moves attempt forward, so
    // that the work of an old stream does nothing.
    int attempt;
    string? deviceId;
    PayloadServer? server;
    TlsStream? stream;
    CancellationTokenSource? running;
    bool audioRequested;

    // audioOutput plays the sound of the computer. Without it, the stream
    // has no sound.
    public DesktopPlugin(IDesktopAudioOutput? audioOutput = null) => audio = new DesktopAudio(audioOutput);

    public IReadOnlyList<string> Incoming { get; } = [PacketType.Desktop, PacketType.Shortcuts];
    public IReadOnlyList<string> Outgoing { get; } = [PacketType.Desktop, PacketType.Shortcuts];

    public DesktopModel Model { get; } = new();

    // The video of the stream. The view attaches its output.
    public DesktopVideo Video { get; } = new();

    public void SetAudioVolume(float volume) => audio.SetVolume(volume);

    public void Attach(FluxCore core)
    {
        this.core = core;
        var settings = core.Settings;
        core.Host.Post(() => Model.Load(settings));
    }

    // True when the computer can stream its screen to this computer.
    public static bool Supported(DeviceSnapshot device) => device.Accepts(PacketType.Desktop);

    // True when the computer runs the actions of the Omarchy panel.
    public static bool ShortcutsSupported(DeviceSnapshot device) => device.Accepts(PacketType.Shortcuts);

    // Actions

    // Starts the stream from the computer. A running stream stops first.
    // monitor selects a monitor of the computer, and maxSize is the longest
    // side of the stream in pixels. audio asks for the sound.
    public void Start(string deviceId, string? monitor = null, int maxSize = DesktopPackets.DefaultSize, bool audio = false)
    {
        if (core is not { } c)
        {
            return;
        }
        Stop();
        var name = c.WithDevice(deviceId, d => d.Name) ?? "the computer";
        var cts = new CancellationTokenSource();
        int id;
        lock (gate)
        {
            this.deviceId = deviceId;
            audioRequested = audio;
            running = cts;
            attempt++;
            Show(new DesktopStatus(DesktopPhase.Connecting, $"Waiting for {name}…", deviceId, monitor ?? ""));
            id = attempt;
        }
        Video.Reset();
        FluxLog.Info("desktop", $"remote desktop: asking {name} for {monitor ?? "the focused monitor"}, max {maxSize} px");
        _ = Task.Run(() => RunAsync(c, deviceId, name, monitor, maxSize, id, cts.Token));
    }

    // Stops the stream and tells the computer. status shows after the stop.
    public void Stop(DesktopStatus? status = null)
    {
        int current;
        lock (gate)
        {
            current = attempt;
        }
        End(status ?? new DesktopStatus(), notify: true, current);
    }

    // Sends a flux.shortcuts packet. It returns false when the computer is
    // offline.
    public bool Send(Packet packet, string deviceId) => core?.Send(packet, deviceId) ?? false;

    // Packets

    public void Handle(Packet packet, Device device)
    {
        if (packet.Type == PacketType.Desktop && packet.String("state") == "audio")
        {
            if (AttemptFor(device) is not null && packet.String("message") is { } message)
            {
                core?.Toast(message);
            }
            return;
        }
        if (packet.Type == PacketType.Shortcuts)
        {
            var id = device.Id;
            core?.Host.Post(() => Model.Shortcuts = Model.Shortcuts.SetItem(id, DesktopShortcuts.Merge(Model.ShortcutsOf(id), packet)));
            return;
        }
        if (DesktopReply.Parse(packet) is not { } reply || AttemptFor(device) is not { } current)
        {
            return;
        }
        var name = device.Name;
        var deviceId = device.Id;
        switch (reply)
        {
            case DesktopReply.Live live:
                FluxLog.Info("desktop", $"remote desktop: {name} shows {live.Monitor} at {live.Width}x{live.Height}, monitors {string.Join(",", live.Monitors)}");
                lock (gate)
                {
                    if (attempt != current)
                    {
                        return;
                    }
                    core?.Host.Post(() =>
                    {
                        var s = Model.Status;
                        if (!s.Active || s.DeviceId != deviceId)
                        {
                            return;
                        }
                        // The size frame of the stream wins over the packet.
                        var sized = s.Width == 0 || s.Height == 0;
                        Model.Status = s with
                        {
                            Phase = DesktopPhase.Live,
                            Message = $"Shows {name}",
                            Monitor = live.Monitor,
                            Monitors = ValueList.From(live.Monitors),
                            Width = sized ? live.Width : s.Width,
                            Height = sized ? live.Height : s.Height,
                        };
                    });
                }
                break;
            case DesktopReply.Failed failed:
                FluxLog.Info("desktop", $"remote desktop: {name} failed: {failed.Message}");
                End(new DesktopStatus(DesktopPhase.Error, failed.Message, deviceId), notify: false, current);
                break;
            case DesktopReply.Stop:
                End(new DesktopStatus(DesktopPhase.Idle, $"Stopped on {name}", deviceId), notify: false, current);
                break;
        }
    }

    public void OnDisconnected(Device device)
    {
        if (AttemptFor(device) is { } current)
        {
            End(new DesktopStatus(DesktopPhase.Error, $"The connection to {device.Name} closed", device.Id), notify: false, current);
        }
    }

    // The attempt of the stream from the device, or null when no stream
    // comes from there.
    int? AttemptFor(Device device)
    {
        lock (gate)
        {
            return deviceId == device.Id ? attempt : null;
        }
    }

    // Stream

    sealed record Peer(bool Accepts, byte[]? Certificate);

    async Task RunAsync(FluxCore core, string deviceId, string name, string? monitor, int maxSize, int id, CancellationToken ct)
    {
        try
        {
            var peer = core.WithDevice(deviceId, d => new Peer(d.Accepts(PacketType.Desktop), d.Certificate));
            if (peer is null)
            {
                throw new DesktopError($"{name} is not known");
            }
            if (!peer.Accepts)
            {
                throw new DesktopError($"Update Flux on {name} to show its screen");
            }
            if (peer.Certificate is not { } certificate)
            {
                throw new DesktopError($"{name} is not connected");
            }
            var opened = await ConnectAsync(core, deviceId, name, monitor, maxSize, certificate, id, ct).ConfigureAwait(false);
            bool keep;
            lock (gate)
            {
                keep = attempt == id;
                if (keep)
                {
                    server = null;
                    stream = opened;
                }
            }
            if (!keep)
            {
                await opened.DisposeAsync().ConfigureAwait(false);
                return;
            }
            await ReadAsync(opened, id, ct).ConfigureAwait(false);
            End(new DesktopStatus(DesktopPhase.Error, $"{name} stopped the stream", deviceId), notify: false, id);
        }
        catch (Exception e) when (e is DesktopError or IOException or SocketException or ObjectDisposedException or
                                  OperationCanceledException or TimeoutException or InvalidDataException or AuthenticationException)
        {
            lock (gate)
            {
                if (attempt != id)
                {
                    return;
                }
            }
            FluxLog.Info("desktop", $"remote desktop ended: {e.Message}");
            var message = e is DesktopError ? e.Message : $"The connection to {name} closed";
            End(new DesktopStatus(DesktopPhase.Error, message, deviceId), notify: true, id);
        }
    }

    // Opens a listener, sends flux.desktop "start" with its port, and waits
    // for the computer. The computer connects out, as for the webcam, and
    // must use the certificate of the paired computer. The listener closes
    // a connection with another certificate and waits on.
    async Task<TlsStream> ConnectAsync(FluxCore core, string deviceId, string name, string? monitor, int maxSize,
                                       byte[] certificate, int id, CancellationToken ct)
    {
        var listener = PayloadServer.Open(core.Tls, certificate);
        bool keep;
        bool withAudio;
        lock (gate)
        {
            keep = attempt == id;
            if (keep)
            {
                server = listener;
            }
            withAudio = audioRequested;
        }
        if (!keep)
        {
            listener.Dispose();
            throw new OperationCanceledException("a newer stream started");
        }
        if (!core.Send(DesktopPackets.Start(listener.Port, monitor, maxSize, withAudio), deviceId))
        {
            listener.Dispose();
            throw new DesktopError($"Not connected to {name}");
        }
        try
        {
            return await listener.AcceptAsync(ConnectTimeout, ct).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // An error packet from the computer ends the attempt first, with
            // its message.
            throw new DesktopError($"{name} did not connect. Update Flux on the computer.");
        }
    }

    // Reads the frames until the computer closes the stream, and shows them.
    async Task ReadAsync(TlsStream opened, int id, CancellationToken ct)
    {
        var reader = new DesktopFrameReader();
        var buffer = new byte[64 * 1024];
        while (true)
        {
            var n = await opened.Stream.ReadAsync(buffer, ct).ConfigureAwait(false);
            if (n == 0)
            {
                return;
            }
            lock (gate)
            {
                if (attempt != id)
                {
                    return;
                }
            }
            foreach (var frame in reader.Push(buffer.AsSpan(0, n)))
            {
                if (frame.IsAudio)
                {
                    bool wanted;
                    lock (gate)
                    {
                        wanted = attempt == id && audioRequested;
                    }
                    if (wanted)
                    {
                        audio.Feed(frame.Data);
                    }
                }
                else if (frame.Size is { } size)
                {
                    ShowSize(size.Width, size.Height, id);
                }
                else if (frame.IsConfig)
                {
                    if (DesktopH264.ParameterSets(frame.Data) is { } sets && !Video.Configure(sets.Sps, sets.Pps))
                    {
                        throw new DesktopError(CannotShowText);
                    }
                }
                else
                {
                    Video.Show(frame.Data, frame.IsKey);
                }
            }
        }
    }

    // Ends the stream of the attempt. With notify, the computer gets
    // flux.desktop "stop" when it already got "start".
    void End(DesktopStatus status, bool notify, int id)
    {
        string? target;
        PayloadServer? listener;
        TlsStream? open;
        CancellationTokenSource? cts;
        lock (gate)
        {
            if (attempt != id)
            {
                return;
            }
            attempt++;
            target = deviceId;
            listener = server;
            open = stream;
            cts = running;
            deviceId = null;
            server = null;
            stream = null;
            running = null;
            Show(status);
        }
        audio.Stop();
        cts?.Cancel();
        listener?.Dispose();
        if (open is not null)
        {
            _ = open.DisposeAsync().AsTask();
        }
        Video.Reset();
        if (notify && target is not null && (listener is not null || open is not null))
        {
            core?.Send(DesktopPackets.Stop(), target);
        }
    }

    // Model

    // Shows a status. The lock is held, so the statuses reach the model in
    // order.
    void Show(DesktopStatus status) => core?.Host.Post(() => Model.Status = status);

    void ShowSize(int width, int height, int id)
    {
        lock (gate)
        {
            if (attempt != id)
            {
                return;
            }
            core?.Host.Post(() =>
            {
                var s = Model.Status;
                if (!s.Active || (s.Width == width && s.Height == height))
                {
                    return;
                }
                Model.Status = s with { Width = width, Height = height };
            });
        }
    }
}
