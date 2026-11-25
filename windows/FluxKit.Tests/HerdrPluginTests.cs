using System.Collections.Concurrent;
using FluxKit;

namespace FluxKit.Tests;

// A manual clock for the timers of HerdrPlugin. Advance runs the actions
// that are due, in the order of their times.
internal sealed class HerdrTimers
{
    sealed class Item(TimeSpan at, long order, Action action)
    {
        public TimeSpan At { get; } = at;
        public long Order { get; } = order;
        public Action Action { get; } = action;
        public bool Canceled { get; set; }
    }

    readonly List<Item> items = [];
    TimeSpan now;
    long order;

    public Action After(TimeSpan delay, Action action)
    {
        var item = new Item(now + delay, order++, action);
        lock (items)
        {
            items.Add(item);
        }
        return () => item.Canceled = true;
    }

    // The count of actions that wait and are not canceled.
    public int Pending
    {
        get
        {
            lock (items)
            {
                return items.Count(i => !i.Canceled);
            }
        }
    }

    public void Advance(TimeSpan by)
    {
        var end = now + by;
        while (true)
        {
            Item? next;
            lock (items)
            {
                next = items.Where(i => i.At <= end).OrderBy(i => i.At).ThenBy(i => i.Order).FirstOrDefault();
                if (next is not null)
                {
                    items.Remove(next);
                }
            }
            if (next is null)
            {
                break;
            }
            now = next.At;
            if (!next.Canceled)
            {
                next.Action();
            }
        }
        now = end;
    }
}

// Records the notifications that the plugin shows.
internal sealed class HerdrNotifications : INotificationBackend
{
    public ConcurrentQueue<SystemNotification> Shown { get; } = new();
    public ConcurrentQueue<string> Removed { get; } = new();

    public void Show(SystemNotification notification, IReadOnlyList<NotificationAction> actions) => Shown.Enqueue(notification);
    public void Remove(string id) => Removed.Enqueue(id);
}

// The timers, the notifications, the agent screen, and the replies of the
// plugin, with a manual clock and a recorded link.
public class HerdrPluginTests
{
    static Packet Msg(string json) => Packet.Parse($$"""{"id":1,"type":"flux.herdr","body":{{json}}}""")!;

    static Packet State(string status, string pane = "w1:p1", string title = "Fix the test") =>
        Msg($$"""
            {"kind":"state","enabled":true,"running":true,"control":true,
             "agents":[{"pane":"{{pane}}","agent":"claude","status":"{{status}}","title":"{{title}}","project":"flux","workspace":"flux"}]}
            """);

    // A plugin with a manual clock that records the packets that it sends.
    sealed class Rig
    {
        public HerdrPlugin Plugin { get; } = new();
        public HerdrTimers Timers { get; } = new();
        public ConcurrentQueue<(Packet Packet, string Device)> Sent { get; } = new();
        public bool Online { get; set; } = true;

        public Rig()
        {
            Plugin.After = Timers.After;
            Plugin.IsOnline = _ => Online;
            Plugin.Send = (p, id) =>
            {
                if (!Online)
                {
                    return false;
                }
                Sent.Enqueue((p, id));
                return true;
            };
        }

        public Packet[] Packets(string kind) => Sent.Select(s => s.Packet).Where(p => p.String("kind") == kind).ToArray();
    }

    static TestCore Core(HerdrPlugin plugin, HerdrNotifications shown)
    {
        var t = new TestCore(new LanConfig { LoopbackOnly = true }, [plugin]);
        t.Core.Host.Notifier.Backend = shown;
        return t;
    }

    [Fact]
    public void NotifiesWhenAnAgentNeedsInput()
    {
        var plugin = new HerdrPlugin();
        var shown = new HerdrNotifications();
        using var t = Core(plugin, shown);
        plugin.After = new HerdrTimers().After;
        plugin.Receive(State("working"), "d", "omarchy");
        // The first list after a connection posts nothing.
        Assert.Empty(shown.Shown);
        plugin.Receive(State("blocked"), "d", "omarchy");
        var n = Assert.Single(shown.Shown);
        Assert.Equal("herdr-d-w1:p1", n.Id);
        Assert.Equal(HerdrPlugin.NotificationCategory, n.Category);
        Assert.Equal("claude in flux needs input", n.Title);
        Assert.Equal("omarchy\nFix the test", n.Body);
        Assert.Equal("d", n.UserInfo["device"]);
        Assert.Equal("w1:p1", n.UserInfo["pane"]);
        // Working again removes the notification.
        plugin.Receive(State("working"), "d", "omarchy");
        Assert.Contains("herdr-d-w1:p1", shown.Removed);
    }

