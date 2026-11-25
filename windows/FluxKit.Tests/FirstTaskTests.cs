using FluxKit;

namespace FluxKit.Tests;

// The first task of a new agent: it goes as a prompt when the agent is
// ready, and after the answer to a question such as the trust dialog.
// Ported from FirstTaskTests.swift.
public class FirstTaskTests
{
    double now = 100;

    // Updates at the current time.
    bool Update(ref FirstTask t, AgentStatus? status, bool choices = false) => t.Update(status, choices, now);

    // Lets the agent stay ready for the hold: the first ready update starts
    // it, and the update at its end sends the task.
    bool ReadyForTheHold(ref FirstTask t, AgentStatus status = AgentStatus.Idle)
    {
        var started = Update(ref t, status);
        now += FirstTask.Hold;
        return !started && Update(ref t, status);
    }

    [Fact]
    public void SendsWhenTheNewAgentStaysIdle()
    {
        var t = new FirstTask("Reply with ok");
        Assert.Equal(FirstTaskPhase.Starting, t.Phase);
        // Nothing goes before the computer names the pane.
        Assert.False(Update(ref t, AgentStatus.Idle));
        t.Created("w4:p1", null);
        Assert.Equal(FirstTaskPhase.Waiting, t.Phase);
        Assert.Equal("w4:p1", t.Pane);
        // A pane that is not in the list yet waits.
        Assert.False(Update(ref t, null));
        Assert.False(Update(ref t, AgentStatus.Working));
        Assert.False(Update(ref t, AgentStatus.Unknown));
        Assert.Equal(FirstTaskPhase.Waiting, t.Phase);
        // The first ready state starts the hold.
        Assert.False(Update(ref t, AgentStatus.Idle));
        Assert.Equal(now + FirstTask.Hold, t.Due);
        now += FirstTask.Hold - 0.1;
        // The task waits for the whole hold.
        Assert.False(Update(ref t, AgentStatus.Idle));
        now += 0.1;
        Assert.True(Update(ref t, AgentStatus.Idle));
        Assert.Equal(FirstTaskPhase.Sending, t.Phase);
        // The task goes once.
        Assert.False(Update(ref t, AgentStatus.Idle));
        t.Sent(null);
        Assert.Equal(FirstTaskPhase.Sent, t.Phase);
        Assert.False(Update(ref t, AgentStatus.Idle));
    }

    [Fact]
    public void DoneIsReadyToo()
    {
        var t = new FirstTask("go");
        t.Created("w4:p1", null);
        Assert.True(ReadyForTheHold(ref t, AgentStatus.Done));
    }

    [Fact]
    public void WaitsForTheAnswerToTheTrustDialog()
    {
        var t = new FirstTask("go");
        t.Created("w4:p1", null);
        Assert.False(Update(ref t, AgentStatus.Blocked, choices: true));
        Assert.Equal(FirstTaskPhase.Answering, t.Phase);
        // Blocked without choices still waits for an answer.
        Assert.False(Update(ref t, AgentStatus.Blocked));
        Assert.False(Update(ref t, AgentStatus.Working));
        // The phase stays until the agent is ready.
        Assert.Equal(FirstTaskPhase.Answering, t.Phase);
        Assert.True(ReadyForTheHold(ref t));
        Assert.Equal(FirstTaskPhase.Sending, t.Phase);
    }

    [Fact]
    public void ANewDialogDuringTheHoldStopsIt()
    {
        // Claude Code shows the next dialog right after the trust dialog.
        var t = new FirstTask("go");
        t.Created("w4:p1", null);
        Assert.False(Update(ref t, AgentStatus.Blocked));
        Assert.False(Update(ref t, AgentStatus.Idle));
        now += 0.5;
        // The next dialog.
        Assert.False(Update(ref t, AgentStatus.Blocked));
        Assert.Null(t.Due);
        Assert.Equal(FirstTaskPhase.Answering, t.Phase);
        now += FirstTask.Hold;
        // The hold starts again after the answer.
        Assert.False(Update(ref t, AgentStatus.Idle));
        now += FirstTask.Hold;
        Assert.True(Update(ref t, AgentStatus.Idle));
    }

    [Fact]
    public void WorkingDuringTheHoldStopsIt()
    {
        var t = new FirstTask("go");
        t.Created("w4:p1", null);
        Assert.False(Update(ref t, AgentStatus.Idle));
        Assert.False(Update(ref t, AgentStatus.Working));
        Assert.Null(t.Due);
        now += FirstTask.Hold;
        Assert.False(Update(ref t, AgentStatus.Idle));
    }

