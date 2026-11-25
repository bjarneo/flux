using System.Windows;
using FluxKit;

namespace Flux;

// The UI state of the app. It mirrors the core and holds the destination,
// the scope, the pages on top of each destination, and the theme setting.
// AppModel.swift of the Mac app has the same job.
public sealed partial class AppModel : Model
{
    public const string PairCategory = "pair";

    readonly Dictionary<Destination, List<Route>> paths = new()
    {
        [Destination.Chat] = [],
        [Destination.Control] = [],
        [Destination.Computers] = [],
    };

    CoreState state;
    string? toast;
    string? pairingSheet;
    Destination destination = Destination.Chat;
    string? scope;
    bool connecting;
    string? newlyPairedId;
    CancellationTokenSource? toastTimer;
    CancellationTokenSource? graceTimer;
    CancellationTokenSource? pairedTimer;

    public FluxCore Core { get; }

    public AppModel(FluxCore core)
    {
        Core = core;
        state = core.State;
        core.Changed += Apply;
        core.Toasted += Show;
        core.PairRequested += PairRequested;
        core.Host.Notifier.Register(PairCategory, [new NotificationAction("accept", "Accept"), new NotificationAction("reject", "Reject")],
            (action, info, _) => Post(() => PairAction(action, info)));
    }

    // Runs the action on the UI thread.
    void Post(Action action) => Core.Host.Post(action);

    public CoreState State
    {
        get => state;
        private set => Set(ref state, value);
    }

    // The message at the bottom of the window, for 3 seconds.
    public string? Toast
    {
        get => toast;
        private set => Set(ref toast, value);
    }

    // The computer that the pairing dialog shows.
    public string? PairingSheet
    {
        get => pairingSheet;
        set => Set(ref pairingSheet, value);
    }

    public Destination Destination
    {
        get => destination;
        set
        {
            if (Set(ref destination, value))
            {
                Changed(nameof(Path));
            }
        }
    }

    // The computer in scope, or null for all computers.
    public string? Scope
    {
        get => scope;
        private set => Set(ref scope, value);
    }

    // True for 3 seconds after a connection attempt starts. A computer that
    // is not online then counts as connecting.
    public bool Connecting
    {
        get => connecting;
        private set => Set(ref connecting, value);
    }

    // The computer that paired last, for 6 seconds.
    public string? NewlyPairedId
    {
        get => newlyPairedId;
        private set => Set(ref newlyPairedId, value);
    }

    // The theme setting.
    public ThemeMode Theme
    {
        get => Core.Plugin<ThemePlugin>()?.Model.Mode ?? ThemeMode.Computer;
        set
        {
            Core.Plugin<ThemePlugin>()?.SetMode(value);
            Changed();
        }
    }

    public IReadOnlyList<DeviceSnapshot> Paired => State.Devices.Where(d => d.Paired).ToArray();
    public IReadOnlyList<DeviceSnapshot> Available => State.Devices.Where(d => !d.Paired).ToArray();
    public IReadOnlyList<DeviceSnapshot> ConnectedPaired => State.Devices.Where(d => d.Paired && d.Online).ToArray();

    // The paired computer with the ID, or null.
    public DeviceSnapshot? PairedDevice(string? id) => id is null ? null : State.Devices.FirstOrDefault(d => d.Id == id && d.Paired);

    public DeviceSnapshot? DeviceOf(string id) => State.Devices.FirstOrDefault(d => d.Id == id);

    // Navigation

    // The pages on top of the destination on screen.
    public IReadOnlyList<Route> Path => paths[destination];

    public void Push(Route route)
    {
        paths[destination].Add(route);
        Changed(nameof(Path));
    }

    public void Back()
    {
        var p = paths[destination];
        if (p.Count > 0)
        {
            p.RemoveAt(p.Count - 1);
            Changed(nameof(Path));
        }
    }

    // Opens the root of a destination.
    public void Go(Destination d)
    {
        Destination = d;
        paths[d].Clear();
        Changed(nameof(Path));
    }

    public void SetScope(string? id)
    {
        Scope = id;
    }

    // State

