using FluxKit;

namespace FluxKit.Tests;

// Ported from ChatListTests.swift of the Mac app and ChatListTest.kt of the
// Android app.
public class ChatListTests
{
    static DateTimeOffset At(double s) => DateTimeOffset.UnixEpoch.AddSeconds(s);

    static DeviceSnapshot Device(string id, string name, bool paired = true, bool online = true, PairState pairState = PairState.Paired) =>
        new(id, name, "laptop", "", true, paired, online, paired ? PairState.Paired : pairState, "", ValueList<string>.Empty, ValueList<string>.Empty);

    static readonly HerdrAgent Migrate = new("w2:p1", "codex", AgentStatus.Blocked, "Run the database migration", "billing");
    static readonly HerdrAgent Refactor = new("w1:p1", "claude", AgentStatus.Working, "Refactor the sync loop", "flux");
    static readonly HerdrAgent Flaky = new("w3:p1", "claude", AgentStatus.Done, "Fix the flaky login test", "web");
    static readonly HerdrAgent Idle = new("w3:p2", "pi", AgentStatus.Idle, Project: "web");

    static HerdrState Herdr(params HerdrAgent[] agents) => new(true, true, agents, control: true);

    static ApproveRequest Approval(string computer, long time = 0) =>
        new(computer, computer, "r1", ApproveKind.Approve, computer, "dev", "sudo", "pts/3", "", time, new string('0', 64), 60);

    static ChatEntry Text(string device, string text, double s) => new ChatEntry.Sent(new SentItem(device, SentKind.Text, text, At(s)));

    static string[] Ids(IEnumerable<ChatRow> rows) => rows.Select(r => r.Id).ToArray();

    static Func<string, string, DateTimeOffset?> NoSince => (_, _) => null;

    [Fact]
    public void TheAgentsThatWaitAndTheApprovalAreOnTop()
    {
        var pc = Device("pc", "omarchy-xps");
        var since = new Dictionary<string, DateTimeOffset> { ["w2:p1"] = At(5_000), ["w1:p1"] = At(100), ["w3:p1"] = At(200) };
        var list = Chats.List([pc], new Dictionary<string, HerdrState> { ["pc"] = Herdr(Refactor, Migrate, Flaky, Idle) }, Approval("pc", 1),
            [], (_, pane) => since.TryGetValue(pane, out var t) ? t : null, new SeenClock(), At(9_000));
        // The newest first.
        Assert.Equal(["agent|pc|w2:p1", "approve|pc|r1"], Ids(list.Needs));
        // An approval takes the time of its request.
        Assert.Equal(At(1), list.Needs[^1].At);
        // The agents that work come first, then the agents that are done.
        Assert.Equal(["agent|pc|w1:p1", "agent|pc|w3:p1", "agent|pc|w3:p2"], Ids(list.Agents));
    }

    [Fact]
    public void AnAgentWithNoStartTakesTheTimeThatTheListSawIt()
    {
        var pc = Device("pc", "omarchy-xps");
        var clock = new SeenClock();
        DateTimeOffset? AgentAt(HerdrAgent agent, double now) =>
            Chats.List([pc], new Dictionary<string, HerdrState> { ["pc"] = Herdr(agent) }, null, [], NoSince, clock, At(now)).Agents.FirstOrDefault()?.At;
        Assert.Equal(At(10), AgentAt(Flaky, 10));
        Assert.Equal(At(10), AgentAt(Flaky, 99));
        // A new status is new.
        Assert.Equal(At(120), AgentAt(Flaky with { Status = AgentStatus.Working }, 120));
    }

    [Fact]
    public void AComputerThatIsNotReachableAddsNoAgents()
    {
        var desk = Device("desk", "omarchy-desk", online: false);
        var list = Chats.List([desk], new Dictionary<string, HerdrState> { ["desk"] = Herdr(Migrate) }, null, [], NoSince, new SeenClock(), At(1));
        Assert.Empty(list.Needs);
        Assert.Empty(list.Agents);
        Assert.Equal(["computer|desk"], Ids(list.Computers));
    }

