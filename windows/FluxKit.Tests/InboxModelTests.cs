using FluxKit;

namespace FluxKit.Tests;

// Ported from InboxModelTests.swift of the Mac app and InboxModelTest.kt of
// the Android app, plus the texts of the items.
public class InboxModelTests
{
    static DeviceSnapshot Device(string id, bool paired = true, bool online = true, PairState? pairState = null) =>
        new(id, "name-" + id, "laptop", "", true, paired, online, pairState ?? (paired ? PairState.Paired : PairState.None), "",
            ValueList<string>.Empty, ValueList<string>.Empty);

    static HerdrState Agents(params HerdrAgent[] list) => new(true, true, list, control: true);

    static IReadOnlyList<InboxItem> Items(IEnumerable<DeviceSnapshot> devices, Dictionary<string, HerdrState>? herdr = null) =>
        Inbox.Items(devices, herdr ?? []);

    static HerdrAgent? AgentOf(InboxItem item) => item.Content is InboxContent.Agent a ? a.Value : null;

    static ApproveRequest Approval(string computer) =>
        new(computer, "name-" + computer, "r1", ApproveKind.Approve, "host", "user", "sudo", "pts/1", "", 0, new string('0', 64), 60);

    static readonly HerdrAgent Working = new("w1:p1", "claude", AgentStatus.Working, "Refactor");
    static readonly HerdrAgent Blocked = new("w2:p1", "codex", AgentStatus.Blocked, "Migrate");
    static readonly HerdrAgent Done = new("w3:p1", "claude", AgentStatus.Done, "Fix test");
    static readonly HerdrAgent Idle = new("w3:p2", "pi", AgentStatus.Idle);

    [Fact]
    public void TheItemsAreTheAgentsAndThePairRequests()
    {
        var devices = new[] { Device("a"), Device("new", paired: false, pairState: PairState.Incoming) };
        var items = Items(devices, new() { ["a"] = Agents(Working, Blocked, Done, Idle) });
        Assert.Equal([InboxKind.AgentWorking, InboxKind.AgentInput, InboxKind.AgentDone, InboxKind.PairRequest], items.Select(i => i.Kind));
        // An idle agent is not news.
        Assert.DoesNotContain(items, i => AgentOf(i)?.Status == AgentStatus.Idle);
        Assert.Equal(2, Inbox.NeedsYou(items));
    }

    [Fact]
    public void TheItemsAreTheAgentsTheApprovalAndThePairRequests()
    {
        var devices = new[] { Device("a"), Device("new", paired: false, pairState: PairState.Incoming) };
        var items = Inbox.Items(devices, new Dictionary<string, HerdrState> { ["a"] = Agents(Working, Blocked, Done, Idle) }, Approval("a"));
        Assert.Equal([InboxKind.AgentWorking, InboxKind.AgentInput, InboxKind.AgentDone, InboxKind.PairRequest, InboxKind.Approval],
            items.Select(i => i.Kind));
        Assert.Equal(3, Inbox.NeedsYou(items));
        // The approval names its computer.
        Assert.Equal("name-a", items[^1].Computer);
    }

    // The items of a core take the open request of the approve plugin.
    [Fact]
    public void TheItemsOfACoreTakeTheOpenApproval()
    {
        using var t = new TestCore(SystemTestComputer.CoreLan(36745), [new ApprovePlugin()]);
        var plugin = t.Core.Plugin<ApprovePlugin>()!;
        Assert.Empty(Inbox.Items(t.Core, [Device("a")]));
        plugin.Model.Current = Approval("a");
        var item = Assert.Single(Inbox.Items(t.Core, [Device("a")]));
        Assert.Equal("approve|a|r1", item.Key);
        // The approval of a computer shows only in its scope.
        Assert.Empty(Inbox.InScope([item], "b"));
        Assert.Single(Inbox.InScope([item], "a"));
    }

    [Fact]
    public void AComputerThatIsNotReachableAddsNoAgents()
    {
        Assert.Empty(Items([Device("a", online: false)], new() { ["a"] = Agents(Blocked) }));
    }

    [Fact]
    public void AComputerWhereHerdrDoesNotRunAddsNoAgents()
    {
        Assert.Empty(Items([Device("a")], new() { ["a"] = new HerdrState(true, false, [Blocked], control: true) }));
    }

    [Fact]
    public void TwoAgentsOnOnePaneMakeOneItem()
    {
        var twin = Blocked with { Agent = "claude" };
        var items = Items([Device("a")], new() { ["a"] = Agents(Blocked, twin, Done) });
        Assert.Equal(items.Count, items.Select(i => i.Key).Distinct().Count());
        Assert.Equal(2, items.Count);
        Assert.Equal("codex", AgentOf(items[0])?.Agent);
    }

