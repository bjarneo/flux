using System.Collections.Concurrent;
using System.Text.Json;
using FluxKit;

namespace FluxKit.Tests;

// A notification backend that keeps the buttons of each notification.
internal sealed class ActionNotifications : INotificationBackend
{
    public ConcurrentQueue<(SystemNotification Notice, IReadOnlyList<NotificationAction> Actions)> Shown { get; } = new();
    public ConcurrentQueue<string> Removed { get; } = new();

    public void Show(SystemNotification notification, IReadOnlyList<NotificationAction> actions) => Shown.Enqueue((notification, actions));
    public void Remove(string id) => Removed.Enqueue(id);

    public (SystemNotification Notice, IReadOnlyList<NotificationAction> Actions) Last => Shown.Last();
}

// The dialog of a blocked agent, the notification with its buttons, and the
// answer from a button. They cover AC84 to AC88 for Windows, with a recorded
// link and a manual clock. HerdrEndToEndTests runs the same path against fluxd.
public class AgentNotificationTests
{
    const string Three = "Bash command\n\n   bin/migrate --apply\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, always\n   3. No\n";
    const string Changed = "Bash command\n\n   bin/migrate --rollback\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n";
    const string Four = "Bash command\n\n   bin/migrate --apply\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Always\n   3. No\n   4. Tell it what to do\n";
    const string Free = "I can migrate one.\n\n Which database should I migrate: staging or production?\n";

    static Packet Msg(string json) => Packet.Parse($$"""{"id":1,"type":"flux.herdr","body":{{json}}}""")!;

    static Packet State(string status, bool control = true) =>
        Msg($$"""
            {"kind":"state","enabled":true,"running":true,"control":{{(control ? "true" : "false")}},
             "agents":[{"pane":"w1:p1","agent":"claude","status":"{{status}}","title":"Fix the test","project":"flux","workspace":"flux"}]}
            """);

    sealed class Rig : IDisposable
    {
        public HerdrPlugin Plugin { get; } = new();
        public HerdrTimers Timers { get; } = new();
        public ActionNotifications Shown { get; } = new();
        public ConcurrentQueue<Packet> Sent { get; } = new();
        public ConcurrentQueue<(string Device, string Pane)> Opened { get; } = new();
        public bool Online { get; set; } = true;
        public int Unlocks { get; private set; }
        readonly TestCore core;

        public Rig()
        {
            Plugin.After = Timers.After;
            Plugin.IsOnline = _ => Online;
            Plugin.Send = (p, _) =>
            {
                if (!Online)
                {
                    return false;
                }
                Sent.Enqueue(p);
                return true;
            };
            core = new TestCore(new LanConfig { LoopbackOnly = true }, [Plugin]);
            core.Core.Host.Notifier.Backend = Shown;
            Plugin.Model.Open = (d, p) => Opened.Enqueue((d, p));
        }

        // The unlock of the app: it runs the action at once, or it fails.
        public void UnlockWith(bool valid) => Plugin.Unlock = (_, run, fail) =>
        {
            Unlocks++;
            if (valid)
            {
                run();
            }
            else
            {
                fail("The check failed.");
            }
        };

        public void Block(bool control = true)
        {
            Plugin.Receive(State("working", control), "d", "omarchy");
            Plugin.Receive(State("blocked", control), "d", "omarchy");
        }

        public Packet[] Packets(string kind) => Sent.Where(p => p.String("kind") == kind).ToArray();

        // The output of the last dialog read, as fluxd sends it.
        public Packet Output(string text, int? request = null)
        {
            var read = Packets("read").Last();
            var n = request ?? read.Int("request");
            var json = JsonSerializer.Serialize(text);
            return Msg($$"""{"kind":"output","pane":"w1:p1","format":"ansi","text":{{json}}{{(n is { } r ? $",\"request\":{r}" : "")}}}""");
        }

        public async Task AnswerReadAsync(string text, int expectedPosts)
        {
            Plugin.Receive(Output(text), "d", "omarchy");
            await Wait.UntilAsync(() => Shown.Shown.Count >= expectedPosts, "the notification with the dialog");
        }