    [Fact]
    public void ChoicesOnScreenHoldTheTask()
    {
        var t = new FirstTask("go");
        t.Created("w4:p1", null);
        Assert.False(Update(ref t, AgentStatus.Idle));
        now += FirstTask.Hold;
        // A dialog on screen needs an answer, whatever the status.
        Assert.False(Update(ref t, AgentStatus.Idle, choices: true));
        Assert.Equal(FirstTaskPhase.Answering, t.Phase);
        // New output without the dialog lets the task go after the hold.
        Assert.True(ReadyForTheHold(ref t));
    }

    [Fact]
    public void AFailedCreateFails()
    {
        var t = new FirstTask("go");
        t.Created(null, "claude did not start");
        Assert.Equal(FirstTaskPhase.Failed("claude did not start"), t.Phase);
        Assert.False(Update(ref t, AgentStatus.Idle));
        Assert.True(t.Finished);
    }

    [Fact]
    public void AnAgentThatStopsFails()
    {
        var t = new FirstTask("go");
        t.Created("w4:p1", null);
        Assert.False(Update(ref t, AgentStatus.Working));
        Assert.False(Update(ref t, null));
        Assert.Equal(FirstTaskPhase.Failed("The agent stopped before it got the task."), t.Phase);
    }

    [Fact]
    public void AnAgentThatNeverAppearsFails()
    {
        var t = new FirstTask("go");
        t.Created("w4:p1", null);
        Assert.False(Update(ref t, null));
        Assert.Equal(now + FirstTask.AppearLimit, t.AppearDue);
        now += FirstTask.AppearLimit - 1;
        Assert.False(Update(ref t, null));
        // The agent list can take a while.
        Assert.Equal(FirstTaskPhase.Waiting, t.Phase);
        now += 1;
        Assert.False(Update(ref t, null));
        Assert.Equal(FirstTaskPhase.Failed("The agent did not appear."), t.Phase);
        Assert.Null(t.AppearDue);
    }

    [Fact]
    public void AnAgentThatAppearsHasNoDeadline()
    {
        var t = new FirstTask("go");
        t.Created("w4:p1", null);
        Assert.False(Update(ref t, null));
        Assert.False(Update(ref t, AgentStatus.Working));
        Assert.Null(t.AppearDue);
        now += FirstTask.AppearLimit * 2;
        Assert.False(Update(ref t, AgentStatus.Working));
        // A working agent may take its time.
        Assert.Equal(FirstTaskPhase.Waiting, t.Phase);
    }

    [Fact]
    public void AFailedPromptFails()
    {
        var t = new FirstTask("go");
        t.Created("w4:p1", null);
        Assert.True(ReadyForTheHold(ref t));
        t.Sent("roger did not answer");
        Assert.Equal(FirstTaskPhase.Failed("roger did not answer"), t.Phase);
        Assert.True(t.Finished);
    }

    [Fact]
    public void TheTextIsTrimmed()
    {
        Assert.Equal("go on", new FirstTask("  go on \n").Text);
    }

    // Plugin

    static Packet Msg(string json) => Packet.Parse($$"""{"id":1,"type":"flux.herdr","body":{{json}}}""")!;

    static Packet State(string status) =>
        Msg($$"""{"kind":"state","enabled":true,"running":true,"control":true,"agents":[{"pane":"w4:p1","agent":"claude","status":"{{status}}"}]}""");

    static void SetTask(HerdrPlugin plugin, FirstTask task) => plugin.Model.FirstTasks = plugin.Model.FirstTasks.SetItem("d", task);

    [Fact]
    public void ThePluginSendsTheTaskOfItsCreate()
    {
        var plugin = new HerdrPlugin();
        var timers = new HerdrTimers();
        plugin.After = timers.After;
        plugin.Create("d", "agent", "claude", "~", "", "Reply with ok");
        // A create that cannot go takes its task with it.
        Assert.Equal(FirstTaskPhase.Failed("The computer is not reachable"), plugin.Model.FirstTasks["d"].Phase);

        plugin.Model.Actions = plugin.Model.Actions.SetItem("d", new HerdrAction("create", 7, What: "agent"));
        SetTask(plugin, new FirstTask("Reply with ok", 7));
        plugin.Receive(State("blocked"), "d", "c");
        Assert.Equal(FirstTaskPhase.Starting, plugin.Model.FirstTasks["d"].Phase);
        plugin.Receive(Msg("""{"kind":"created","what":"agent","pane":"w4:p1"}"""), "d", "c");
        // The state before the created answer counts.
        Assert.Equal(FirstTaskPhase.Answering, plugin.Model.FirstTasks["d"].Phase);
        Assert.False(plugin.Model.Replies.ContainsKey("d"));
        double clock = 50;
        plugin.Clock = () => clock;
        plugin.Receive(State("idle"), "d", "c");
        // The task waits for the hold.
        Assert.False(plugin.Model.Replies.ContainsKey("d"));
        clock += FirstTask.Hold;
        plugin.Receive(State("idle"), "d", "c");
        // The plugin has no link here, so the prompt fails at once.
        Assert.Equal("prompt", plugin.Model.Replies["d"].Action);
        Assert.Equal("w4:p1", plugin.Model.Replies["d"].Pane);
        Assert.Equal(FirstTaskPhase.Failed("The computer is not reachable"), plugin.Model.FirstTasks["d"].Phase);
        plugin.ClearFirstTask("d");
        Assert.False(plugin.Model.FirstTasks.ContainsKey("d"));
    }

