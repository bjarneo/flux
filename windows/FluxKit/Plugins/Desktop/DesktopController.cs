using System.ComponentModel;
using System.Diagnostics;

namespace FluxKit;

// The panel that shows next to the video or under it.
public enum DesktopPanel
{
    None,
    Omarchy,
    Keys,
}

// The state of the remote desktop window of 1 computer: the stream, the
// pause rules, the mouse over the video, the keys, and the panels. The
// computer shows its screen while remote_desktop is on, and it takes the
// mouse and the keys while remote_input is on. DesktopController.swift and
// DesktopWindows.swift of the Mac app have the same rules. The window
// creates it on the UI thread, calls it on the UI thread, and calls Close
// when it closes.
//
// The stream pauses while the window is minimized and while this computer
// sleeps or is locked. The app sets Minimized and Locked. The stream stops
// when the link drops, and it starts again when the link comes back while
// the window shows and this computer is unlocked.
public sealed class DesktopController : RemoteKeyTarget
{
    // The message after a pause for a minimized window.
    public const string MinimizedText = "The stream stopped while the window was minimized.";

    // The message after a pause while this computer slept or was locked.
    public const string LockedText = "The stream stopped while this computer slept or was locked.";

    readonly FluxCore core;
    // The name when the window opened, for a computer that is gone.
    readonly string firstName;
    readonly DesktopPointer pointer = new();
    readonly DesktopMotionThrottle throttle = new();
    DeviceSnapshot? device;
    // The last values of the derived state, to report their changes.
    bool ready;
    bool control;
    bool panelShows;
    CancellationTokenSource? flush;
    CancellationTokenSource? refresh;
    // True after a dictation typed its text, so that the next one starts
    // with a space.
    bool afterVoice;
    bool closed;

    DesktopPanel panel;
    bool pointerInside;
    string? monitor;
    bool paused;
    bool hidden;
    bool minimized;
    bool locked;
    bool viewOnlyNotice;
    bool audioOn;
    double audioVolume = 1;
    double previousAudioVolume = 1;
    int screenPixels;

    public DesktopController(FluxCore core, DesktopPlugin plugin, RemoteInputPlugin input, DeviceSnapshot device) : base(core.Settings)
    {
        this.core = core;
        Plugin = plugin;
        Input = input;
        DeviceId = device.Id;
        firstName = device.Name;
        this.device = core.State.Devices.FirstOrDefault(d => d.Id == DeviceId);
        ready = Ready;
        control = Control;
        core.Changed += CoreChanged;
        input.Model.PropertyChanged += ModelChanged;
        plugin.Model.PropertyChanged += ModelChanged;
    }

    public string DeviceId { get; }
    public DesktopPlugin Plugin { get; }
    public RemoteInputPlugin Input { get; }

    // The computer now, or null when it is gone.
    public DeviceSnapshot? Device => device;

    public override string Name => device?.Name ?? firstName;

    // True while the computer shows its screen to this computer.
    public bool DesktopOn => Input.Model.IsDesktopOn(DeviceId);

    public bool ShortcutsSupported => device is { } d && DesktopPlugin.ShortcutsSupported(d);

    // True when the computer is online and shows its screen.
    public bool Ready => device is { Paired: true, Online: true } d && DesktopPlugin.Supported(d) && DesktopOn;

    // True when the mouse and the keys control the computer.
    public bool Control => Ready && Input.Model.IsOn(DeviceId);

    // The stream of this computer, or null when the stream shows another
    // computer.
    public DesktopStatus? Status => Plugin.Model.Status.DeviceId == DeviceId ? Plugin.Model.Status : null;

    // True while the video shows and has its size.
    public bool Live => Status is { Phase: DesktopPhase.Live, Width: > 0, Height: > 0 };

    // The Omarchy panel of this computer, or null before its first answer.
    public DesktopShortcutsState? Shortcuts => Plugin.Model.ShortcutsOf(DeviceId);

    public override bool KeysReady => Control;

