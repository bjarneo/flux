using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// A battery that a test changes.
public sealed class FakeBattery(BatteryState? state) : IBatterySource
{
    public BatteryState? State { get; private set; } = state;

    public BatteryState? Read() => State;

    public event Action? Changed;

    public void Change(BatteryState? state)
    {
        State = state;
        Changed?.Invoke();
    }
}

// A Do Not Disturb state that a test changes. After an apply that works, it
// reports the new state like Windows does.
public sealed class FakeDnd(bool? state, bool canApply) : IDndSource
{
    public bool? State { get; private set; } = state;
    public bool CanApply { get; } = canApply;
    public ConcurrentQueue<bool> Applied { get; } = new();

    // The error of the next applies, or null.
    public string? Error { get; set; }

    public bool? Read() => State;

    public event Action<bool>? Changed;

    public void Change(bool on)
    {
        State = on;
        Changed?.Invoke(on);
    }

    public Task<string?> ApplyAsync(bool on)
    {
        Applied.Enqueue(on);
        if (Error is null)
        {
            Change(on);
        }
        return Task.FromResult(Error);
    }
}

// The notifications that the system still shows from an earlier run.
public sealed class FakeNotificationHistory(IReadOnlyList<string> ids) : INotificationHistory
{
    public IReadOnlyList<string> DeliveredIds() => ids;
}

// The battery, notification, and Do Not Disturb plugins against a computer
// on loopback.
public class SystemPluginTests
{
    static Packet Dnd(bool on) => new(PacketType.Dnd, new JsonObject { ["on"] = on });

    [Fact]
    public void AComputerWithoutABatteryDoesNotAdvertiseIt()
    {
        var none = new BatteryPlugin(new FakeBattery(null));
        Assert.False(none.HasBattery);
        Assert.Empty(none.Outgoing);
        Assert.Equal([PacketType.Battery], none.Incoming);
        Assert.Empty(new BatteryPlugin().Outgoing);
        var laptop = new BatteryPlugin(new FakeBattery(new BatteryState(50, false)));
        Assert.True(laptop.HasBattery);
        Assert.Equal([PacketType.Battery], laptop.Outgoing);
    }

    [Fact]
    public async Task BatteryGoesBothWays()
    {
        using var computer = new SystemTestComputer(32200, 32201, [PacketType.Battery], [PacketType.Battery]);
        var battery = new FakeBattery(new BatteryState(57, true));
        var plugin = new BatteryPlugin(battery);
        using var t = new TestCore(SystemTestComputer.CoreLan(32220), [plugin]);
        await computer.PairAsync(t);

        // The battery goes out on connect.
        await Wait.UntilAsync(() => computer.Got(PacketType.Battery).Count == 1, "the battery on connect");
        Assert.Equal(new BatteryState(57, true), BatteryState.From(computer.Got(PacketType.Battery)[0]));

        // A change goes out, and the same state does not go out again.
        battery.Change(new BatteryState(14, false));
        battery.Change(new BatteryState(14, false));
        await Wait.UntilAsync(() => computer.Got(PacketType.Battery).Count == 2, "the battery after a change");
        var low = computer.Got(PacketType.Battery)[1];
        Assert.Equal(14, low.Int("currentCharge"));
        Assert.Equal(1, low.Int("thresholdEvent"));
        await Task.Delay(300);
        Assert.Equal(2, computer.Got(PacketType.Battery).Count);

        // The battery of the computer shows in the model.
        computer.Send(new BatteryState(80, true).ToPacket());
        await Wait.UntilAsync(() => plugin.Model.Of(computer.Id) == new BatteryState(80, true), "the battery of the computer");
        computer.Send(new Packet(PacketType.Battery, new JsonObject { ["currentCharge"] = -1 }));
        await Wait.UntilAsync(() => plugin.Model.Of(computer.Id) is null, "a computer without a battery");
        computer.Send(new BatteryState(30, false).ToPacket());
        await Wait.UntilAsync(() => plugin.Model.Of(computer.Id) is not null, "the battery again");
        computer.Disconnect();
        await Wait.UntilAsync(() => plugin.Model.Computers.IsEmpty, "the end of the battery after the link closes");
    }