    [Fact]
    public void EachComputerShowsItsNewestEntryAndTheOnlineComputersComeFirst()
    {
        var pc = Device("pc", "omarchy-xps");
        var desk = Device("desk", "omarchy-desk", online: false);
        var other = Device("other", "work-thinkpad");
        var file = new ChatEntry.File(new FileTransfer { DeviceId = "pc", Name = "invoice.pdf", Incoming = true, Size = 10, State = TransferState.Done, Started = At(50) });
        ChatEntry[] log = [Text("pc", "Dinner at 7", 100), file, Text("desk", "notes", 900)];
        var list = Chats.List([desk, other, pc], new Dictionary<string, HerdrState>(), null, log, NoSince, new SeenClock(), At(1_000));
        Assert.Equal(["computer|pc", "computer|other", "computer|desk"], Ids(list.Computers));
        var last = Assert.IsType<ChatRow.Computer>(list.Computers[0]).Last;
        var none = Assert.IsType<ChatRow.Computer>(list.Computers[1]).Last;
        Assert.Equal("You: Dinner at 7", last?.Preview());
        Assert.Null(none);
        Assert.Equal("invoice.pdf", file.Preview());
    }

    [Fact]
    public void APairRequestNeedsTheUserAndAnApprovalOfAnotherComputerDoesNotShow()
    {
        var pc = Device("pc", "omarchy-xps");
        var asking = Device("new", "framework-13", paired: false, pairState: PairState.Incoming);
        var list = Chats.List([pc, asking], new Dictionary<string, HerdrState>(), Approval("gone"), [], NoSince, new SeenClock(), At(1));
        Assert.Equal(["pair|new"], Ids(list.Needs));
        Assert.Equal(["computer|pc"], Ids(list.Computers));
    }

    [Fact]
    public void TheSearchKeepsTheRowsThatHoldItAndShowsTheEntryThatMatches()
    {
        var pc = Device("pc", "omarchy-xps");
        var desk = Device("desk", "omarchy-desk");
        var file = new ChatEntry.File(new FileTransfer { DeviceId = "pc", Name = "invoice-0042.pdf", Incoming = true, Size = 10, State = TransferState.Done, Started = At(10) });
        ChatEntry[] log = [file, Text("pc", "Dinner at 7", 20), Text("desk", "notes", 30)];
        var state = new Dictionary<string, HerdrState> { ["pc"] = Herdr(Migrate, Flaky) };
        var clock = new SeenClock();
        var byFile = Chats.List([pc, desk], state, null, log, NoSince, clock, At(100), "INVOICE");
        Assert.Empty(byFile.Needs);
        Assert.Empty(byFile.Agents);
        Assert.Equal(["computer|pc"], Ids(byFile.Computers));
        Assert.Equal("invoice-0042.pdf", Assert.IsType<ChatRow.Computer>(byFile.Computers[0]).Last?.Text());
        var byProject = Chats.List([pc, desk], state, null, log, NoSince, clock, At(100), "billing");
        Assert.Equal(["agent|pc|w2:p1"], Ids(byProject.Needs));
        var byName = Chats.List([pc, desk], state, null, log, NoSince, clock, At(100), "desk");
        // A computer that matches by name shows its newest entry.
        Assert.Equal("notes", Assert.IsType<ChatRow.Computer>(byName.Computers[0]).Last?.Text());
    }

    // The previews of the other entries: a file that goes out, a clip, and the answers.
    [Fact]
    public void ThePreviewNamesWhatTheEntryIs()
    {
        var sending = new ChatEntry.File(new FileTransfer { DeviceId = "pc", Name = "a.txt", Started = At(1) });
        var failed = new ChatEntry.File(new FileTransfer { DeviceId = "pc", Name = "a.txt", State = TransferState.Failed, Started = At(1) });
        var receiving = new ChatEntry.File(new FileTransfer { DeviceId = "pc", Name = "b.txt", Incoming = true, Started = At(1) });
        var clip = new ChatEntry.Clip(ClipEvent.ReceivedFrom("pc", "omarchy-xps", "git push\norigin", At(2)));
        var request = Approval("pc");
        var approved = new ChatEntry.Answer(new ApproveRecord(Guid.NewGuid(), "r1", "pc", ApproveKind.Approve, "", At(3), ApproveOutcome.Approved, request, At(4)));
        var denied = new ChatEntry.Answer(new ApproveRecord(Guid.NewGuid(), "r2", "pc", ApproveKind.Approve, "", At(3), ApproveOutcome.Denied, request, At(4)));
        Assert.Equal("You: sending a.txt", sending.Preview());
        Assert.Equal("You: not sent, a.txt", failed.Preview());
        Assert.Equal("Receiving b.txt", receiving.Preview());
        Assert.Equal("Clipboard: git push origin", clip.Preview());
        Assert.Equal("Approved sudo", approved.Preview());
        Assert.Equal("Denied sudo", denied.Preview());
        Assert.Equal("You: an image", new ChatEntry.Sent(new SentItem("pc", SentKind.ClipImage, "", At(5))).Preview());
    }
}