    [Fact]
    public void TheReachCountsThePairedComputersInScope()
    {
        var a = Device("a");
        var off = Device("off", online: false);
        var stranger = Device("new", paired: false);
        Assert.Equal(new InboxReach(1, ValueList.From([off])), Inbox.Reach(null, [a, off, stranger]));
        Assert.True(Inbox.Reach("off", [a, off]).NoneOnline);
        Assert.False(Inbox.Reach("a", [a, off]).NoneOnline);
        // No paired computer is not the same as none online.
        Assert.False(Inbox.Reach(null, [stranger]).NoneOnline);
    }

    [Fact]
    public void TheScopeKeepsItsComputerAndThePairRequests()
    {
        var devices = new[] { Device("a"), Device("b"), Device("new", paired: false, pairState: PairState.Incoming) };
        var items = Items(devices, new() { ["a"] = Agents(Blocked), ["b"] = Agents(Done) });
        Assert.Equal(3, Inbox.InScope(items, null).Count);
        Assert.Equal([InboxKind.AgentDone, InboxKind.PairRequest], Inbox.InScope(items, "b").Select(i => i.Kind));
    }

    [Fact]
    public void AStatusChangeMakesANewItem()
    {
        var finished = Blocked with { Status = AgentStatus.Done };
        var a = new InboxItem(new InboxContent.Agent("a", Blocked, true), "a");
        var b = new InboxItem(new InboxContent.Agent("a", finished, true), "a");
        Assert.NotEqual(a.Key, b.Key);
    }

    [Fact]
    public void TheTargetIsTheComputerInScopeOrTheOnlyOneOnline()
    {
        var a = Device("a");
        var b = Device("b");
        var off = Device("off", online: false);
        var input = new HashSet<string> { "b" };
        Assert.Equal(new ActionTarget.One(a), Inbox.Target("a", [a, b]));
        Assert.Equal(new ActionTarget.Unavailable(off), Inbox.Target("off", [a, off]));
        Assert.Equal(new ActionTarget.Unavailable(null), Inbox.Target("gone", [a]));
        Assert.Equal(new ActionTarget.Ask(ValueList.From([a, b])), Inbox.Target(null, [a, b, off]));
        Assert.Equal(new ActionTarget.One(b), Inbox.Target(null, [a, b], d => input.Contains(d.Id)));
        Assert.Equal(new ActionTarget.Unavailable(a), Inbox.Target("a", [a, b], d => input.Contains(d.Id)));
        Assert.Equal(new ActionTarget.Unavailable(null), Inbox.Target(null, [off]));
        Assert.Equal(new ActionTarget.One(a), Inbox.Target(null, [a, off]));
        Assert.True(Inbox.HasFeature(null, [a, b], d => input.Contains(d.Id)));
        Assert.False(Inbox.HasFeature("a", [a, b], d => input.Contains(d.Id)));
    }

    static readonly string[] Dialog =
    [
        "● I added the migration.",
        new string('─', 40),
        " Bash command",
        "",
        "   bin/migrate --apply",
        "   Apply the pending migration",
        "",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and do not ask again",
        "   3. No",
    ];

    [Fact]
    public void ThePromptIsTheTextAboveTheChoices()
    {
        Assert.Equal("Bash command\nbin/migrate --apply\nApply the pending migration\nDo you want to proceed?", Inbox.AgentPrompt(Dialog));
        Assert.Equal("Apply the pending migration\nDo you want to proceed?", Inbox.AgentPrompt(Dialog, maxLines: 2));
        // A short prompt drops the question, so that the command stays next to the choices.
        Assert.Equal("Bash command\nbin/migrate --apply\nApply the pending migration", Inbox.AgentPrompt(Dialog, maxLines: 3, dropAsk: true));
        Assert.Equal("bin/migrate --apply\nApply the pending migration", Inbox.AgentPrompt(Dialog, maxLines: 2, dropAsk: true));
    }

    [Fact]
    public void AShortPromptKeepsALastLineThatIsNotAQuestion()
    {
        string[] lines = ["Would you like to run the following command?", "", "$ bin/migrate --apply", "", "› 1. Yes, proceed (y)", "  2. No (esc)"];
        Assert.Equal("Would you like to run the following command?\n$ bin/migrate --apply", Inbox.AgentPrompt(lines, maxLines: 3, dropAsk: true));
        // Without choices, nothing answers the question, so it stays.
        Assert.Equal("Which file?", Inbox.AgentPrompt(["Some work", "────", "", "Which file?", ""], maxLines: 3, dropAsk: true));
    }