    [Fact]
    public async Task NotificationsShowWithTheLimits()
    {
        using var computer = new SystemTestComputer(32250, 32251, [], [PacketType.Notification]);
        var plugin = new NotificationsPlugin();
        using var t = new TestCore(SystemTestComputer.CoreLan(32270), [plugin]);
        var shown = new SystemNotificationRecorder();
        t.Core.Host.Notifier.Backend = shown;
        await computer.PairAsync(t);
        var opened = new ConcurrentQueue<string>();
        plugin.Opened += opened.Enqueue;

        computer.Send(new Packet(PacketType.Notification, new JsonObject { ["id"] = "a", ["appName"] = "Firefox", ["title"] = "Secret title zqx", ["text"] = "Secret text zqx" }));
        await Wait.UntilAsync(() => shown.Shown.Count == 1, "the first notification");
        var first = shown.Shown[0];
        Assert.Equal($"computer-{computer.Id}:a", first.Id);
        Assert.Equal(NotificationsPlugin.Category, first.Category);
        Assert.Equal("Secret title zqx", first.Title);
        Assert.Equal("Secret text zqx", first.Body);
        Assert.Equal($"Firefox · {computer.Name}", first.Subtitle);
        Assert.True(first.Sound); // the first of a burst makes a sound
        Assert.Equal(computer.Id, first.UserInfo[NotificationsPlugin.ComputerKey]);

        // A notification with the same ID replaces the old one.
        computer.Send(new Packet(PacketType.Notification, new JsonObject { ["id"] = "a", ["title"] = "Again" }));
        await Wait.UntilAsync(() => shown.Shown.Count == 2, "the second notification");
        Assert.Single(shown.Current);
        Assert.Equal("Again", shown.Current[first.Id].Title);
        Assert.False(shown.Shown[1].Sound); // the rest of a burst is quiet

        // A burst of 10, then the limit drops the rest.
        for (var i = 0; i < 10; i++)
        {
            computer.Send(new Packet(PacketType.Notification, new JsonObject { ["id"] = $"n{i}", ["title"] = $"Burst {i}" }));
        }
        await Wait.UntilAsync(() => Count(plugin.Model.Received, computer.Id) == 10 && Count(plugin.Model.Dropped, computer.Id) == 2,
            $"the burst, received {Count(plugin.Model.Received, computer.Id)}");
        Assert.Equal(10, shown.Shown.Count);
        Assert.All(shown.Shown.Skip(1), n => Assert.False(n.Sound));

        // A packet without a title shows nothing.
        computer.Send(new Packet(PacketType.Notification, new JsonObject { ["id"] = "x", ["text"] = "only text" }));

        // A click names the computer.
        t.Core.Host.Notifier.Activate(NotificationsPlugin.Category, Notifier.DefaultAction, first.UserInfo);
        await Wait.UntilAsync(() => opened.Contains(computer.Id), "the click");

        // The log never holds the text of a notification.
        Assert.DoesNotContain(TestCore.Log, line => line.Contains("zqx"));
    }

    [Fact]
    public void TheNotificationsOfAnEarlierRunCountTowardTheCap()
    {
        var pc = Guid.NewGuid().ToString("N");
        var found = Enumerable.Range(0, 25).Select(i => $"computer-{pc}:{i}").ToArray();
        using var p = new SystemPluginCore([new NotificationsPlugin(new FakeNotificationHistory(found))]);
        Assert.Equal(found.Take(5), p.Notifications.Removed);
    }

    [Fact]
    public async Task DndGoesBothWaysWithoutAnEcho()
    {
        using var a = new SystemTestComputer(32300, 32301, [PacketType.Dnd], [PacketType.Dnd], "omarchy-a");
        using var b = new SystemTestComputer(32310, 32311, [PacketType.Dnd], [PacketType.Dnd], "omarchy-b");
        var dnd = new FakeDnd(false, canApply: true);
        var plugin = new DndPlugin(dnd);
        using var t = new TestCore(SystemTestComputer.CoreLan(32320), [plugin]);
        await a.PairAsync(t);
        await b.PairAsync(t);
        await Wait.UntilAsync(() => plugin.Model.CanApply && plugin.Model.FocusOn == false, "the start state");

        // A state from a computer applies, goes to the other computer, and
        // does not go back.
        a.Send(Dnd(true));
        await Wait.UntilAsync(() => b.Got(PacketType.Dnd).Count == 1, "the state on the other computer");
        Assert.Equal([true], dnd.Applied);
        Assert.True(b.Got(PacketType.Dnd)[0].Bool("on"));
        Assert.True(plugin.Model.Computers[a.Id]);
        await Task.Delay(300);
        Assert.Empty(a.Got(PacketType.Dnd));
        Assert.Single(b.Got(PacketType.Dnd));
        Assert.True(plugin.Model.FocusOn);

        // The same state again does not apply again.
        a.Send(Dnd(true));
        await Task.Delay(300);
        Assert.Single(dnd.Applied);

        // A local change goes to each computer.
        dnd.Change(false);
        await Wait.UntilAsync(() => a.Got(PacketType.Dnd).Count == 1 && b.Got(PacketType.Dnd).Count == 2, "the local change");
        Assert.False(a.Got(PacketType.Dnd)[0].Bool("on"));

        // With the sync off, nothing goes out and nothing applies.
        plugin.Model.Sync = false;
        Assert.False(t.Core.Settings.Bool(DndPlugin.SyncKey, true));
        a.ClearReceived();
        b.ClearReceived();
        dnd.Change(true);
        a.Send(Dnd(false));
        await Task.Delay(500);
        Assert.Empty(a.Got(PacketType.Dnd));
        Assert.Empty(b.Got(PacketType.Dnd));
        Assert.Single(dnd.Applied);

        // An apply that fails shows the error.
        plugin.Model.Sync = true;
        dnd.Error = "no access";
        b.Send(Dnd(false));
        await Wait.UntilAsync(() => plugin.Model.LastError == "no access", "the error");
        await Wait.UntilAsync(() => t.Toasts.Contains("Flux cannot turn Do Not Disturb off: no access"), "the toast");
        Assert.Equal([true, false], dnd.Applied);
    }

