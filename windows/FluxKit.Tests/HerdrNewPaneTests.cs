using FluxKit;

namespace FluxKit.Tests;

// Ported from NewPaneTests.swift of the Mac app and NewPaneTest.kt of the
// Android app.
public class HerdrNewPaneTests
{
    static readonly HerdrState State = new(
        enabled: true,
        running: true,
        agents:
        [
            new HerdrAgent("w2:p1", "claude", AgentStatus.Idle, Workspace: "flux"),
            new HerdrAgent("w2:p2", "codex", AgentStatus.Working, Workspace: "flux"),
            new HerdrAgent("w3:p1", "claude", AgentStatus.Done, Workspace: "web"),
        ],
        control: true,
        workspaces:
        [
            new HerdrWorkspace("w1", "notes", "~"),
            new HerdrWorkspace("w2", "flux", "~/Code/flux/"),
            new HerdrWorkspace("w3", "web", "~/Code/web"),
            new HerdrWorkspace("w4", "flux 2", "~/Code/flux"),
            new HerdrWorkspace("w5", "empty", ""),
            new HerdrWorkspace("w6", "srv", "/srv/app"),
        ]);

    [Fact]
    public void FoldersComeOnceAfterHome()
    {
        var folders = NewPane.FolderChoices(State);
        Assert.Equal(["~", "~/Code/flux", "~/Code/web", "/srv/app"], folders.Select(f => f.Path));
        Assert.Equal(["home", "flux", "web", "app"], folders.Select(f => f.Name));
        // The first workspace of a folder wins.
        Assert.Equal("w2", folders[1].Workspace?.Id);
        Assert.Equal([0, 2, 1, 0], folders.Select(f => f.Agents));
        Assert.Equal("w1", folders[0].Workspace?.Id);
    }

    [Fact]
    public void HomeWithoutWorkspace()
    {
        var s = State with { Workspaces = ValueList.From([new HerdrWorkspace("w3", "web", "~/Code/web")]) };
        var folders = NewPane.FolderChoices(s);
        Assert.Equal(["~", "~/Code/web"], folders.Select(f => f.Path));
        Assert.Null(folders[0].Workspace);
    }

    [Fact]
    public void HomeCountsTheAgentsOfItsWorkspace()
    {
        var s = State with { Agents = ValueList.From(State.Agents.Append(new HerdrAgent("w1:p1", "claude", AgentStatus.Idle, Workspace: "notes"))) };
        Assert.Equal(1, NewPane.FolderChoices(s)[0].Agents);
    }

    [Fact]
    public void FiltersByNameOrPath()
    {
        var folders = NewPane.FolderChoices(State);
        Assert.Equal(["~/Code/flux"], NewPane.FilterFolders(folders, "FLU").Select(f => f.Path));
        Assert.Equal(["~/Code/flux", "~/Code/web"], NewPane.FilterFolders(folders, "code").Select(f => f.Path));
        Assert.Equal(folders, NewPane.FilterFolders(folders, "  "));
    }

    [Fact]
    public void MatchesTheWorkspaceOfAFolder()
    {
        Assert.Equal("w2", NewPane.WorkspaceFor(State, "~/Code/flux")?.Id);
        // A slash at the end does not matter.
        Assert.Equal("w2", NewPane.WorkspaceFor(State, "~/Code/flux/")?.Id);
        Assert.Equal("w1", NewPane.WorkspaceFor(State, "~")?.Id);
        Assert.Null(NewPane.WorkspaceFor(State, "~/Code/other"));
        // A workspace without a folder matches nothing.
        Assert.Null(NewPane.WorkspaceFor(State, ""));
    }

    [Fact]
    public void FolderNamesAndPaths()
    {
        Assert.Equal("home", NewPane.FolderName("~"));
        Assert.Equal("home", NewPane.FolderName("~/"));
        Assert.Equal("home", NewPane.FolderName(""));
        Assert.Equal("flux", NewPane.FolderName("~/Code/flux/"));
        Assert.Equal("/", NewPane.FolderName("/"));
        Assert.Equal("/", NewPane.NormalFolder("/"));
        Assert.Equal("~", NewPane.NormalFolder("~"));
        Assert.Equal("~/a", NewPane.NormalFolder(" ~/a// "));
        Assert.Equal("/", NewPane.NormalFolder("//"));
        Assert.True(NewPane.LooksLikePath("~/Code"));
        Assert.True(NewPane.LooksLikePath(" /srv"));
        Assert.False(NewPane.LooksLikePath("flux"));
    }

