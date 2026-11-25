using FluxKit;

namespace FluxKit.Tests;

// Ported from ChatTests.swift of the Mac app and ChatFeedTest.kt of the
// Android app.
public class ChatTests
{
    static DateTimeOffset At(double s) => DateTimeOffset.UnixEpoch.AddSeconds(s);

    static readonly HerdrAgent Blocked = new("w2:p1", "codex", AgentStatus.Blocked, "Migrate");
    static readonly HerdrAgent Done = new("w3:p1", "claude", AgentStatus.Done, "Fix test");

    static IReadOnlyDictionary<string, DateTimeOffset> Seen(params (string Key, DateTimeOffset At)[] times) =>
        times.ToDictionary(t => t.Key, t => t.At);

    [Fact]
    public void TheEntriesAreInTimeOrder()
    {
        var ask = new InboxItem(new InboxContent.Agent("pc", Blocked, true), "omarchy-xps");
        var fin = new InboxItem(new InboxContent.Agent("pc", Done, true), "omarchy-xps");
        var pair = new InboxItem(new InboxContent.Pair("new"), "framework-13");
        var link = new SentItem("pc", SentKind.Link, "https://omarchy.org", At(50));
        var file = new FileTransfer { DeviceId = "pc", Name = "invoice.pdf", Incoming = true, Size = 10, Started = At(200) };
        var since = new Dictionary<string, DateTimeOffset> { ["w2:p1"] = At(300), ["w3:p1"] = At(100) };
        var chat = Chat.Entries([link], [file], null, [], [ask, fin, pair], (_, pane) => since.TryGetValue(pane, out var t) ? t : null,
            Seen((pair.Key, At(250))));
        Assert.Equal(["sent|" + link.Id, fin.Key, "file|" + file.Id, pair.Key, ask.Key], chat.Select(e => e.Id));
        Assert.Equal(At(300), chat[^1].At);
    }

    [Fact]
    public void AnAgentWithNoStartTakesTheTimeThatTheChatSawIt()
    {
        var ask = new InboxItem(new InboxContent.Agent("pc", Blocked, true), "omarchy-xps");
        var link = new SentItem("pc", SentKind.Link, "https://omarchy.org", At(500));
        var chat = Chat.Entries([link], [], null, [], [ask], (_, _) => null, Seen((ask.Key, At(400))));
        Assert.Equal(ask.Key, chat[0].Id);
    }

    [Fact]
    public void AnItemThatTheChatDidNotSeeGoesFirst()
    {
        var pair = new InboxItem(new InboxContent.Pair("new"), "framework-13");
        var link = new SentItem("pc", SentKind.Link, "https://omarchy.org", At(5));
        var chat = Chat.Entries([link], [], null, [], [pair], (_, _) => null, Seen());
        Assert.Equal([pair.Key, "sent|" + link.Id], chat.Select(e => e.Id));
    }

    [Fact]
    public void OnlyAClipFromAComputerShows()
    {
        var sentClip = new ClipEvent(ValueList.From(["pc"]), "omarchy-xps", true, "out", false, At(10));
        // A clip that went out is a sent item already.
        Assert.Empty(Chat.Entries([], [], sentClip, [], [], (_, _) => null, Seen()));
        var received = ClipEvent.ReceivedFrom("pc", "omarchy-xps", "git push", At(20));
        var chat = Chat.Entries([], [], received, [], [], (_, _) => null, Seen());
        Assert.Equal(["clip"], chat.Select(e => e.Id));
        Assert.Equal(At(20), chat[0].At);
    }

    static ApproveRequest Request(string computer) =>
        new(computer, "name-" + computer, "r1", ApproveKind.Approve, "host", "dev", "sudo", "pts/3", "", 0, new string('0', 64), 60);

    static ApproveRecord Record(string requestId, ApproveOutcome outcome, double received, double? resolved, ApproveRequest? request = null) =>
        new(Guid.NewGuid(), requestId, "pc", ApproveKind.Approve, "", At(received), outcome, request, resolved is { } r ? At(r) : null);

    // Only the approved, enrolled, and denied answers with an end time show.
    // An answer takes the time that it ended.
    [Fact]
    public void OnlyTheEndedAnswersShow()
    {
        var received = ClipEvent.ReceivedFrom("pc", "omarchy-xps", "git push", At(20));
        var approved = Record("r1", ApproveOutcome.Approved, 30, 40, Request("pc"));
        var open = Record("r2", ApproveOutcome.Open, 35, null);
        var expired = Record("r3", ApproveOutcome.Expired, 36, 37);
        var failed = Record("r4", ApproveOutcome.Failed("no"), 38, 39);
        var chat = Chat.Entries([], [], received, [approved, open, expired, failed], [], (_, _) => null, Seen());
        Assert.Equal(["clip", "answer|" + approved.Id], chat.Select(e => e.Id));
        Assert.Equal(At(40), chat[^1].At);
        var enrolled = Record("r5", ApproveOutcome.Enrolled, 50, 51);
        var denied = Record("r6", ApproveOutcome.Denied, 52, 53);
        Assert.Equal(2, Chat.Entries([], [], null, [enrolled, denied], [], (_, _) => null, Seen()).Count);
    }