        public void Activate(string action, string? reply = null)
        {
            var (n, _) = Shown.Last;
            core.Core.Host.Notifier.Activate(n.Category, action, n.UserInfo, reply);
        }

        public void Dispose() => core.Dispose();
    }

    // AC84
    [Fact]
    public async Task ABlockedAgentWithThreeChoicesPostsOneNoticeWithOneButtonEach()
    {
        using var rig = new Rig();
        rig.Block();
        // The first notice comes at once, with no buttons.
        var first = Assert.Single(rig.Shown.Shown);
        Assert.Empty(first.Actions);
        Assert.Equal("claude in flux needs input", first.Notice.Title);
        var read = Assert.Single(rig.Packets("read"));
        Assert.Equal(40, read.Int("lines"));
        Assert.NotNull(read.Int("request"));

        await rig.AnswerReadAsync(Three, 2);
        var (notice, actions) = rig.Shown.Last;
        Assert.Equal(first.Notice.Id, notice.Id);
        Assert.Equal("claude in flux needs input", notice.Title);
        Assert.Equal(["Yes", "Yes, always", "No"], actions.Select(a => a.Title));
        Assert.All(actions, a => Assert.False(a.TextInput));
        // The notice names the computer, the question, and the numbered choices.
        Assert.StartsWith("omarchy\n", notice.Body);
        Assert.Contains("Do you want to proceed?", notice.Body);
        Assert.Contains("2. Yes, always", notice.Body);
        Assert.Equal("d", notice.UserInfo["device"]);
        Assert.Equal("w1:p1", notice.UserInfo["pane"]);
        Assert.False(string.IsNullOrEmpty(notice.UserInfo["dialog"]));
    }

    // AC85
    [Fact]
    public async Task FourChoicesGiveNoButtonAndNoChoicesGiveReply()
    {
        using var four = new Rig();
        four.Block();
        await four.AnswerReadAsync(Four, 2);
        Assert.Empty(four.Shown.Last.Actions);
        Assert.Contains("4. Tell it what to do", four.Shown.Last.Notice.Body);

        using var free = new Rig();
        free.Block();
        await free.AnswerReadAsync(Free, 2);
        var (notice, actions) = free.Shown.Last;
        var reply = Assert.Single(actions);
        Assert.True(reply.TextInput);
        Assert.Equal("Reply", reply.Title);
        Assert.Equal("claude in flux asks a question", notice.Title);
    }

    // AC85: a sent reply reaches the agent input, as Send in the thread does.
    [Fact]
    public async Task AReplyGoesOutAsAnAnswerAfterTheUnlockAndANewRead()
    {
        using var rig = new Rig();
        rig.UnlockWith(true);
        rig.Block();
        await rig.AnswerReadAsync(Free, 2);
        rig.Activate("reply", " staging ");
        await WaitForReadsAsync(rig, 2);
        Assert.Empty(rig.Packets("prompt"));
        rig.Plugin.Receive(rig.Output(Free), "d", "omarchy");
        await Wait.UntilAsync(() => rig.Packets("prompt").Length == 1, "the answer");
        var prompt = rig.Packets("prompt")[0];
        Assert.Equal("staging", prompt.String("text"));
        Assert.True(prompt.Bool("answer"));
        Assert.Contains("herdr-d-w1:p1", rig.Shown.Removed);
    }

    // AC86
    [Fact]
    public void ControlOffGivesNoButtonAndEndsWithReadOnly()
    {
        using var rig = new Rig();
        rig.Block(control: false);
        var (notice, actions) = Assert.Single(rig.Shown.Shown);
        Assert.Empty(actions);
        Assert.EndsWith("Fix the test Read only", notice.Body);
        // No read goes out, because the notice has no button.
        Assert.Empty(rig.Packets("read"));
    }