    [Fact]
    public void PicksTheRun()
    {
        string[] kinds = ["codex", "claude", "opencode"];
        // The last choice stays.
        Assert.Equal("opencode", NewPane.PickRun("opencode", kinds, false));
        // A missing agent gives claude.
        Assert.Equal("claude", NewPane.PickRun("gemini", kinds, true));
        Assert.Equal("codex", NewPane.PickRun(null, ["codex", "opencode"], true));
        Assert.Equal(NewPane.ShellChoice, NewPane.PickRun(NewPane.ShellChoice, kinds, true));
        // A terminal needs terminals.
        Assert.Equal("claude", NewPane.PickRun(NewPane.ShellChoice, kinds, false));
        Assert.Equal(NewPane.ShellChoice, NewPane.PickRun(null, [], true));
        Assert.Null(NewPane.PickRun("claude", [], false));
    }

    [Fact]
    public void ProductNames()
    {
        Assert.Equal("Claude Code", NewPane.AgentProduct("claude"));
        Assert.Equal("Codex CLI", NewPane.AgentProduct("codex"));
        Assert.Equal("Antigravity", NewPane.AgentProduct("agy"));
        Assert.Null(NewPane.AgentProduct("somethingnew"));
    }

    [Fact]
    public void HomeFolderFromBrowseIsTilde()
    {
        Assert.Equal("~", NewPane.HomeRelative("/home/snorre", "/home/snorre"));
        Assert.Equal("~", NewPane.HomeRelative("/home/snorre/", "/home/snorre"));
    }

    [Fact]
    public void FolderInHomeFromBrowseStartsWithTilde()
    {
        Assert.Equal("~/Code/app", NewPane.HomeRelative("/home/snorre/Code/app", "/home/snorre"));
        Assert.Equal("~/Code/app", NewPane.HomeRelative("/home/snorre/Code/app/", "/home/snorre/"));
    }

    [Fact]
    public void FolderOutsideHomeStaysAbsolute()
    {
        Assert.Equal("/home/snorre2/x", NewPane.HomeRelative("/home/snorre2/x", "/home/snorre"));
        Assert.Equal("/srv/data", NewPane.HomeRelative("/srv/data", "/home/snorre"));
        Assert.Equal("/srv/data", NewPane.HomeRelative("/srv/data", ""));
    }

    [Fact]
    public void BrowsedFolderMatchesItsWorkspace()
    {
        var folder = NewPane.HomeRelative("/home/snorre/Code/flux", "/home/snorre");
        Assert.Equal(NewPane.WorkspaceFor(State, "~/Code/flux")?.Id, NewPane.WorkspaceFor(State, folder)?.Id);
    }

    [Fact]
    public void TildeOpensTheHomeFolderInBrowse()
    {
        Assert.Equal("/home/snorre", NewPane.AbsoluteFolder("~", "/home/snorre"));
        Assert.Equal("/home/snorre", NewPane.AbsoluteFolder("~/", "/home/snorre/"));
    }

    [Fact]
    public void FolderInHomeOpensUnderTheHomeFolderInBrowse()
    {
        Assert.Equal("/home/snorre/Code/app", NewPane.AbsoluteFolder("~/Code/app", "/home/snorre"));
        Assert.Equal("/home/snorre/Code/app", NewPane.AbsoluteFolder("~/Code/app/", "/home/snorre/"));
    }

    [Fact]
    public void AbsoluteFolderOpensAsItIsInBrowse()
    {
        Assert.Equal("/srv/data", NewPane.AbsoluteFolder("/srv/data/", "/home/snorre"));
        Assert.Equal("/srv/data", NewPane.AbsoluteFolder("/srv/data", ""));
    }

    [Fact]
    public void FolderWithoutAKnownHomeHasNoPathInBrowse()
    {
        Assert.Null(NewPane.AbsoluteFolder("~/Code/app", ""));
        Assert.Null(NewPane.AbsoluteFolder("~", "/"));
        Assert.Null(NewPane.AbsoluteFolder("~other/x", "/home/snorre"));
        Assert.Null(NewPane.AbsoluteFolder("Code/app", "/home/snorre"));
    }

    [Fact]
    public void ChosenFolderOpensWhereBrowseFoundIt()
    {
        var folder = NewPane.HomeRelative("/home/snorre/Code/flux", "/home/snorre");
        Assert.Equal("/home/snorre/Code/flux", NewPane.AbsoluteFolder(folder, "/home/snorre"));
    }
}