    [Fact]
    public void WithoutChoicesThePromptIsTheLastLines()
    {
        Assert.Equal("Which file?", Inbox.AgentPrompt(["Some work", "────", "", "Which file?", ""]));
        Assert.Equal("", Inbox.AgentPrompt([]));
    }

    [Fact]
    public void ThePromptLooksOnlyAtTheEndOfTheOutput()
    {
        // The choices are more than 40 lines from the end, so the last lines are the prompt.
        var lines = new List<string> { "Which way?", "1. Left", "2. Right" };
        lines.AddRange(Enumerable.Range(0, 45).Select(i => $"line {i}"));
        Assert.Equal("line 43\nline 44", Inbox.AgentPrompt(lines, maxLines: 2));
    }

    [Fact]
    public void AClipPreviewIsOneShortLine()
    {
        Assert.Equal("a b c", Inbox.ClipPreview("  a\n\tb   c \n"));
        Assert.Equal("a b", Inbox.ClipPreview("a\r\nb"));
        var cut = Inbox.ClipPreview(new string('x', 500), 10);
        Assert.Equal(10, cut.Length);
        Assert.EndsWith("…", cut);
        // 160 characters stay whole.
        Assert.Equal(160, Inbox.ClipPreview(new string('x', 160)).Length);
    }

    [Fact]
    public void ItemTexts()
    {
        var waiting = Blocked with { Project = "billing", Workspace = "ws" };
        var input = new InboxItem(new InboxContent.Agent("a", waiting, true), "desk");
        Assert.Equal(InboxKind.AgentInput, input.Kind);
        Assert.Equal("agent|a|w2:p1|AgentInput", input.Key);
        Assert.Equal(["a"], input.DeviceIds);
        Assert.Equal("Needs input", input.StateWord);
        Assert.Equal(InboxTone.Red, input.Tone);
        Assert.Equal(["codex", "billing"], input.SourceParts);
        Assert.Equal("Migrate", input.Title);

        var finished = new InboxItem(new InboxContent.Agent("a", Done, true), "desk");
        Assert.Equal("Done", finished.StateWord);
        Assert.Equal(InboxTone.Green, finished.Tone);
        // A blank project and workspace go.
        Assert.Equal(["claude"], finished.SourceParts);

        var bare = Working with { Title = "", Workspace = "flux" };
        var works = new InboxItem(new InboxContent.Agent("a", bare, false), "desk");
        Assert.Equal("Working", works.StateWord);
        Assert.Equal(InboxTone.Accent, works.Tone);
        // The workspace stands in for the project.
        Assert.Equal(["claude", "flux"], works.SourceParts);
        // Without a title and a project, the pane names the agent.
        Assert.Equal("w1:p1", works.Title);
        Assert.Equal("billing", new InboxItem(new InboxContent.Agent("a", waiting with { Title = "" }, true), "desk").Title);

        var approve = new InboxItem(new InboxContent.Approval(Approval("a")), "name-a");
        Assert.Equal(InboxKind.Approval, approve.Kind);
        Assert.Equal("approve|a|r1", approve.Key);
        Assert.Equal(["a"], approve.DeviceIds);
        Assert.Equal("Needs approval", approve.StateWord);
        Assert.Equal(InboxTone.Red, approve.Tone);
        Assert.Equal(["sudo"], approve.SourceParts);
        Assert.Equal("Approve sudo on host?", approve.Title);
        Assert.Equal("Enroll this computer on host?",
            new InboxItem(new InboxContent.Approval(Approval("a") with { Kind = ApproveKind.Enroll }), "name-a").Title);

        var pair = new InboxItem(new InboxContent.Pair("new"), "name-new");
        Assert.Equal(InboxKind.PairRequest, pair.Kind);
        Assert.Equal("pair|new", pair.Key);
        // A pair request shows in every scope.
        Assert.Empty(pair.DeviceIds);
        Assert.Equal("Pair request", pair.StateWord);
        Assert.Equal(InboxTone.Red, pair.Tone);
        Assert.Empty(pair.SourceParts);
        Assert.Equal("name-new asks to pair", pair.Title);
    }

    [Fact]
    public void TheKindsInOrder()
    {
        Assert.True(InboxKind.AgentInput.NeedsYou());
        Assert.True(InboxKind.Approval.NeedsYou());
        Assert.True(InboxKind.PairRequest.NeedsYou());
        Assert.False(InboxKind.AgentDone.NeedsYou());
        Assert.False(InboxKind.AgentWorking.NeedsYou());
        Assert.Equal(["AgentInput", "Approval", "PairRequest", "AgentDone", "AgentWorking"], Enum.GetValues<InboxKind>().Select(k => k.KeyName()));
    }
}