    [Fact]
    public void AFinishedAgentGivesNoButton()
    {
        using var rig = new Rig();
        rig.Plugin.Receive(State("working"), "d", "omarchy");
        rig.Plugin.Receive(State("done"), "d", "omarchy");
        rig.Timers.Advance(HerdrPlugin.FinishHold);
        var (notice, actions) = Assert.Single(rig.Shown.Shown);
        Assert.Equal("claude in flux finished", notice.Title);
        Assert.Empty(actions);
        Assert.DoesNotContain("Read only", notice.Body);
    }

    // AC87
    [Fact]
    public async Task AChoiceSendsNothingBeforeTheUnlockSucceeds()
    {
        using var rig = new Rig();
        rig.UnlockWith(false);
        rig.Block();
        await rig.AnswerReadAsync(Three, 2);
        var reads = rig.Packets("read").Length;
        rig.Activate("choice:1");
        await Wait.UntilAsync(() => rig.Unlocks == 1, "the unlock");
        Assert.Empty(rig.Packets("keys"));
        // A failed unlock does not read the pane. The app opens the thread.
        Assert.Equal(reads, rig.Packets("read").Length);
        await Wait.UntilAsync(() => !rig.Opened.IsEmpty, "the thread");
    }

    [Fact]
    public async Task AChoiceWithNoUnlockInTheAppOpensTheThread()
    {
        using var rig = new Rig();
        rig.Block();
        await rig.AnswerReadAsync(Three, 2);
        rig.Activate("choice:2");
        await Wait.UntilAsync(() => !rig.Opened.IsEmpty, "the thread");
        Assert.Empty(rig.Packets("keys"));
    }

    [Fact]
    public async Task AChoiceSendsTheKeysOfTheNewReadAfterTheUnlock()
    {
        using var rig = new Rig();
        rig.UnlockWith(true);
        rig.Block();
        await rig.AnswerReadAsync(Three, 2);
        rig.Activate("choice:2");
        await WaitForReadsAsync(rig, 2);
        // The keys wait for the new read.
        Assert.Empty(rig.Packets("keys"));
        rig.Plugin.Receive(rig.Output(Three), "d", "omarchy");
        await Wait.UntilAsync(() => rig.Packets("keys").Length == 1, "the keys");
        Assert.Equal(["2"], rig.Packets("keys")[0].Body["keys"]!.AsArray().Select(k => (string)k!));
        Assert.Contains("herdr-d-w1:p1", rig.Shown.Removed);
        Assert.Empty(rig.Opened);
    }

    // AC88
    [Fact]
    public async Task AChangedQuestionSendsNothingAndOpensTheThread()
    {
        using var rig = new Rig();
        rig.UnlockWith(true);
        rig.Block();
        await rig.AnswerReadAsync(Three, 2);
        rig.Activate("choice:1");
        await WaitForReadsAsync(rig, 2);
        rig.Plugin.Receive(rig.Output(Changed), "d", "omarchy");
        await Wait.UntilAsync(() => !rig.Opened.IsEmpty, "the thread");
        Assert.Empty(rig.Packets("keys"));
        Assert.Equal(("d", "w1:p1"), rig.Opened.Single());
    }

    [Fact]
    public async Task AClosedLinkSendsNothingAndOpensTheThread()
    {
        using var rig = new Rig();
        rig.UnlockWith(true);
        rig.Block();
        await rig.AnswerReadAsync(Three, 2);
        rig.Online = false;
        rig.Activate("choice:1");
        await Wait.UntilAsync(() => !rig.Opened.IsEmpty, "the thread");
        Assert.Empty(rig.Packets("keys"));
    }

    [Fact]
    public async Task ASlowReadSendsNothingAndOpensTheThread()
    {
        using var rig = new Rig();
        rig.UnlockWith(true);
        rig.Block();
        await rig.AnswerReadAsync(Three, 2);
        rig.Activate("choice:1");
        await WaitForReadsAsync(rig, 2);
        rig.Timers.Advance(AgentDialogs.ReadTimeout);
        await Wait.UntilAsync(() => !rig.Opened.IsEmpty, "the thread");
        Assert.Empty(rig.Packets("keys"));
    }

