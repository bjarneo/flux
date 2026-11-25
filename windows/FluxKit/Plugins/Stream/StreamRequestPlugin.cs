namespace FluxKit;

// What the stream request plugin needs from the app. The app gives it only
// when it can stream both the webcam and the microphone. The plugin calls
// each member on the UI thread.
public interface IStreamStarter
{
    // True while the Flux window is in front. Then a new request shows the
    // prompt. Otherwise a notification shows the request.
    bool IsAppActive { get; }

    // Shows the prompt for the newest request, StreamRequestModel.Current.
    void Present();

    // True while a stream of the kind runs or starts to the computer.
    bool Streams(StreamRequestKind kind, string computerId);

    // Opens the webcam or the microphone page of the computer and starts the
    // stream. The plugin calls it only after a click of the user on start.
    void Start(StreamRequest request);

    // Opens the webcam or the microphone page of the computer and starts
    // nothing. The plugin calls it after a click on a notification whose
    // request ended or is too old. The user then starts the stream on the
    // page. The app opens only the page of a paired computer.
    void OpenPage(string computerId, StreamRequestKind kind);
}

// The open stream requests of the computers, for the UI.
public sealed class StreamRequestModel : Model
{
    ValueList<StreamRequest> requests = ValueList<StreamRequest>.Empty;

    // The open requests, the oldest first.
    public ValueList<StreamRequest> Requests
    {
        get => requests;
        internal set
        {
            if (Set(ref requests, value))
            {
                Changed(nameof(Current));
            }
        }
    }

    // The request that the prompt shows: the newest one.
    public StreamRequest? Current => requests.Count > 0 ? requests[^1] : null;
}

// flux.stream.request from a computer: flux-cli webcam start or flux-cli mic
// start asks this computer to start its webcam or its microphone. The packet
// never starts a stream. While the app is in front, the app shows a prompt.
// Otherwise a notification shows the request. Only a click of the user on
// start starts the stream. A request ends after 60 seconds.
// StreamRequestPlugin.swift of the Mac app has the same rules.
public sealed class StreamRequestPlugin : IFluxPlugin
{
    // The ID of the start action of the notification.
    internal const string StartAction = "start";

    readonly IStreamStarter? starter;
    // The book and the timers change only on the UI thread.
    readonly StreamRequestBook book = new();
    // The timer that ends each open request, by request ID.
    readonly Dictionary<string, CancellationTokenSource> expiries = [];
    FluxCore? core;

    // starter is null while the app cannot stream both kinds. lifetime is the
    // time after which an open request ends. A test sets a shorter time.
    public StreamRequestPlugin(IStreamStarter? starter = null, TimeSpan? lifetime = null)
    {
        this.starter = starter;
        book.Lifetime = lifetime ?? StreamRequest.Lifetime;
        Incoming = starter is null ? [] : [PacketType.StreamRequest];
    }

    public StreamRequestModel Model { get; } = new();

    // This computer lists flux.stream.request only when it can stream both
    // kinds.
    public IReadOnlyList<string> Incoming { get; }
    public IReadOnlyList<string> Outgoing { get; } = [];
    public IReadOnlyList<string> HandledTypes { get; } = [PacketType.StreamRequest];

    public void Attach(FluxCore core)
    {
        this.core = core;
        foreach (var kind in StreamRequestKinds.All)
        {
            core.Host.Notifier.Register(kind.NotificationCategory(), NotificationActions(kind), (action, info, _) =>
            {
                if (!StartsStream(action) || !info.TryGetValue("id", out var id))
                {
                    return;
                }
                // The category gives the kind. The computer must match the ID.
                var computerId = info.TryGetValue("computer", out var c) && StreamRequest.MakeId(kind, c) == id ? c : null;
                core.Host.Post(() => StartFromNotification(id, kind, computerId));
            });
        }
    }

    // The action of the notification.
    internal static IReadOnlyList<NotificationAction> NotificationActions(StreamRequestKind kind) =>
        [new NotificationAction(StartAction, kind.StartLabel())];

    // True for the start action and for a click on the notification itself,
    // whose text asks for it.
    internal static bool StartsStream(string action) => action is StartAction or Notifier.DefaultAction;

    // The core lock is held. The UI queue keeps the order of the packets.
    public void Handle(Packet packet, Device device)
    {
        if (StreamRequestKinds.Parse(packet) is not { } kind)
        {
            return;
        }
        var id = device.Id;
        var name = device.Name;
        var now = StreamRequest.Now;
        core?.Host.Post(() => Receive(kind, id, name, now));
    }

    // An unpair from either side ends the requests of the computer. A link
    // that only drops keeps them, so that a click after a reconnect still
    // works. The core lock is held.
    public void OnDisconnected(Device device)
    {
        if (device.Paired)
        {
            return;
        }
        var id = device.Id;
        core?.Host.Post(() => Forget(id));
    }

    // Requests