    [Fact]
    public void AFinishedAgentWaitsForTheHold()
    {
        var plugin = new HerdrPlugin();
        var shown = new HerdrNotifications();
        using var t = Core(plugin, shown);
        var timers = new HerdrTimers();
        plugin.After = timers.After;
        plugin.Receive(State("working"), "d", "omarchy");
        plugin.Receive(State("done"), "d", "omarchy");
        timers.Advance(TimeSpan.FromSeconds(1.9));
        Assert.Empty(shown.Shown);
        timers.Advance(TimeSpan.FromSeconds(0.1));
        Assert.Equal("claude in flux finished", Assert.Single(shown.Shown).Title);

        // An agent that works again within the hold posts nothing.
        plugin.Receive(State("working"), "d", "omarchy");
        plugin.Receive(State("idle"), "d", "omarchy");
        plugin.Receive(State("working"), "d", "omarchy");
        timers.Advance(HerdrPlugin.FinishHold);
        Assert.Single(shown.Shown);
        Assert.Equal(0, timers.Pending);
    }

    [Fact]
    public void TheSettingsTurnTheNotificationsOff()
    {
        var plugin = new HerdrPlugin();
        var shown = new HerdrNotifications();
        using var t = Core(plugin, shown);
        var timers = new HerdrTimers();
        plugin.After = timers.After;
        plugin.Model.InputAlerts = false;
        plugin.Model.DoneAlerts = false;
        plugin.Receive(State("working"), "d", "omarchy");
        plugin.Receive(State("blocked"), "d", "omarchy");
        plugin.Receive(State("working"), "d", "omarchy");
        plugin.Receive(State("done"), "d", "omarchy");
        timers.Advance(HerdrPlugin.FinishHold);
        Assert.Empty(shown.Shown);
        // A finished agent without the setting removes its old notification.
        Assert.Contains("herdr-d-w1:p1", shown.Removed);
        // The settings stay for the next start.
        Assert.False(t.Core.Settings.Bool(HerdrPlugin.InputAlertsKey, true));
        Assert.False(t.Core.Settings.Bool(HerdrPlugin.DoneAlertsKey, true));
    }

    [Fact]
    public void TheDoneSettingAlsoCountsAtTheEndOfTheHold()
    {
        var plugin = new HerdrPlugin();
        var shown = new HerdrNotifications();
        using var t = Core(plugin, shown);
        var timers = new HerdrTimers();
        plugin.After = timers.After;
        plugin.Receive(State("working"), "d", "omarchy");
        plugin.Receive(State("done"), "d", "omarchy");
        plugin.Model.DoneAlerts = false;
        timers.Advance(HerdrPlugin.FinishHold);
        Assert.Empty(shown.Shown);
    }

    [Fact]
    public async Task AClickOnANotificationOpensTheAgent()
    {
        var plugin = new HerdrPlugin();
        var shown = new HerdrNotifications();
        using var t = Core(plugin, shown);
        var opened = new ConcurrentQueue<(string Device, string Pane)>();
        plugin.Model.Open = (id, pane) => opened.Enqueue((id, pane));
        plugin.Receive(Msg(HerdrControlTests.SessionsState), "d", "omarchy");
        t.Core.Host.Notifier.Activate(HerdrPlugin.NotificationCategory, Notifier.DefaultAction,
            new Dictionary<string, string> { ["device"] = "d", ["pane"] = "omarchy/w2:p1" });
        await Wait.UntilAsync(() => !opened.IsEmpty, "the open of the agent");
        Assert.Equal(("d", "omarchy/w2:p1"), Assert.Single(opened));
        // The agent list shows the session of the agent.
        Assert.Equal("omarchy", plugin.Model.Session("d")?.Name);
    }