    // The Windows key is Super while the pointer is over the video.
    public override bool SuperIsSuper => PointerInside && Live;

    public override bool WorkspaceKeys => ShortcutsSupported;

    // The panel that shows. The Omarchy panel reads the list of shortcuts
    // when it shows, and the workspaces every 3 seconds while it shows and
    // the stream does not pause.
    public DesktopPanel Panel
    {
        get => panel;
        set
        {
            if (Set(ref panel, value))
            {
                UpdatePanel();
            }
        }
    }

    // True while the pointer of this computer is over the video.
    public bool PointerInside
    {
        get => pointerInside;
        set
        {
            if (Set(ref pointerInside, value))
            {
                Changed(nameof(SuperIsSuper));
            }
        }
    }

    // The monitor that the user selected. A restart of the stream keeps it.
    public string? Monitor
    {
        get => monitor;
        set => Set(ref monitor, value);
    }

    // True after the stream stopped because this computer slept, locked,
    // or minimized the window, or when it was to start while Hidden. Resume
    // starts it.
    public bool Paused
    {
        get => paused;
        private set
        {
            if (Set(ref paused, value))
            {
                UpdatePanel();
            }
        }
    }

    // True while this computer sleeps or is locked, or the window is
    // minimized. The stream does not start then, also not after a
    // reconnect.
    public bool Hidden
    {
        get => hidden;
        private set => Set(ref hidden, value);
    }

    // True while the window is minimized. The app sets it.
    public bool Minimized
    {
        get => minimized;
        set
        {
            if (!Set(ref minimized, value))
            {
                return;
            }
            if (value)
            {
                Pause(MinimizedText);
            }
            else if (!Locked)
            {
                Resume();
            }
        }
    }

    // True while this computer sleeps, its screen is locked, or its session
    // is not active. The app sets it.
    public bool Locked
    {
        get => locked;
        set
        {
            if (!Set(ref locked, value))
            {
                return;
            }
            if (value)
            {
                Pause(LockedText);
            }
            else if (!Minimized)
            {
                Resume();
            }
        }
    }

    // True after a click on a view-only screen, to explain it.
    public bool ViewOnlyNotice
    {
        get => viewOnlyNotice;
        set => Set(ref viewOnlyNotice, value);
    }

    // True when the stream asks for the sound of the computer.
    public bool AudioOn
    {
        get => audioOn;
        private set => Set(ref audioOn, value);
    }

    // The volume of the sound, from 0 to 1.
    public double AudioVolume
    {
        get => audioVolume;
        set
        {
            var v = double.IsFinite(value) ? Math.Clamp(value, 0, 1) : 1;
            if (!Set(ref audioVolume, v))
            {
                return;
            }
            if (v > 0)
            {
                previousAudioVolume = v;
            }
            Plugin.SetAudioVolume((float)v);
        }
    }

    // The longest side of the screen of this computer in pixels. The app
    // sets it, and the stream size follows it from 640 to 3840 pixels.
    public int ScreenPixels
    {
        get => screenPixels;
        set => Set(ref screenPixels, value);
    }

    // Turns the sound on or off. The stream starts again with the change.
    public void ToggleAudio()
    {
        AudioOn = !AudioOn;
        Start();
    }

    public void ToggleMute() => AudioVolume = AudioVolume == 0 ? previousAudioVolume : 0;

    public void TogglePanel(DesktopPanel p) => Panel = Panel == p ? DesktopPanel.None : p;

    // Stream

    // Starts the stream, with the monitor that the user selected. While
    // Hidden, it only marks the stream to start at Resume.
    public void Start()
    {
        if (!Ready)
        {
            return;
        }
        if (Hidden)
        {
            Paused = true;
            return;
        }
        Paused = false;
        Plugin.Start(DeviceId, Monitor, DesktopPackets.Size(ScreenPixels), AudioOn);
    }

    // Shows another monitor of the computer.
    public void ShowMonitor(string m)
    {
        Monitor = m;
        Start();
    }