    // An answer shows in the scope of its computer only.
    [Fact]
    public void AnAnswerShowsInTheScopeOfItsComputer()
    {
        var approved = Record("r1", ApproveOutcome.Approved, 30, 40, Request("pc"));
        Assert.Single(Chat.Entries([], [], null, [approved], [], (_, _) => null, Seen(), "pc"));
        Assert.Empty(Chat.Entries([], [], null, [approved], [], (_, _) => null, Seen(), "desk"));
    }

    // The open request is an Inbox item that takes the time that the chat
    // saw it, and it shows in the scope of its computer.
    [Fact]
    public void TheOpenApprovalIsAnEvent()
    {
        var ask = new InboxItem(new InboxContent.Approval(Request("pc")), "name-pc");
        var link = new SentItem("pc", SentKind.Link, "https://omarchy.org", At(5));
        var chat = Chat.Entries([link], [], null, [], [ask], (_, _) => null, Seen((ask.Key, At(9))), "pc");
        Assert.Equal(["sent|" + link.Id, "approve|pc|r1"], chat.Select(e => e.Id));
        Assert.Empty(Chat.Entries([], [], null, [], [ask], (_, _) => null, Seen((ask.Key, At(9))), "desk"));
    }

    [Fact]
    public void TheScopeKeepsItsComputerAndThePairRequests()
    {
        var pair = new InboxItem(new InboxContent.Pair("new"), "framework-13");
        var desk = new SentItem("desk", SentKind.Text, "hello", At(1));
        var pc = new SentItem("pc", SentKind.Text, "hello", At(2));
        var deskFile = new FileTransfer { DeviceId = "desk", Name = "a.txt", Started = At(4) };
        var deskClip = ClipEvent.ReceivedFrom("desk", "desk", "x", At(5));
        var chat = Chat.Entries([desk, pc], [deskFile], deskClip, [], [pair], (_, _) => null, Seen((pair.Key, At(3))), "pc");
        Assert.Equal(["sent|" + pc.Id, pair.Key], chat.Select(e => e.Id));
    }

    // The times of a clock as sorted pairs, so that 2 dictionaries compare by their content.
    static string[] Times(IReadOnlyDictionary<string, DateTimeOffset> times) =>
        times.OrderBy(e => e.Key, StringComparer.Ordinal).Select(e => $"{e.Key}={e.Value.ToUnixTimeSeconds()}").ToArray();

    [Fact]
    public void TheClockKeepsTheFirstTimeAndForgetsWhatIsGoneForLong()
    {
        var clock = new SeenClock(TimeSpan.FromSeconds(100));
        Assert.Equal(["a=10"], Times(clock.Update(["a"], At(10))));
        Assert.Equal(["a=10", "b=20"], Times(clock.Update(["a", "b"], At(20))));
        Assert.Equal(["b=20"], Times(clock.Update(["b"], At(30))));
        // An item that comes back soon keeps its time.
        Assert.Equal(["a=10", "b=20"], Times(clock.Update(["a", "b"], At(40))));
        clock.Update(["b"], At(100));
        // An item that is gone for long is new.
        Assert.Equal(["a=201", "b=20"], Times(clock.Update(["a", "b"], At(201))));
        // An item that stays keeps its time without updates.
        Assert.Equal(["a=201", "b=20"], Times(clock.Update(["a", "b"], At(9_999))));
        Assert.Equal(TimeSpan.FromMinutes(10), new SeenClock().Grace);
    }

    [Fact]
    public void ATellChoiceOpensAReply()
    {
        Assert.True(Chat.IsTellChoice(new AgentChoice("3", "No, and tell Codex what to do differently (esc)")));
        Assert.True(Chat.IsTellChoice(new AgentChoice("3", "No, and tell Claude what to do differently")));
        Assert.True(Chat.IsTellChoice(new AgentChoice("3", "No, and TELL Claude what to do DIFFERENTLY")));
        Assert.False(Chat.IsTellChoice(new AgentChoice("1", "Yes")));
        Assert.False(Chat.IsTellChoice(new AgentChoice("2", "Yes, and do not ask again for bin/migrate commands")));
        Assert.False(Chat.IsTellChoice(new AgentChoice("2", "No, tell nobody, do it indifferently")));
    }
}