    [Fact]
    public void TheModelKeepsTheStatusTimes()
    {
        var plugin = new HerdrPlugin();
        plugin.Receive(State("working"), "d", "c");
        // The first list does not know when the status started.
        Assert.Null(plugin.Model.AgentSince("d", "w1:p1"));
        plugin.Receive(State("blocked"), "d", "c");
        Assert.NotNull(plugin.Model.AgentSince("d", "w1:p1"));
    }

    // Requests and their timeouts

    [Fact]
    public void AReadSendsItsNumberAndTakesOnlyItsAnswer()
    {
        var rig = new Rig();
        rig.Plugin.Read("d", "w1:p1");
        var read = Assert.Single(rig.Packets("read"));
        HerdrTests.AssertBody("""{"kind":"read","pane":"w1:p1","format":"ansi","path":"","request":1,"lines":1000}""", read);
        Assert.True(rig.Plugin.Model.Outputs["d"].Loading);
        // The answer to an older read does not show.
        rig.Plugin.Show(new HerdrOutput("w1:p1", false, [new TermLine([new TermSpan("old")])], request: 0), "d", 0, null);
        Assert.True(rig.Plugin.Model.Outputs["d"].Loading);
    }

    [Fact]
    public async Task AReadShowsItsAnswer()
    {
        var rig = new Rig();
        rig.Plugin.Read("d", "w1:p1");
        rig.Plugin.Receive(Msg("""{"kind":"output","pane":"w1:p1","format":"ansi","view":"ansi","path":"","request":1,"text":"new"}"""), "d", "c");
        await Wait.UntilAsync(() => !rig.Plugin.Model.Outputs["d"].Loading, "the parse of the output");
        Assert.Equal("new", rig.Plugin.Model.Outputs["d"].Text);
        Assert.Equal(1, rig.Plugin.Model.Outputs["d"].Request);
    }

    [Fact]
    public void AReadWithoutAnAnswerFailsAfter15Seconds()
    {
        var rig = new Rig();
        rig.Plugin.Read("d", "w1:p1");
        rig.Timers.Advance(HerdrPlugin.ReadTimeout - TimeSpan.FromMilliseconds(1));
        Assert.True(rig.Plugin.Model.Outputs["d"].Loading);
        rig.Timers.Advance(TimeSpan.FromMilliseconds(1));
        Assert.False(rig.Plugin.Model.Outputs["d"].Loading);
        Assert.Equal("The computer did not answer", rig.Plugin.Model.Outputs["d"].Error);
    }

    [Fact]
    public void AReviewReadsTheDiffAndMarksTheFeedback()
    {
        var rig = new Rig();
        rig.Plugin.Read("d", "w1:p1", review: true, path: "src/a.go");
        HerdrTests.AssertBody("""{"kind":"read","pane":"w1:p1","format":"diff","path":"src/a.go","request":1,"lines":1000}""",
            Assert.Single(rig.Packets("read")));
        rig.Plugin.SendPrompt("d", "w1:p1", "Rename the function");
        Assert.Equal("Review feedback for src/a.go:\nRename the function", rig.Packets("prompt")[0].String("text"));
        rig.Plugin.SendPrompt("d", "w1:p1", "Go on", feedback: false);
        Assert.Equal("Go on", rig.Packets("prompt")[1].String("text"));
        rig.Plugin.Read("d", "w1:p1", review: true);
        rig.Plugin.SendPrompt("d", "w1:p1", "Split it");
        Assert.Equal("Review feedback for the working tree:\nSplit it", rig.Packets("prompt")[2].String("text"));
        rig.Plugin.Read("d", "w1:p1", review: false);
        Assert.Equal("ansi", rig.Packets("read")[^1].String("format"));
        rig.Plugin.SendPrompt("d", "w1:p1", "Thanks");
        Assert.Equal("Thanks", rig.Packets("prompt")[3].String("text"));
    }

    [Fact]
    public void AReplyWithoutAnAnswerFailsAfter10Seconds()
    {
        var rig = new Rig();
        rig.Plugin.SendKeys("d", "w1:p1", ["2"]);
        HerdrTests.AssertBody("""{"kind":"keys","pane":"w1:p1","keys":["2"],"request":1}""", Assert.Single(rig.Packets("keys")));
        Assert.True(rig.Plugin.Model.Replies["d"].Sending);
        rig.Timers.Advance(HerdrPlugin.ReplyTimeout);
        Assert.Equal(new HerdrReply("w1:p1", "keys", 1, false, "The computer did not answer"), rig.Plugin.Model.Replies["d"]);
    }

