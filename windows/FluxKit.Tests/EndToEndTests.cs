using FluxKit;

namespace FluxKit.Tests;

// Tests against a headless fluxd. Each test uses its own ports, so the tests
// can run at the same time.
public class EndToEndTests
{
    static LanConfig Lan(Fluxd fluxd, int udpPort, int tcpPort) => new()
    {
        UdpPort = udpPort,
        PeerUdpPort = fluxd.UdpPort,
        FirstTcpPort = tcpPort,
        LastTcpPort = tcpPort + 8,
        LoopbackOnly = true,
    };

    // Starts the core, waits for the link, and pairs from this side.
    internal static async Task<DeviceSnapshot> PairFromWindowsAsync(Fluxd fluxd, TestCore t)
    {
        t.Core.Start();
        await Wait.UntilAsync(() => t.Computer is { Online: true }, "the link from fluxd", fluxd);
        var computer = t.Computer!;
        var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var key = t.Core.PreviewKey(computer.Id, ts);
        Assert.Equal(16, key.Length);
        t.Core.Pair(computer.Id, ts);
        await Wait.UntilAsync(async () => Json.String((await fluxd.DeviceAsync(t.Core.Local.DeviceId))?["pairState"]) == "incoming",
            "the request on fluxd", fluxd);
        await fluxd.CliAsync("accept", t.Core.Local.DeviceId, key);
        await Wait.UntilAsync(() => t.Computer is { Paired: true }, "the pairing", fluxd);
        return t.Computer!;
    }

    [FluxdFact]
    public async Task PairsFromWindowsAndPings()
    {
        await using var fluxd = await Fluxd.StartAsync(28716, 28720);
        using var t = new TestCore(Lan(fluxd, 28731, 28740), [new PingPlugin()]);
        var computer = await PairFromWindowsAsync(fluxd, t);
        Assert.True(computer.IsFlux);
        Assert.Equal("fluxd", computer.App);
        Assert.NotNull(t.Core.Trust.Get(computer.Id));
        // The toast comes through the queue of the UI, after the state.
        await Wait.UntilAsync(() => t.Toasts.Contains($"Paired with {computer.Name}"), "the pairing toast", fluxd);

        await fluxd.CliAsync("ping", "hello there");
        await Wait.UntilAsync(() => t.Toasts.Contains($"hello there from {computer.Name}"), $"the ping from fluxd, toasts: {string.Join(" | ", t.Toasts)}", fluxd);

        t.Core.Plugin<PingPlugin>()!.Ping(computer.Id);
        await Wait.UntilAsync(() => t.Toasts.Contains("Ping sent"), "the ping to fluxd", fluxd);
    }

    [FluxdFact]
    public async Task PairsFromFluxdAndUnpairs()
    {
        await using var fluxd = await Fluxd.StartAsync(28816, 28820);
        using var t = new TestCore(Lan(fluxd, 28831, 28840), [new PingPlugin()]);
        t.Core.Start();
        await Wait.UntilAsync(() => t.Computer is { Online: true }, "the link from fluxd", fluxd);
        var id = t.Core.Local.DeviceId;
        // flux-cli pair waits for an answer, so it runs while this side accepts.
        var pair = fluxd.CliAsync("pair", id);
        await Wait.UntilAsync(() => !t.PairRequests.IsEmpty || pair.IsFaulted, "the request from fluxd", fluxd);
        Assert.False(pair.IsFaulted, pair.Exception?.ToString());
        t.PairRequests.TryPeek(out var request);
        Assert.Equal(PairState.Incoming, request!.PairState);
        t.Core.AcceptPair(request.Id);
        await Wait.UntilAsync(() => t.Computer is { Paired: true }, "the pairing", fluxd);
        var key = t.Computer!.PairKey;
        try
        {
            await pair;
        }
        catch (InvalidOperationException)
        {
            // flux-cli pair asks for a confirmation on a terminal. The key
            // confirms the pairing in the next step.
        }
        await fluxd.CliAsync("accept", id, key);
        await Wait.UntilAsync(async () => Json.Bool((await fluxd.DeviceAsync(id))?["paired"]) == true, "the pairing on fluxd", fluxd);

        t.Core.Unpair(request.Id);
        await Wait.UntilAsync(async () => Json.Bool((await fluxd.DeviceAsync(id))?["paired"]) != true, "the unpair on fluxd", fluxd);
        Assert.Null(t.Core.Trust.Get(request.Id));
    }

    [FluxdFact]
    public async Task KeepsThePairingAfterARestart()
    {
        await using var fluxd = await Fluxd.StartAsync(28916, 28920);
        var lan = Lan(fluxd, 28931, 28940);
        var data = CoreTests.TempDir();
        string computerId;
        using (var first = new TestCore(lan, [new PingPlugin()]))
        {
            computerId = (await PairFromWindowsAsync(fluxd, first)).Id;
            foreach (var f in Directory.GetFiles(first.Data))
            {
                File.Copy(f, Path.Combine(data, Path.GetFileName(f)));
            }
            CopyDirectory(Path.Combine(first.Data, "identity"), Path.Combine(data, "identity"));
        }
        var queue = new SerialQueue();
        using var again = new FluxCore(new FluxPaths(data), new FluxHost { DeviceName = () => "Windows Test", DeviceType = "laptop", Post = queue.Post }, lan, [new PingPlugin()]);
        Assert.True(again.State.Devices.Single().Paired);
        again.Start();
        await Wait.UntilAsync(() => again.State.Devices.SingleOrDefault() is { Online: true, Paired: true }, "the link after the restart", fluxd);
        Assert.Equal(computerId, again.State.Devices.Single().Id);
    }

    [FluxdFact]
    public async Task DialsFluxdAndPairs()
    {
        await using var fluxd = await Fluxd.StartAsync(29016, 29020);
        // The announcements go to a port that nobody reads, so only the dial
        // of this side makes the link.
        using var t = new TestCore(Lan(fluxd, 29031, 29040) with { PeerUdpPort = 29099 }, [new PingPlugin()]);
        t.Core.Start();
        await Wait.UntilAsync(() => t.Core.IsRunning && t.Core.State.TcpPort > 0, "the start", fluxd);
        t.Core.Dial("127.0.0.1", fluxd.TcpPort);
        await Wait.UntilAsync(() => t.Computer is { Online: true }, "the link to fluxd", fluxd);
        var computer = t.Computer!;
        var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var key = t.Core.PreviewKey(computer.Id, ts);
        t.Core.Pair(computer.Id, ts);
        await Wait.UntilAsync(async () => Json.String((await fluxd.DeviceAsync(t.Core.Local.DeviceId))?["pairState"]) == "incoming",
            "the request on fluxd", fluxd);
        await fluxd.CliAsync("accept", t.Core.Local.DeviceId, key);
        await Wait.UntilAsync(() => t.Computer is { Paired: true }, "the pairing", fluxd);
    }

    static void CopyDirectory(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from))
        {
            File.Copy(f, Path.Combine(to, Path.GetFileName(f)));
        }
    }
}