    // Stops the stream of this computer.
    public void Stop(DesktopStatus? status = null)
    {
        EndPointer();
        if (Status?.Active != true)
        {
            return;
        }
        Plugin.Stop(status);
    }

    // Stops the stream while this computer sleeps, locks, or minimizes the
    // window.
    public void Pause(string reason)
    {
        Hidden = true;
        if (Status?.Active != true)
        {
            return;
        }
        Stop(new DesktopStatus(DesktopPhase.Idle, reason, DeviceId));
        Paused = true;
    }

    // Starts the stream again after a pause, when this computer and the
    // window are back.
    public void Resume()
    {
        Hidden = false;
        if (!Paused)
        {
            return;
        }
        Paused = false;
        Start();
    }

    // Ends the window: the stream stops, and the modifiers clear.
    public void Close()
    {
        Stop();
        Mods = default;
        if (closed)
        {
            return;
        }
        closed = true;
        CancelFlush();
        refresh?.Cancel();
        refresh = null;
        core.Changed -= CoreChanged;
        Input.Model.PropertyChanged -= ModelChanged;
        Plugin.Model.PropertyChanged -= ModelChanged;
    }

    // Pointer

    // The pointer of this computer moves over the video. The computer
    // pointer follows, at most 60 times each second.
    public void Hover(DesktopPoint? at)
    {
        if (!Control || !Live || at is not { } p)
        {
            return;
        }
        if (throttle.Move(p, Now()) is { } now)
        {
            SendPointer([RemoteInput.At(now.X, now.Y)]);
        }
        else if (throttle.Pending is not null && flush is null)
        {
            var cts = new CancellationTokenSource();
            flush = cts;
            _ = Task.Delay(TimeSpan.FromMilliseconds(17), cts.Token).ContinueWith(t =>
            {
                if (t.IsCanceled)
                {
                    return;
                }
                core.Host.Post(() =>
                {
                    if (flush != cts)
                    {
                        return;
                    }
                    flush = null;
                    if (throttle.Flush(Now()) is { } late)
                    {
                        SendPointer([RemoteInput.At(late.X, late.Y)]);
                    }
                });
            }, TaskScheduler.Default);
        }
    }

    public void LeftDown(RemotePoint point, DesktopPoint at)
    {
        if (!Allowed())
        {
            return;
        }
        CancelFlush();
        pointer.LeftDown(point, at);
    }

    public void LeftDragged(RemotePoint point, DesktopPoint at)
    {
        if (!Control)
        {
            return;
        }
        SendPointer(pointer.LeftDragged(point, at));
    }

    public void LeftUp(RemotePoint point, DesktopPoint at, int clickCount)
    {
        if (!Control || !pointer.Pressed)
        {
            return;
        }
        SendPointer(pointer.LeftUp(point, at, clickCount));
        throttle.Reset(at, Now());
    }

    // Clicks the right or the middle button at the position.
    public void Click(RemoteClick c, DesktopPoint at)
    {
        if (!Allowed())
        {
            return;
        }
        CancelFlush();
        SendPointer([RemoteInput.ClickAt(c, at.X, at.Y)]);
        throttle.Reset(at, Now());
    }

    // Scrolls the window under the pointer with the wheel deltas of this
    // computer, see RemoteInput.Wheel.
    public void Wheel(double deltaX, double deltaY, DesktopPoint at)
    {
        if (!Control || RemoteInput.Wheel(deltaX, deltaY) is not { } p || p.Double("dx") is not { } dx || p.Double("dy") is not { } dy)
        {
            return;
        }
        SendPointer([RemoteInput.ScrollAt(dx, dy, at.X, at.Y)]);
    }