    [Fact]
    public void ASentReplyReadsTheOutputAgain()
    {
        var rig = new Rig();
        rig.Plugin.Read("d", "w1:p1");
        rig.Plugin.ReadPrompt("d", "w1:p1");
        rig.Plugin.SendPrompt("d", "w1:p1", "go on");
        var request = rig.Packets("prompt")[0].Int("request");
        rig.Plugin.Receive(Msg($$"""{"kind":"sent","pane":"w1:p1","action":"prompt","request":{{request}}}"""), "d", "c");
        Assert.False(rig.Plugin.Model.Replies["d"].Sending);
        Assert.Null(rig.Plugin.Model.Replies["d"].Error);
        Assert.Equal(2, rig.Packets("read").Length);
        rig.Timers.Advance(HerdrPlugin.RereadDelay);
        // The agent screen and the prompt of the Inbox read again.
        Assert.Equal(4, rig.Packets("read").Length);
    }

    [Fact]
    public void ACreateWithoutAnAnswerFailsAfter60Seconds()
    {
        var rig = new Rig();
        rig.Plugin.Create("d", "agent", "claude", "~/Code/flux", "", "Run the tests", "omarchy");
        HerdrTests.AssertBody("""
            {"kind":"create","what":"agent","agent":"claude","cwd":"~/Code/flux","workspace":"","herdr_session":"omarchy","request":1}
            """, Assert.Single(rig.Packets("create")));
        rig.Timers.Advance(HerdrPlugin.CreateTimeout - TimeSpan.FromSeconds(1));
        Assert.True(rig.Plugin.Model.Actions["d"].Sending);
        rig.Timers.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal("The computer did not answer", rig.Plugin.Model.Actions["d"].Error);
        Assert.Equal(FirstTaskPhase.Failed("The computer did not answer"), rig.Plugin.Model.FirstTasks["d"].Phase);
    }

    [Fact]
    public void ACloseWithoutAnAnswerFailsAfter10Seconds()
    {
        var rig = new Rig();
        rig.Plugin.Close("d", "w1:p1");
        HerdrTests.AssertBody("""{"kind":"close","pane":"w1:p1","request":1}""", Assert.Single(rig.Packets("close")));
        rig.Timers.Advance(HerdrPlugin.CloseTimeout);
        Assert.Equal("The computer did not answer", rig.Plugin.Model.Actions["d"].Error);
    }

    [Fact]
    public void TheFirstTaskGoesAsAPromptWhenTheAgentIsReady()
    {
        var rig = new Rig();
        double clock = 10;
        rig.Plugin.Clock = () => clock;
        rig.Plugin.Create("d", "agent", "claude", "~", "", " Reply with ok ");
        rig.Plugin.Receive(State("idle", "w4:p1"), "d", "c");
        rig.Plugin.Receive(Msg("""{"kind":"created","what":"agent","pane":"w4:p1","request":1}"""), "d", "c");
        Assert.Equal(FirstTaskPhase.Waiting, rig.Plugin.Model.FirstTasks["d"].Phase);
        Assert.Empty(rig.Packets("prompt"));
        clock += FirstTask.Hold + 0.05;
        rig.Timers.Advance(TimeSpan.FromSeconds(FirstTask.Hold + 0.05));
        var prompt = Assert.Single(rig.Packets("prompt"));
        HerdrTests.AssertBody("""{"kind":"prompt","pane":"w4:p1","text":"Reply with ok","request":1}""", prompt);
        Assert.Equal(FirstTaskPhase.Sending, rig.Plugin.Model.FirstTasks["d"].Phase);
        rig.Plugin.Receive(Msg("""{"kind":"sent","pane":"w4:p1","action":"prompt","request":1}"""), "d", "c");
        Assert.Equal(FirstTaskPhase.Sent, rig.Plugin.Model.FirstTasks["d"].Phase);
    }