    [Fact]
    public void ThePluginChecksTheTaskAgainAtTheEndOfTheHold()
    {
        var plugin = new HerdrPlugin();
        var timers = new HerdrTimers();
        plugin.After = timers.After;
        double clock = 50;
        plugin.Clock = () => clock;
        plugin.Model.Actions = plugin.Model.Actions.SetItem("d", new HerdrAction("create", 7, What: "agent"));
        SetTask(plugin, new FirstTask("go", 7));
        plugin.Receive(Msg("""{"kind":"created","what":"agent","pane":"w4:p1"}"""), "d", "c");
        plugin.Receive(State("idle"), "d", "c");
        Assert.False(plugin.Model.Replies.ContainsKey("d"));
        // No new state comes, so the timer at the end of the hold sends the task.
        clock += FirstTask.Hold + 0.05;
        timers.Advance(TimeSpan.FromSeconds(FirstTask.Hold + 0.1));
        Assert.Equal("prompt", plugin.Model.Replies["d"].Action);
    }

    [Fact]
    public void ThePluginFailsATaskWhoseAgentNeverAppears()
    {
        var plugin = new HerdrPlugin();
        plugin.After = new HerdrTimers().After;
        double clock = 50;
        plugin.Clock = () => clock;
        plugin.Model.Actions = plugin.Model.Actions.SetItem("d", new HerdrAction("create", 7, What: "agent"));
        SetTask(plugin, new FirstTask("go", 7));
        plugin.Receive(Msg("""{"kind":"created","what":"agent","pane":"w9:p9"}"""), "d", "c");
        // The deadline starts without any state.
        Assert.Equal(FirstTaskPhase.Waiting, plugin.Model.FirstTasks["d"].Phase);
        Assert.Equal(50 + FirstTask.AppearLimit, plugin.Model.FirstTasks["d"].AppearDue);
        clock += FirstTask.AppearLimit;
        plugin.Receive(State("idle"), "d", "c");
        Assert.Equal(FirstTaskPhase.Failed("The agent did not appear."), plugin.Model.FirstTasks["d"].Phase);
    }

    [Fact]
    public void TheSentAnswerEndsTheTask()
    {
        var plugin = new HerdrPlugin();
        var t = new FirstTask("go", 1);
        t.Created("w4:p1", null);
        Assert.True(ReadyForTheHold(ref t));
        SetTask(plugin, t);
        plugin.Receive(Msg("""{"kind":"sent","pane":"w4:p1","action":"keys"}"""), "d", "c");
        // Keys do not answer the task.
        Assert.Equal(FirstTaskPhase.Sending, plugin.Model.FirstTasks["d"].Phase);
        plugin.Receive(Msg("""{"kind":"sent","pane":"w4:p1","action":"prompt"}"""), "d", "c");
        Assert.Equal(FirstTaskPhase.Sent, plugin.Model.FirstTasks["d"].Phase);
    }

    [Fact]
    public void AnotherCreateIgnoresTheTask()
    {
        var plugin = new HerdrPlugin();
        plugin.Model.Actions = plugin.Model.Actions.SetItem("d", new HerdrAction("create", 9, What: "agent"));
        SetTask(plugin, new FirstTask("go", 8));
        plugin.Receive(Msg("""{"kind":"created","what":"agent","pane":"w4:p1"}"""), "d", "c");
        // The task waits for its own create.
        Assert.Equal(FirstTaskPhase.Starting, plugin.Model.FirstTasks["d"].Phase);
    }

    [Fact]
    public void ATerminalHasNoTask()
    {
        var plugin = new HerdrPlugin();
        plugin.Create("d", "terminal", "", "~", "", "ls");
        Assert.False(plugin.Model.FirstTasks.ContainsKey("d"));
    }
}