    // Sends the packets of touch actions, see DesktopTouches. It returns
    // the last new viewport of the actions, or null.
    public DesktopViewport? Touched(IReadOnlyList<DesktopTouchAction> actions)
    {
        DesktopViewport? viewport = null;
        foreach (var a in actions)
        {
            if (a is DesktopTouchAction.Viewport v)
            {
                viewport = v.Value;
            }
            else if (a.ToPacket() is { } p && Control && Live)
            {
                SendPointer([p]);
            }
            else if (a is DesktopTouchAction.Click && !Control && Live)
            {
                ViewOnlyNotice = true;
            }
        }
        return viewport;
    }

    // Ends a drag, for example when the window closes.
    public void EndPointer()
    {
        CancelFlush();
        SendPointer(pointer.Cancel(null));
    }

    // Keys

    public override void Send(IReadOnlyList<Packet> packets)
    {
        afterVoice = false;
        SendPointer(packets);
    }

    // Types the words of a dictation. A dictation right after another
    // starts with a space.
    public void TypeSpoken(string spoken)
    {
        var words = spoken.Trim();
        if (!Control || words.Length == 0)
        {
            return;
        }
        SendPointer([RemoteInput.Text(afterVoice ? " " + words : words)]);
        afterVoice = true;
    }

    // Omarchy panel

    // Sends a flux.shortcuts packet of the Omarchy panel.
    public void Shortcut(Packet p)
    {
        if (!Plugin.Send(p, DeviceId))
        {
            core.Toast($"{Name} is not reachable");
        }
    }

    // True when a click may go to the computer. A click on a view-only
    // screen explains why nothing happens.
    bool Allowed()
    {
        if (!Live)
        {
            return false;
        }
        if (!Control)
        {
            ViewOnlyNotice = true;
        }
        return Control;
    }

    void CancelFlush()
    {
        flush?.Cancel();
        flush = null;
    }

    void SendPointer(IReadOnlyList<Packet> packets) => Input.Send(packets, DeviceId);

    static double Now() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    // Starts the refresh of the Omarchy panel while it shows and the stream
    // does not pause, and asks for the shortcuts when the panel shows.
    void UpdatePanel()
    {
        var shows = !closed && Panel == DesktopPanel.Omarchy && Control;
        if (shows && !panelShows)
        {
            Shortcut(DesktopShortcuts.Request());
        }
        panelShows = shows;
        var wanted = shows && !Paused;
        if (wanted == (refresh is not null))
        {
            return;
        }
        refresh?.Cancel();
        refresh = null;
        if (!wanted)
        {
            return;
        }
        var cts = new CancellationTokenSource();
        refresh = cts;
        _ = RefreshAsync(cts.Token);
    }

    async Task RefreshAsync(CancellationToken ct)
    {
        try
        {
            while (true)
            {
                await Task.Delay(DesktopShortcuts.RefreshInterval, ct).ConfigureAwait(false);
                Plugin.Send(DesktopShortcuts.Refresh(), DeviceId);
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    // State

    void CoreChanged(CoreState state)
    {
        var next = state.Devices.FirstOrDefault(d => d.Id == DeviceId);
        if (next == device)
        {
            return;
        }
        device = next;
        Changed(nameof(Device));
        Changed(nameof(ShortcutsSupported));
        Follow();
    }

    void ModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        Changed(nameof(DesktopOn));
        Changed(nameof(Status));
        Changed(nameof(Live));
        Changed(nameof(Shortcuts));
        Follow();
    }

    // Reports the derived state, and starts or stops the stream when the
    // computer can show its screen or no longer can.
    void Follow()
    {
        if (closed)
        {
            return;
        }
        Changed(nameof(Ready));
        Changed(nameof(Control));
        ReadyChanged();
        var nowReady = Ready;
        var nowControl = Control;
        var readyChanged = nowReady != ready;
        var controlChanged = nowControl != control;
        ready = nowReady;
        control = nowControl;
        if (readyChanged)
        {
            if (nowReady)
            {
                Start();
            }
            else
            {
                Stop();
            }
        }
        if (controlChanged)
        {
            if (!nowControl && Panel != DesktopPanel.None)
            {
                Panel = DesktopPanel.None;
            }
            UpdatePanel();
        }
    }
}