    [Fact]
    public void TellRejectsAndSendsTheTextWhenTheAgentLeavesTheDialog()
    {
        var rig = new Rig();
        rig.Plugin.Receive(State("blocked"), "d", "c");
        rig.Plugin.Tell("d", "w1:p1", ["3"], "Use git clean");
        Assert.Single(rig.Packets("keys"));
        rig.Timers.Advance(HerdrPlugin.TellStep * 3);
        // The agent still waits, so the text waits.
        Assert.Empty(rig.Packets("prompt"));
        rig.Plugin.Receive(State("working"), "d", "c");
        rig.Timers.Advance(HerdrPlugin.TellStep);
        Assert.Equal("Use git clean", Assert.Single(rig.Packets("prompt")).String("text"));
    }

    [Fact]
    public void TellSendsTheTextAfterTheWait()
    {
        var rig = new Rig();
        rig.Plugin.Receive(State("blocked"), "d", "c");
        rig.Plugin.Read("d", "w1:p1", review: true);
        rig.Plugin.Tell("d", "w1:p1", ["3"], "Use git clean");
        rig.Timers.Advance(HerdrPlugin.TellWait - HerdrPlugin.TellStep);
        Assert.Empty(rig.Packets("prompt"));
        rig.Timers.Advance(HerdrPlugin.TellStep);
        // The reply answers the agent, not a review of its changes.
        Assert.Equal("Use git clean", Assert.Single(rig.Packets("prompt")).String("text"));
    }

    // The agent screen

    [Fact]
    public void TheAgentScreenPollsEvery5SecondsWhileTheAgentWorks()
    {
        var rig = new Rig();
        rig.Plugin.Receive(State("working"), "d", "c");
        rig.Plugin.Watch("d", "w1:p1");
        Assert.Single(rig.Packets("read"));
        // A second call with the same pane changes nothing.
        rig.Plugin.Watch("d", "w1:p1");
        Assert.Single(rig.Packets("read"));
        // A poll waits while the last read did not end.
        rig.Timers.Advance(HerdrPlugin.WorkingRefresh);
        Assert.Single(rig.Packets("read"));
        rig.Plugin.Model.Outputs = rig.Plugin.Model.Outputs.SetItem("d", rig.Plugin.Model.Outputs["d"] with { Loading = false });
        rig.Timers.Advance(HerdrPlugin.WorkingRefresh);
        Assert.Equal(2, rig.Packets("read").Length);
        // A new status reads at once, and an idle agent has no poll.
        rig.Plugin.Receive(State("idle"), "d", "c");
        Assert.Equal(3, rig.Packets("read").Length);
        rig.Plugin.Model.Outputs = rig.Plugin.Model.Outputs.SetItem("d", rig.Plugin.Model.Outputs["d"] with { Loading = false });
        rig.Timers.Advance(HerdrPlugin.WorkingRefresh * 3);
        Assert.Equal(3, rig.Packets("read").Length);
        // A state with the same status reads nothing.
        rig.Plugin.Receive(State("idle"), "d", "c");
        Assert.Equal(3, rig.Packets("read").Length);
    }

    [Fact]
    public void TheAgentScreenReadsTheReviewAndStopsOnUnwatch()
    {
        var rig = new Rig();
        rig.Plugin.Receive(State("working"), "d", "c");
        rig.Plugin.Watch("d", "w1:p1");
        rig.Plugin.Watch("d", "w1:p1", review: true);
        Assert.Equal("diff", rig.Packets("read")[^1].String("format"));
        rig.Plugin.Unwatch("d", "w1:p1");
        Assert.False(rig.Plugin.Model.Outputs.ContainsKey("d"));
        rig.Timers.Advance(HerdrPlugin.WorkingRefresh * 2);
        Assert.Equal(2, rig.Packets("read").Length);
    }

    [Fact]
    public void TheAgentScreenWaitsForTheLinkAndTheAgent()
    {
        var rig = new Rig { Online = false };
        rig.Plugin.Receive(State("working"), "d", "c");
        rig.Plugin.Watch("d", "w1:p1");
        // No link: no read.
        Assert.Empty(rig.Packets("read"));
        Assert.False(rig.Plugin.Model.Outputs.ContainsKey("d"));
        rig.Online = true;
        rig.Plugin.Watch("d", "w9:p9");
        // No agent in the pane: no read.
        Assert.Empty(rig.Packets("read"));
        rig.Plugin.Receive(State("working", "w9:p9"), "d", "c");
        // The agent appears, so the screen reads.
        Assert.Single(rig.Packets("read"));
    }
}