    // Takes a new state of the core. Tests call it with a sample state.
    internal void Apply(CoreState s)
    {
        var old = State;
        State = s;
        Changed(nameof(Paired));
        Changed(nameof(Available));
        Changed(nameof(ConnectedPaired));
        // A computer that is no longer paired leaves the scope.
        if (scope is not null && !s.Devices.Any(d => d.Id == scope && d.Paired))
        {
            Scope = null;
        }
        // A computer that goes offline keeps the time, for "last seen" in Chats.
        var now = DateTimeOffset.Now;
        foreach (var d in old.Devices.Where(d => d.Paired && d.Online && !s.Devices.Any(n => n.Id == d.Id && n.Online)))
        {
            lastSeen[d.Id] = now;
        }
        // A new pairing shows the chat of the new computer.
        var before = old.Devices.ToDictionary(d => d.Id, d => d.Paired);
        if (s.Devices.FirstOrDefault(d => d.Paired && before.TryGetValue(d.Id, out var was) && !was) is { } paired)
        {
            PairingSheet = null;
            Scope = paired.Id;
            Chat = new ChatKey.Computer(paired.Id);
            paths[Destination.Chat].Clear();
            paths[Destination.Computers].Clear();
            Destination = Destination.Chat;
            Changed(nameof(Path));
            NotePaired(paired.Id);
        }
        foreach (var d in s.Devices.Where(d => d.PairState != PairState.Incoming))
        {
            Core.Host.Notifier.Remove("pair-" + d.Id);
        }
    }

    // Starts the 3 seconds in which a computer that is not online counts as
    // connecting.
    public void StartConnectGrace()
    {
        Connecting = true;
        graceTimer = Later(TimeSpan.FromSeconds(3), graceTimer, () => Connecting = false);
    }

    // Searches for the computers again.
    public void Retry()
    {
        StartConnectGrace();
        Core.Search();
    }

    void NotePaired(string id)
    {
        NewlyPairedId = id;
        pairedTimer = Later(TimeSpan.FromSeconds(6), pairedTimer, () => NewlyPairedId = null);
    }

    // Unpairs the computer. This computer also deletes its approval key for
    // the computer, so that a new pairing needs a new enrollment.
    public void Unpair(string id)
    {
        if (Core.Plugin<ApprovePlugin>() is { } approve)
        {
            approve.Unpair(id);
        }
        else
        {
            Core.Unpair(id);
        }
    }

    // The text of the unpair dialog. It names the approval key when this
    // computer has one for the computer.
    public string UnpairMessage(DeviceSnapshot d)
    {
        var text = $"{d.Name} and this computer forget each other. Pair again to use it.";
        return Core.Plugin<ApprovePlugin>()?.Model.KeyFor(d.Id) is null ? text : text + " " + ApproveTexts.UnpairNote(d.Name);
    }

    public void Show(string message)
    {
        Toast = message;
        toastTimer = Later(TimeSpan.FromSeconds(3), toastTimer, () => Toast = null);
    }

    // Runs the action on the UI thread after the delay, unless a later call
    // replaces the timer.
    CancellationTokenSource Later(TimeSpan delay, CancellationTokenSource? old, Action action)
    {
        old?.Cancel();
        var cts = new CancellationTokenSource();
        _ = Task.Delay(delay, cts.Token).ContinueWith(t =>
        {
            if (!t.IsCanceled)
            {
                Post(action);
            }
        }, TaskScheduler.Default);
        return cts;
    }

    // A request from a computer does not take the window, so that a key press
    // meant for the open page cannot accept it. The chat shows the request,
    // and a notification shows the key.
    void PairRequested(DeviceSnapshot d)
    {
        if (Application.Current?.MainWindow is { IsActive: true })
        {
            Show($"{d.Name} wants to pair");
        }
        Core.Host.Notifier.Post(new SystemNotification("pair-" + d.Id, PairCategory, $"Pair with {d.Name}?",
            $"Check that {d.Name} shows the key {Certificates.FormatKey(d.PairKey)}.")
        {
            UserInfo = new Dictionary<string, string> { ["device"] = d.Id, ["key"] = d.PairKey },
        });
    }

    void PairAction(string action, IReadOnlyDictionary<string, string> info)
    {
        if (!info.TryGetValue("device", out var id))
        {
            return;
        }
        switch (action)
        {
            case "accept":
                // Accept only the request whose key the notification showed.
                if (State.Devices.FirstOrDefault(d => d.Id == id) is { PairState: PairState.Incoming } d &&
                    info.TryGetValue("key", out var key) && d.PairKey == key)
                {
                    Core.AcceptPair(id);
                }
                break;
            case "reject":
                Core.CancelPair(id);
                break;
            default:
                // The pairing page of the computer shows the key.
                Destination = Destination.Computers;
                paths[Destination.Computers].Clear();
                paths[Destination.Computers].Add(new Route.Pairing(id));
                Changed(nameof(Path));
                ShowMain?.Invoke();
                break;
        }
    }

    // Brings the main window to the front. The app sets it.
    public Action? ShowMain { get; set; }

    // Theme

    // The palette to draw for the scope. systemDark is the app mode of Windows.
    public ThemePalette Palette(bool systemDark) =>
        Core.Plugin<ThemePlugin>()?.Model.Palette(scope, systemDark) ?? (systemDark ? ThemePalette.TokyoNight : ThemePalette.TokyoNightDay);
}