    [Fact]
    public async Task AControlThatTurnedOffSendsNothing()
    {
        using var rig = new Rig();
        rig.UnlockWith(true);
        rig.Block();
        await rig.AnswerReadAsync(Three, 2);
        rig.Plugin.Receive(State("blocked", control: false), "d", "omarchy");
        rig.Activate("choice:1");
        await Wait.UntilAsync(() => !rig.Opened.IsEmpty, "the thread");
        Assert.Empty(rig.Packets("keys"));
        Assert.Equal(0, rig.Unlocks);
    }

    [Fact]
    public async Task AClickOnTheNoticeOpensTheThreadWithNoUnlock()
    {
        using var rig = new Rig();
        rig.UnlockWith(true);
        rig.Block();
        await rig.AnswerReadAsync(Three, 2);
        rig.Activate(Notifier.DefaultAction);
        await Wait.UntilAsync(() => !rig.Opened.IsEmpty, "the thread");
        Assert.Equal(0, rig.Unlocks);
        Assert.Empty(rig.Packets("keys"));
    }

    [Fact]
    public async Task AReadThatFailsKeepsTheFirstNoticeWithNoButton()
    {
        using var rig = new Rig();
        rig.Online = false;
        rig.Block();
        var (_, actions) = Assert.Single(rig.Shown.Shown);
        Assert.Empty(actions);
        await Task.Delay(50);
        Assert.Single(rig.Shown.Shown);
    }

    // The dialog reads: 1 read for each pane, and a joined second call.
    [Fact]
    public async Task ASecondPeekJoinsTheReadOfThePane()
    {
        using var rig = new Rig();
        rig.Plugin.Receive(State("blocked"), "d", "omarchy");
        var got = new ConcurrentQueue<AgentDialog?>();
        rig.Plugin.PeekDialog("d", "w1:p1", got.Enqueue);
        rig.Plugin.PeekDialog("d", "w1:p1", got.Enqueue);
        Assert.Single(rig.Packets("read"));
        rig.Plugin.Receive(rig.Output(Three), "d", "omarchy");
        await Wait.UntilAsync(() => got.Count == 2, "both answers");
        Assert.All(got, d => Assert.Equal("Do you want to proceed?", d!.Question));
        Assert.Equal(got.First()!.Id, rig.Plugin.LatestDialog("d", "w1:p1")!.Id);
        // A read of another request number is not the answer.
        rig.Plugin.PeekDialog("d", "w1:p1", got.Enqueue);
        rig.Plugin.Receive(rig.Output(Three, request: 9999), "d", "omarchy");
        await Task.Delay(50);
        Assert.Equal(2, got.Count);
    }

    // The dialog ID and the parse.
    [Fact]
    public void ParsesTheQuestionTheChoicesAndAnId()
    {
        static HerdrOutput Out(string text) => new("w2:p1", loading: false, lines: TermText.Lines(text));
        var d = AgentDialogs.Parse(Out(Three), DateTimeOffset.UnixEpoch)!;
        Assert.Equal("Do you want to proceed?", d.Question);
        Assert.Equal(["Yes", "Yes, always", "No"], d.Choices.Select(c => c.Label));
        Assert.Equal(16, d.Id.Length);
        Assert.Equal(d.Id, AgentDialogs.Parse(Out(Three), DateTimeOffset.UnixEpoch.AddSeconds(4))!.Id);
        Assert.NotEqual(d.Id, AgentDialogs.Parse(Out(Changed), DateTimeOffset.UnixEpoch)!.Id);
        Assert.Null(AgentDialogs.Parse(Out(Three) with { Error = "x" }, DateTimeOffset.UnixEpoch));
        var free = AgentDialogs.Parse(Out(Free), DateTimeOffset.UnixEpoch)!;
        Assert.Empty(free.Choices);
        Assert.Equal("Which database should I migrate: staging or production?", free.Question);
    }

    static async Task<int> WaitForReadsAsync(Rig rig, int count)
    {
        await Wait.UntilAsync(() => rig.Packets("read").Length >= count, "the new read of the pane");
        return rig.Packets("read").Length;
    }
}