    // Takes a request from a computer. A new request shows the prompt while
    // the app is in front, else a notification. It runs on the UI thread.
    internal void Receive(StreamRequestKind kind, string computerId, string computerName, TimeSpan now)
    {
        var outcome = book.Receive(kind, computerId, computerName, Streams(kind, computerId), now, out var opened);
        switch (outcome)
        {
            case StreamRequestOutcome.TooSoon:
                FluxLog.Info("stream", $"stream request: ignored a {kind.WireName()} request from {computerName} that came less than 3 seconds after the last one");
                return;
            case StreamRequestOutcome.Streaming:
                FluxLog.Info("stream", $"stream request: ignored a {kind.WireName()} request from {computerName}, because the stream runs");
                return;
        }
        if (opened is not { } r)
        {
            return;
        }
        Publish();
        Arm(r);
        if (starter is { IsAppActive: true } active)
        {
            core?.Host.Notifier.Remove(r.Id);
            active.Present();
        }
        else
        {
            core?.Host.Notifier.Post(new SystemNotification(r.Id, kind.NotificationCategory(), r.Title, kind.NotificationText())
            {
                UserInfo = new Dictionary<string, string> { ["id"] = r.Id, ["computer"] = r.ComputerId },
            });
        }
    }

    // Starts the stream of an open request after a click of the user on
    // start in the prompt. The request ends. A request that ended or is too
    // old starts nothing. When a stream of the kind already runs to the
    // computer, the request does nothing. Call it on the UI thread.
    public void Start(string id) => Take(id, StreamRequest.Now);

    internal void Start(string id, TimeSpan now) => Take(id, now);

    // Starts the stream of a request after a click on its notification. When
    // the request ended or is too old, it only opens the page of the
    // computer, and the user starts the stream there. computerId is null when
    // the notification does not name the computer. Then a request that ended
    // opens nothing.
    internal void StartFromNotification(string id, StreamRequestKind kind, string? computerId) =>
        StartFromNotification(id, kind, computerId, StreamRequest.Now);

    internal void StartFromNotification(string id, StreamRequestKind kind, string? computerId, TimeSpan now)
    {
        if (Take(id, now) || computerId is null)
        {
            return;
        }
        starter?.OpenPage(computerId, kind);
    }

    // Ends an open request and opens its stream, unless a stream of the kind
    // already runs to the computer. It returns false when the request ended
    // or is too old.
    bool Take(string id, TimeSpan now)
    {
        if (book.Remove(id) is not { } r)
        {
            return false;
        }
        End([r]);
        if (!book.Fresh(r, now))
        {
            FluxLog.Info("stream", $"stream request: the {r.Kind.WireName()} request of {r.ComputerName} is too old");
            return false;
        }
        if (!Streams(r.Kind, r.ComputerId))
        {
            starter?.Start(r);
        }
        return true;
    }

    // Ends an open request without a stream: "Not now". Call it on the UI
    // thread.
    public void Dismiss(string id)
    {
        if (book.Remove(id) is { } r)
        {
            End([r]);
        }
    }

    // Ends the requests that are too old. The timer of each request does it
    // too. The app can also call it after the computer wakes up. Call it on
    // the UI thread.
    public void Expire() => Expire(StreamRequest.Now);

    internal void Expire(TimeSpan now)
    {
        var old = book.Expire(now);
        if (old.Count > 0)
        {
            End(old);
        }
    }

    // True while a stream of the kind runs or starts to the computer.
    bool Streams(StreamRequestKind kind, string computerId) => starter?.Streams(kind, computerId) == true;

    // Ends the requests of a computer that is no longer paired.
    internal void Forget(string computerId)
    {
        var gone = book.Forget(computerId);
        if (gone.Count > 0)
        {
            End(gone);
        }
    }

    // Removes the timers and the notifications of the ended requests, and
    // shows the open requests.
    void End(IReadOnlyList<StreamRequest> ended)
    {
        foreach (var r in ended)
        {
            if (expiries.Remove(r.Id, out var timer))
            {
                timer.Cancel();
                timer.Dispose();
            }
            core?.Host.Notifier.Remove(r.Id);
        }
        Publish();
    }

    // Ends the request after its lifetime. A new request of the same computer
    // and kind replaces the timer.
    void Arm(StreamRequest r)
    {
        if (expiries.Remove(r.Id, out var old))
        {
            old.Cancel();
            old.Dispose();
        }
        var timer = new CancellationTokenSource();
        expiries[r.Id] = timer;
        var delay = r.Received + book.Lifetime - StreamRequest.Now;
        var token = timer.Token;
        _ = Task.Delay(delay < TimeSpan.Zero ? TimeSpan.Zero : delay, token).ContinueWith(t =>
        {
            if (t.IsCanceled)
            {
                return;
            }
            core?.Host.Post(() =>
            {
                Expire();
                // The clock of Windows moves in steps of about 16 ms, so the
                // timer can end a moment before the request counts as old.
                // A request that is still open gets its timer again.
                if (expiries.TryGetValue(r.Id, out var current) && current == timer && book.Requests.Any(x => x.Id == r.Id))
                {
                    Arm(r);
                }
            });
        }, TaskScheduler.Default);
    }

    void Publish()
    {
        var current = ValueList.From(book.Requests);
        if (!current.Equals(Model.Requests))
        {
            Model.Requests = current;
        }
    }
}
