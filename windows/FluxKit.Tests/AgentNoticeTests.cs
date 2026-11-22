using FluxKit;

namespace FluxKit.Tests;

// The text and the buttons of the agent notification. Ported from
// AgentNoticeTest.kt of the Android app, with the same vectors.
public class AgentNoticeTests
{
    static readonly HerdrAgent Blocked = new("w2:p1", "codex", AgentStatus.Blocked, "Run the database migration", "billing", "billing");

    static AgentDialog Dialog(string[] labels, string question = "Do you want to proceed?", string[]? lines = null)
    {
        lines ??= ["$ bin/migrate --apply"];
        var choices = labels.Select((l, i) => new AgentChoice((i + 1).ToString(), l)).ToArray();
        return new AgentDialog(question, ValueList.From(lines), ValueList.From(choices), true, AgentDialogs.Id(question, lines, labels), DateTimeOffset.UnixEpoch);
    }

    static AgentDialog Free(string question = "Which database should I migrate?") => Dialog([], question, []);

    [Fact]
    public void TwoChoicesGiveChoiceActions()
    {
        var n = AgentNotice.Build(Blocked, Dialog(["Yes", "No"]), control: true);
        Assert.Equal(["Yes", "No"], n.Actions.Select(a => a.Label));
        Assert.Equal(["1", "2"], n.Actions.Select(a => a.Key));
        Assert.All(n.Actions, a => Assert.Equal(NoticeKind.Choice, a.Kind));
        Assert.Equal("codex in billing needs input", n.Title);
    }

    [Fact]
    public void ThreeChoicesGiveChoiceActionsAndNoReply()
    {
        var n = AgentNotice.Build(Blocked, Dialog(["Yes", "Yes, and do not ask again", "No"]), control: true);
        Assert.Equal(3, n.Actions.Count);
        Assert.DoesNotContain(n.Actions, a => a.Kind == NoticeKind.Reply);
        Assert.Contains("bin/migrate --apply", n.Text);
        Assert.EndsWith("Do you want to proceed?", n.Text);
    }

    [Fact]
    public void FourChoicesGiveNoAction()
    {
        var n = AgentNotice.Build(Blocked, Dialog(["Yes", "Always", "No", "Tell it what to do"]), control: true);
        Assert.Empty(n.Actions);
        Assert.Contains("4. Tell it what to do", n.BigText);
    }

    [Fact]
    public void NoChoicesGiveReply()
    {
        var n = AgentNotice.Build(Blocked, Free(), control: true);
        Assert.Equal([new NoticeAction(NoticeKind.Reply, "Reply", "")], n.Actions);
        Assert.Equal("codex in billing asks a question", n.Title);
        Assert.Equal("Which database should I migrate?", n.Text);
    }

    [Fact]
    public void ControlOffGivesNoActionAndReadOnly()
    {
        var n = AgentNotice.Build(Blocked, Dialog(["Yes", "No"]), control: false);
        Assert.Empty(n.Actions);
        Assert.EndsWith(" Read only", n.Text);
        Assert.EndsWith("\nRead only", n.BigText);
        // Reply is an action too.
        Assert.Empty(AgentNotice.Build(Blocked, Free("Which one?"), control: false).Actions);
    }

    [Fact]
    public void ControlOnHasNoReadOnlyText() =>
        Assert.DoesNotContain("Read only", AgentNotice.Build(Blocked, Dialog(["Yes", "No"]), control: true).Text);

    [Fact]
    public void AFinishedAgentGivesNoAction()
    {
        var n = AgentNotice.Build(Blocked with { Status = AgentStatus.Done }, Dialog(["Yes", "No"]), control: true);
        Assert.Empty(n.Actions);
        Assert.Equal("codex in billing finished", n.Title);
        Assert.Equal("Run the database migration", n.Text);
    }

    [Fact]
    public void AMissingDialogGivesNoActionAndTheTitleOfTheAgent()
    {
        var n = AgentNotice.Build(Blocked, null, control: true);
        Assert.Empty(n.Actions);
        Assert.Equal("Run the database migration", n.Text);
        Assert.Equal("codex in billing needs input", n.Title);
    }

    [Fact]
    public void ALongLabelIsCutAtAWordEnd()
    {
        Assert.Equal("Yes, and do not ask…", AgentNotice.CutLabel("Yes, and do not ask again for bin/migrate commands"));
        Assert.Equal("No", AgentNotice.CutLabel("No"));
        Assert.Equal("exactly twenty-four ch", AgentNotice.CutLabel("exactly twenty-four ch"));
        Assert.Equal(new string('a', 24) + "…", AgentNotice.CutLabel(new string('a', 40)));
        Assert.Equal("one two three four five…", AgentNotice.CutLabel("one two three four five six"));
        var n = AgentNotice.Build(Blocked, Dialog(["Yes", "Yes, and do not ask again for bin/migrate commands", "No"]), control: true);
        Assert.Equal("Yes, and do not ask…", n.Actions[1].Label);
        Assert.Contains("2. Yes, and do not ask again for bin/migrate commands", n.BigText);
    }

    [Fact]
    public void TheNoticeCarriesTheIdOfItsDialog()
    {
        var d = Dialog(["Yes", "No"]);
        Assert.Equal(d.Id, AgentNotice.Build(Blocked, d, control: true).DialogId);
        Assert.Equal("", AgentNotice.Build(Blocked, null, control: true).DialogId);
    }

    [Fact]
    public void AReplySendsOnlyForTheDialogOfTheNotice()
    {
        var a = Dialog([], "Which name?", ["Name the file."]);
        var b = Dialog([], "Which folder?", ["Name the folder."]);
        Assert.True(AgentDialogs.ReplyMatches(a, a.Id));
        Assert.False(AgentDialogs.ReplyMatches(b, a.Id));
        Assert.False(AgentDialogs.ReplyMatches(null, a.Id));
        Assert.False(AgentDialogs.ReplyMatches(a, ""));
        var withChoices = Dialog(["Yes", "No"]);
        Assert.False(AgentDialogs.ReplyMatches(withChoices, withChoices.Id));
    }
}
