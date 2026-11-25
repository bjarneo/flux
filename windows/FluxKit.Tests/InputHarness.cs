using System.Collections.Concurrent;
using FluxKit;

namespace FluxKit.Tests;

// A FluxCore for the tests of remote input, the remote desktop, and Get
// files. It has its own downloads folder, records the toasts and the
// notifications, and runs the actions of the UI thread on its queue.
internal sealed class ControlHarness : IDisposable
{
    readonly SerialQueue queue = new();

    public FluxCore Core { get; }
    public string Data { get; }
    public string Downloads { get; }
    public ConcurrentQueue<string> Toasts { get; } = new();
    public ConcurrentQueue<SystemNotification> Notifications { get; } = new();

    // prepare gets the data folder before the core reads it.
    public ControlHarness(LanConfig lan, IReadOnlyList<IFluxPlugin> plugins, Action<string>? prepare = null)
    {
        Data = CoreTests.TempDir();
        Downloads = Path.Combine(CoreTests.TempDir(), "Downloads");
        prepare?.Invoke(Data);
        var notifier = new Notifier { Backend = new Recorder(Notifications) };
        var host = new FluxHost
        {
            DeviceName = () => "Windows Test",
            DeviceType = "laptop",
            AppVersion = "0.0.1",
            Post = queue.Post,
            Notifier = notifier,
            Downloads = () => Downloads,
        };
        FluxLog.Sink = (level, category, message) => TestCore.Log.Enqueue($"{level} {category}: {message}");
        Core = new FluxCore(new FluxPaths(Data), host, lan, plugins);
        Core.Toasted += Toasts.Enqueue;
    }

    // The only computer of the core.
    public DeviceSnapshot? Computer => Core.State.Devices.FirstOrDefault();

    // The configuration for a test against fluxd on loopback.
    public static LanConfig Lan(Fluxd fluxd, int udpPort, int tcpPort) => new()
    {
        UdpPort = udpPort,
        PeerUdpPort = fluxd.UdpPort,
        FirstTcpPort = tcpPort,
        LastTcpPort = tcpPort + 8,
        LoopbackOnly = true,
    };

    // Runs the function on the UI queue of the core and returns its result.
    public Task<T> OnUi<T>(Func<T> body)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        queue.Post(() =>
        {
            try
            {
                done.SetResult(body());
            }
            catch (Exception e)
            {
                done.SetException(e);
            }
        });
        return done.Task.WaitAsync(TimeSpan.FromSeconds(15));
    }

    public Task OnUi(Action body) => OnUi(() =>
    {
        body();
        return true;
    });

    // Starts the core, waits for the link, and pairs from this side, as
    // EndToEndTests.PairFromWindowsAsync does.
    public async Task<DeviceSnapshot> PairAsync(Fluxd fluxd)
    {
        Core.Start();
        await Wait.UntilAsync(() => Computer is { Online: true }, "the link from fluxd", fluxd);
        var computer = Computer!;
        var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var key = Core.PreviewKey(computer.Id, ts);
        Core.Pair(computer.Id, ts);
        await Wait.UntilAsync(async () => Json.String((await fluxd.DeviceAsync(Core.Local.DeviceId))?["pairState"]) == "incoming",
            "the request on fluxd", fluxd);
        await fluxd.CliAsync("accept", Core.Local.DeviceId, key);
        await Wait.UntilAsync(() => Computer is { Paired: true }, "the pairing", fluxd);
        return Computer!;
    }

    public void Dispose()
    {
        Core.Dispose();
        foreach (var dir in new[] { Data, Path.GetDirectoryName(Downloads)! })
        {
            try
            {
                Directory.Delete(dir, true);
            }
            catch (IOException)
            {
            }
        }
    }

    sealed class Recorder(ConcurrentQueue<SystemNotification> shown) : INotificationBackend
    {
        public void Show(SystemNotification notification, IReadOnlyList<NotificationAction> actions) => shown.Enqueue(notification);
        public void Remove(string id)
        {
        }
    }
}

// Records the packets of some types that reach the core, next to the
// plugins that handle them. It adds no capability.
internal sealed class PacketRecorder(params string[] types) : IFluxPlugin
{
    public ConcurrentQueue<Packet> Packets { get; } = new();
    public IReadOnlyList<string> Incoming { get; } = [];
    public IReadOnlyList<string> Outgoing { get; } = [];
    public IReadOnlyList<string> HandledTypes { get; } = types;
    public void Handle(Packet packet, Device device) => Packets.Enqueue(packet);
}