    [Fact]
    public async Task DndShowsTheStateOfAComputerThatThisComputerCannotFollow()
    {
        using var computer = new SystemTestComputer(32350, 32351, [PacketType.Dnd], [PacketType.Dnd]);
        var dnd = new FakeDnd(false, canApply: false);
        var plugin = new DndPlugin(dnd);
        using var t = new TestCore(SystemTestComputer.CoreLan(32370), [plugin]);
        await computer.PairAsync(t);

        computer.Send(Dnd(true));
        await Wait.UntilAsync(() => plugin.Model.Computers.TryGetValue(computer.Id, out var on) && on, "the state of the computer");
        Assert.False(plugin.Model.CanApply);
        Assert.Empty(dnd.Applied);

        // A local change still goes out.
        dnd.Change(true);
        await Wait.UntilAsync(() => computer.Got(PacketType.Dnd).Count == 1, "the local change");
        Assert.True(computer.Got(PacketType.Dnd)[0].Bool("on"));
    }

    [Fact]
    public async Task DndChangeWaitsForAComputerWithoutALink()
    {
        using var computer = new SystemTestComputer(32400, 32401, [PacketType.Dnd], [PacketType.Dnd]);
        var dnd = new FakeDnd(false, canApply: true);
        var plugin = new DndPlugin(dnd);
        using var t = new TestCore(SystemTestComputer.CoreLan(32420), [plugin]);
        await computer.PairAsync(t);

        computer.Disconnect();
        await Wait.UntilAsync(() => computer.Snapshot(t) is { Online: false }, "the end of the link");
        dnd.Change(true);
        await computer.ReconnectAsync(t);
        await Wait.UntilAsync(() => computer.Got(PacketType.Dnd).Count == 1, "the change after the reconnect");
        Assert.True(computer.Got(PacketType.Dnd)[0].Bool("on"));

        // The change goes out once.
        computer.Disconnect();
        await Wait.UntilAsync(() => computer.Snapshot(t) is { Online: false }, "the end of the second link");
        await computer.ReconnectAsync(t);
        await Task.Delay(300);
        Assert.Single(computer.Got(PacketType.Dnd));
    }

    [Fact]
    public void DndChangeWhileFluxDidNotRunWaitsForThePairedComputers()
    {
        // The last run saw Do Not Disturb off, and 1 computer is paired.
        var data = CoreTests.TempDir();
        var pc = Guid.NewGuid().ToString("N");
        File.WriteAllText(Path.Combine(data, "settings.json"), """{"dnd.focus": false}""");
        File.WriteAllText(Path.Combine(data, "trusted.json"),
            $$"""[{"id":"{{pc}}","name":"omarchy","type":"laptop","certificate":"{{Convert.ToBase64String([1])}}","isFlux":true}]""");
        using var p = new SystemPluginCore([new DndPlugin(new FakeDnd(true, true))], data);
        Assert.Equal([pc], Json.Strings(p.Core.Settings.Node(FocusBacklog.WaitingKey)));
        Assert.True(Json.Bool(p.Core.Settings.Node(FocusBacklog.UnsentKey)));
    }

    static int Count(System.Collections.Immutable.ImmutableDictionary<string, int> counts, string key) =>
        counts.TryGetValue(key, out var n) ? n : 0;
}
