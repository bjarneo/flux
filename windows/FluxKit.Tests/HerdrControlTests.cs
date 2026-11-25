using System.Collections.Immutable;
using FluxKit;

namespace FluxKit.Tests;

// Ported from HerdrControlTests.swift of the Mac app and HerdrTest.kt of the
// Android app: terminals, workspaces, kinds, sessions, and the create, close,
// and input packets.
public class HerdrControlTests
{
    static System.Text.Json.Nodes.JsonObject Body(string json) => HerdrTests.Body(json);

    static Packet Msg(string json) => Packet.Parse($$"""{"id":1,"type":"flux.herdr","body":{{json}}}""")!;

    [Fact]
    public void ParsesTerminalsWorkspacesAndKinds()
    {
        var s = HerdrWire.State(Body("""
            {"kind":"state","enabled":true,"running":true,"control":true,"terminals":true,"agents":[],
            "panes":[{"pane":"w1:p2","title":"npm run dev","project":"web","workspace":"web"},{"title":"no pane"}],
            "workspaces":[{"id":"w1","label":"web","cwd":"/src/web"},{"id":"w2"},{"label":"no id"}],
            "kinds":["claude","","codex"]}
            """))!;
        Assert.True(s.Control);
        Assert.True(s.Terminals);
        Assert.Equal([new HerdrTerminal("w1:p2", "npm run dev", "web", "web")], s.Panes);
        Assert.Equal(new HerdrTerminal("w1:p2", "npm run dev", "web", "web"), s.Terminal("w1:p2"));
        Assert.Null(s.Terminal("w9:p9"));
        // A workspace needs an id, and its id is the label when it has none.
        Assert.Equal([new HerdrWorkspace("w1", "web", "/src/web"), new HerdrWorkspace("w2", "w2")], s.Workspaces);
        // An empty kind is dropped.
        Assert.Equal(["claude", "codex"], s.Kinds);
    }

    [Fact]
    public void GatesTheFieldsLikeAndroid()
    {
        var noControl = HerdrWire.State(Body("""
            {"kind":"state","enabled":true,"running":true,"control":false,"terminals":true,"panes":[{"pane":"w1:p2"}],
            "workspaces":[{"id":"w1"}],"kinds":["claude"]}
            """))!;
        // Terminals, workspaces, and kinds need control.
        Assert.False(noControl.Terminals);
        Assert.Empty(noControl.Panes);
        Assert.Empty(noControl.Workspaces);
        Assert.Empty(noControl.Kinds);

        var noTerminals = HerdrWire.State(Body("""
            {"kind":"state","enabled":true,"running":true,"control":true,"terminals":false,"panes":[{"pane":"w1:p2"}],
            "workspaces":[{"id":"w1"}],"kinds":["claude"]}
            """))!;
        // Panes need terminals.
        Assert.Empty(noTerminals.Panes);
        Assert.Equal(["w1"], noTerminals.Workspaces.Select(w => w.Id));
        Assert.Equal(["claude"], noTerminals.Kinds);

        var off = HerdrWire.State(Body("""{"kind":"state","enabled":false,"running":true,"control":true,"terminals":true}"""))!;
        Assert.False(off.Control);
        // A computer with herdr off has no terminals.
        Assert.False(off.Terminals);

        var old = HerdrWire.State(Body("""{"kind":"state","enabled":true,"running":true,"control":true,"agents":[]}"""))!;
        // An older fluxd without the field has no terminals.
        Assert.False(old.Terminals);
        Assert.Empty(old.Kinds);
    }

    [Fact]
    public void ParsesCreatedAndClosed()
    {
        Assert.Equal(new HerdrDone("create", "w4:p1", null), HerdrWire.Done(Body("""{"kind":"created","what":"agent","pane":"w4:p1"}""")));
        Assert.Equal(new HerdrDone("create", null, "The folder /x does not exist"),
            HerdrWire.Done(Body("""{"kind":"created","error":"The folder /x does not exist"}""")));
        Assert.Equal(new HerdrDone("close", "w4:p1", null), HerdrWire.Done(Body("""{"kind":"closed","pane":"w4:p1"}""")));
        // An empty error is no error.
        Assert.Null(HerdrWire.Done(Body("""{"kind":"closed","pane":"w4:p1","error":""}"""))?.Error);
        Assert.Null(HerdrWire.Done(Body("""{"kind":"sent","pane":"w4:p1"}""")));
        Assert.Equal(5, HerdrWire.Done(Body("""{"kind":"closed","pane":"w4:p1","request":5}"""))?.Request);
        // An older fluxd sends no number.
        Assert.Null(HerdrWire.Done(Body("""{"kind":"closed","pane":"w4:p1"}"""))?.Request);
    }

    [Fact]
    public void TerminalKeys()
    {
        Assert.Contains("ctrl+c", HerdrWire.TerminalKeys);
        Assert.Contains("ctrl+a", HerdrWire.TerminalKeys);
        Assert.Contains("ctrl+z", HerdrWire.TerminalKeys);
        Assert.DoesNotContain("f1", HerdrWire.TerminalKeys);
        // A terminal types letters as text.
        Assert.DoesNotContain("y", HerdrWire.TerminalKeys);
        Assert.DoesNotContain("ctrl+c", HerdrWire.AllowedKeys);
        Assert.Equal(10 + 26, HerdrWire.TerminalKeys.Count);
        // An input can be text alone.
        Assert.True(HerdrWire.AllowedInput("ls", []));
        Assert.True(HerdrWire.AllowedInput("", ["ctrl+c"]));
        // An input needs text or keys.
        Assert.False(HerdrWire.AllowedInput("", []));
        // fluxd takes at most 8 keys.
        Assert.False(HerdrWire.AllowedInput("x", Enumerable.Repeat("up", 9).ToArray()));
        // Digits are text in a terminal.
        Assert.False(HerdrWire.AllowedInput("x", ["2"]));
    }

    [Fact]
    public void PacketsMatchAndroid()
    {
        HerdrTests.AssertBody("""{"kind":"read","pane":"w5:p1","lines":1000,"format":"ansi"}""", HerdrWire.Read("w5:p1"));
        HerdrTests.AssertBody("""{"kind":"input","pane":"w1:p2","text":"ls","keys":["enter"]}""", HerdrWire.Input("w1:p2", "ls", ["enter"]));
        HerdrTests.AssertBody("""{"kind":"input","pane":"w1:p2","text":"","keys":["ctrl+c"]}""", HerdrWire.Input("w1:p2", "", ["ctrl+c"]));
        HerdrTests.AssertBody("""{"kind":"input","pane":"w1:p2","text":"ls","keys":[]}""", HerdrWire.Input("w1:p2", "ls", []));
        HerdrTests.AssertBody("""{"kind":"create","what":"agent","agent":"claude","cwd":"~/Code/x","workspace":"w3"}""",
            HerdrWire.Create("agent", "claude", " ~/Code/x ", "w3"));
        HerdrTests.AssertBody("""{"kind":"create","what":"terminal","agent":"","cwd":"","workspace":""}""",
            HerdrWire.Create("terminal", "", "", ""));
        HerdrTests.AssertBody("""{"kind":"close","pane":"w4:p1"}""", HerdrWire.Close("w4:p1"));
        Assert.Equal("flux.herdr", HerdrWire.Close("w4:p1").Type);
        HerdrTests.AssertBody("""{"kind":"close","pane":"w4:p1","request":5}""", HerdrWire.Numbered(HerdrWire.Close("w4:p1"), 5));
    }

    [Fact]
    public void CreateNamesTheSessionOfANewWorkspace()
    {
        HerdrTests.AssertBody("""{"kind":"create","what":"agent","agent":"claude","cwd":"~/x","workspace":"","herdr_session":"omarchy"}""",
            HerdrWire.Create("agent", "claude", "~/x", "", "omarchy"));
        // A workspace ID names its session.
        HerdrTests.AssertBody("""{"kind":"create","what":"agent","agent":"claude","cwd":"~/x","workspace":"omarchy/w3"}""",
            HerdrWire.Create("agent", "claude", "~/x", "omarchy/w3", "omarchy"));
        // The default session needs no field.
        HerdrTests.AssertBody("""{"kind":"create","what":"terminal","agent":"","cwd":"","workspace":""}""",
            HerdrWire.Create("terminal", "", "", "", "default"));
        HerdrTests.AssertBody("""{"kind":"create","what":"terminal","agent":"","cwd":"","workspace":""}""",
            HerdrWire.Create("terminal", "", "", "", ""));
    }

    // Sessions

    internal const string SessionsState = """
        {"kind":"state","enabled":true,"running":true,"control":true,"terminals":true,"kinds":["claude"],
        "agents":[{"pane":"w1:p1","agent":"claude","status":"idle","project":"flux","workspace":"flux"}],
        "panes":[{"pane":"w1:p2","workspace":"flux"}],
        "workspaces":[{"id":"w1","label":"flux","cwd":"~/Code/flux"}],
        "sessions":[
         {"name":"default","default":true,"running":true,
          "agents":[{"pane":"w1:p1","agent":"claude","status":"idle","project":"flux","workspace":"flux"}],
          "panes":[{"pane":"w1:p2","workspace":"flux"}],
          "workspaces":[{"id":"w1","label":"flux","cwd":"~/Code/flux"}]},
         {"name":"omarchy","default":false,"running":true,
          "agents":[{"pane":"omarchy/w1:p1","agent":"codex","status":"blocked","project":"omarchy","workspace":"omarchy"},
                    {"pane":"omarchy/w2:p1","agent":"claude","status":"blocked"}],
          "panes":[{"pane":"omarchy/w3:p2","workspace":"omarchy"}],
          "workspaces":[{"id":"omarchy/w1","label":"omarchy","cwd":"~/.local/share/omarchy"}]}
        ]}
        """;

    [Fact]
    public void ParsesSessions()
    {
        var s = HerdrWire.State(Body(SessionsState))!;
        Assert.Equal([new HerdrSession("default", true, true), new HerdrSession("omarchy", false, true)], s.Sessions);
        // The agents of all sessions, the default session first.
        Assert.Equal(["w1:p1", "omarchy/w1:p1", "omarchy/w2:p1"], s.Agents.Select(a => a.Pane));
        Assert.Equal(["default", "omarchy", "omarchy"], s.Agents.Select(a => a.Session));
        Assert.Equal(["w1:p2", "omarchy/w3:p2"], s.Panes.Select(p => p.Pane));
        Assert.Equal(["w1", "omarchy/w1"], s.Workspaces.Select(w => w.Id));
        Assert.Equal("omarchy", s.Workspaces[^1].Session);
        // A lookup finds the agents of each session.
        Assert.Equal("codex", s.Agent("omarchy/w1:p1")?.Agent);
        Assert.Equal("omarchy", s.Terminal("omarchy/w3:p2")?.Session);
        // The agents of all sessions count.
        Assert.Equal(2, s.Blocked);
        Assert.Equal(2, s.BlockedCount("omarchy"));
        Assert.Equal(0, s.BlockedCount("default"));
        Assert.Equal("omarchy", s.Session("omarchy").Label);
        Assert.Equal("Default", s.Session(null).Label);
    }

    [Fact]
    public void ParsesTheDefaultSessionOfAnOlderFluxd()
    {
        var s = HerdrWire.State(Body("""
            {"kind":"state","enabled":true,"running":false,"control":true,"agents":[{"pane":"w1:p1","agent":"claude","status":"idle"}],
            "workspaces":[{"id":"w1"}]}
            """))!;
        Assert.Equal([new HerdrSession("default", true, false)], s.Sessions);
        Assert.Equal([new HerdrAgent("w1:p1", "claude", AgentStatus.Idle)], s.Agents);
        Assert.Equal("default", s.Agents[0].Session);
        Assert.Equal("default", s.Workspaces[0].Session);
        // The default session is all of the state.
        Assert.Equal(s, s.ScopedTo(null));
        // A session that is gone shows the default session.
        Assert.Equal(s, s.ScopedTo("omarchy"));
        var empty = HerdrWire.State(Body("""{"kind":"state","enabled":true,"running":true,"agents":[{"pane":"w1:p1"}],"sessions":[]}"""))!;
        // An empty list is the default session.
        Assert.Equal(["default"], empty.Sessions.Select(x => x.Name));
        Assert.Equal(["w1:p1"], empty.Agents.Select(a => a.Pane));
    }

    [Fact]
    public void SessionsKeepThePermissions()
    {
        var s = HerdrWire.State(Body(SessionsState.Replace("\"terminals\":true", "\"terminals\":false")))!;
        // The panes of each session need terminals.
        Assert.Empty(s.Panes);
        Assert.Equal(2, s.Workspaces.Count);
        var off = HerdrWire.State(Body(SessionsState.Replace("\"control\":true", "\"control\":false")))!;
        // The workspaces of each session need control.
        Assert.Empty(off.Workspaces);
        Assert.Equal(3, off.Agents.Count);
    }

    [Fact]
    public void ScopesToASession()
    {
        var s = HerdrWire.State(Body(SessionsState))!;
        var omarchy = s.ScopedTo("omarchy");
        Assert.Equal(["omarchy/w1:p1", "omarchy/w2:p1"], omarchy.Agents.Select(a => a.Pane));
        Assert.Equal(["omarchy/w3:p2"], omarchy.Panes.Select(p => p.Pane));
        Assert.Equal(["omarchy/w1"], omarchy.Workspaces.Select(w => w.Id));
        Assert.Equal(2, omarchy.Blocked);
        // A scoped state keeps the session list.
        Assert.Equal(s.Sessions, omarchy.Sessions);
        // A new pane offers the workspaces of the session.
        Assert.Equal(["~", "~/.local/share/omarchy"], NewPane.FolderChoices(omarchy).Select(f => f.Path));
        var main = s.ScopedTo("default");
        Assert.Equal(["w1:p1"], main.Agents.Select(a => a.Pane));
        Assert.Equal(["w1"], main.Workspaces.Select(w => w.Id));
        // A session that is gone shows the default session.
        Assert.Equal(main, s.ScopedTo("gone"));
    }

    [Fact]
    public void ANamedSessionRunsWithoutTheDefaultSession()
    {
        var json = SessionsState.Replace("\"running\":true", "\"running\":false")
            .Replace("\"name\":\"omarchy\",\"default\":false,\"running\":false", "\"name\":\"omarchy\",\"default\":false,\"running\":true");
        var s = HerdrWire.State(Body(json))!;
        // The agents of a running session count.
        Assert.True(s.Running);
        Assert.False(s.ScopedTo(null).Running);
        Assert.True(s.ScopedTo("omarchy").Running);
    }

    [Fact]
    public void NewAgentsUseThePickedSessionWorkspaces()
    {
        var model = new HerdrPlugin().Model;
        // Both sessions can have the same folder. A new tab must stay in
        // the picked session, not the first match across all sessions.
        model.States = model.States.SetItem("d", HerdrWire.State(Body(SessionsState.Replace("~/.local/share/omarchy", "~/Code/flux")))!);
        model.SelectSession("d", "omarchy");
        var shown = model.Scoped("d")!;
        var workspace = NewPane.WorkspaceFor(shown, "~/Code/flux")!;
        Assert.Equal("omarchy/w1", workspace.Id);
        Assert.Equal(["omarchy/w1"], NewPane.FolderChoices(shown).Select(f => f.Workspace?.Id).OfType<string>());
        var tab = HerdrWire.Create("agent", "claude", "~/Code/flux", workspace.Id, model.CreateSession("d"));
        Assert.Equal("omarchy/w1", tab.String("workspace"));
        // An existing workspace names its session.
        Assert.False(tab.Has("herdr_session"));
        var created = HerdrWire.Create("agent", "claude", "~/Code/new", "", model.CreateSession("d"));
        Assert.Equal("omarchy", created.String("herdr_session"));
        model.SelectSession("d", "default");
        Assert.Equal("w1", NewPane.WorkspaceFor(model.Scoped("d")!, "~/Code/flux")?.Id);
        Assert.Equal("", model.CreateSession("d"));
    }

    [Fact]
    public void TheModelKeepsThePickedSession()
    {
        var m = new HerdrPlugin().Model;
        // No session before the first agent list.
        Assert.Null(m.Session("d"));
        Assert.Equal("", m.CreateSession("d"));
        m.States = m.States.SetItem("d", HerdrWire.State(Body(SessionsState))!);
        Assert.Equal("default", m.Session("d")?.Name);
        Assert.Equal(["w1:p1"], m.Scoped("d")!.Agents.Select(a => a.Pane));
        m.SelectSession("d", "omarchy");
        Assert.Equal(KeyValuePair.Create("d", "omarchy"), Assert.Single(m.SessionChoices));
        Assert.Equal(2, m.Scoped("d")!.Agents.Count);
        Assert.Equal(2, m.ScopedStates["d"].Agents.Count);
        Assert.Equal("omarchy", m.CreateSession("d"));
        // The agents of all sessions stay for the notifications.
        Assert.Equal(3, m.States["d"].Agents.Count);

        m.States = m.States.SetItem("d", HerdrWire.State(Body("""{"kind":"state","enabled":true,"running":true,"agents":[{"pane":"w1:p1"}]}"""))!);
        // A session that is gone shows the default session.
        Assert.Equal("default", m.Session("d")?.Name);
        Assert.Equal("", m.CreateSession("d"));
        // The choice stays while its session is gone.
        Assert.Equal(KeyValuePair.Create("d", "omarchy"), Assert.Single(m.SessionChoices));

        m.States = m.States.SetItem("d", HerdrWire.State(Body(SessionsState))!);
        // The session shows again when it comes back.
        Assert.Equal("omarchy", m.Session("d")?.Name);
        m.Reveal("d", "w1:p2");
        // A notification shows the session of its pane.
        Assert.Equal("default", m.Session("d")?.Name);
        Assert.Empty(m.SessionChoices);
        m.Reveal("d", "omarchy/w2:p1");
        Assert.Equal("omarchy", m.Session("d")?.Name);
    }

    [Fact]
    public void TheModelSavesItsSettings()
    {
        var path = Path.Combine(CoreTests.TempDir(), "settings.json");
        var settings = new FluxSettings(path);
        var m = new HerdrPlugin().Model;
        m.Load(settings);
        Assert.True(m.InputAlerts);
        Assert.True(m.DoneAlerts);
        m.States = m.States.SetItem("d", HerdrWire.State(Body(SessionsState))!);
        m.InputAlerts = false;
        m.DictationLanguage = "de-DE";
        m.SelectSession("d", "omarchy");
        var again = new HerdrPlugin().Model;
        again.Load(new FluxSettings(path));
        Assert.False(again.InputAlerts);
        Assert.True(again.DoneAlerts);
        Assert.Equal("de-DE", again.DictationLanguage);
        Assert.Equal("omarchy", again.SessionChoices["d"]);
    }

    [Fact]
    public void TimeoutsMatchAndroid()
    {
        Assert.Equal(TimeSpan.FromSeconds(15), HerdrPlugin.ReadTimeout);
        Assert.Equal(TimeSpan.FromSeconds(60), HerdrPlugin.CreateTimeout);
        Assert.Equal(TimeSpan.FromSeconds(10), HerdrPlugin.ReplyTimeout);
        Assert.Equal(TimeSpan.FromSeconds(10), HerdrPlugin.CloseTimeout);
        Assert.Equal(TimeSpan.FromMilliseconds(700), HerdrPlugin.RereadDelay);
        Assert.Equal(TimeSpan.FromSeconds(5), HerdrPlugin.WorkingRefresh);
        Assert.Equal(1000, HerdrWire.ReadLines);
    }

    // Plugin

    // A poll waits while the last read did not end, so that reads do not
    // pile up on a slow link. A manual read always goes out.
    [Fact]
    public void APollWaitsForTheLastRead()
    {
        var plugin = new HerdrPlugin();
        plugin.Model.Outputs = plugin.Model.Outputs.SetItem("d", new HerdrOutput("w1:p1", loading: true));
        plugin.Poll("d", "w1:p1");
        // The poll skips while the read loads.
        Assert.Equal(new HerdrOutput("w1:p1", loading: true), plugin.Model.Outputs["d"]);
        plugin.Read("d", "w1:p1");
        // A manual read goes out.
        Assert.Equal("The computer is not reachable", plugin.Model.Outputs["d"].Error);
        plugin.Poll("d", "w1:p1");
        Assert.False(plugin.Model.Outputs["d"].Loading);
        plugin.Model.Outputs = plugin.Model.Outputs.SetItem("d", new HerdrOutput("w1:p2", loading: true));
        plugin.Poll("d", "w1:p1");
        // A read of another pane does not stop the poll.
        Assert.Equal("w1:p1", plugin.Model.Outputs["d"].Pane);
    }

    [Fact]
    public void CreatedAnswersTheCreate()
    {
        var plugin = new HerdrPlugin();
        plugin.Model.Actions = plugin.Model.Actions.SetItem("d", new HerdrAction("create", 3, What: "agent"));
        plugin.Receive(Msg("""{"kind":"closed","pane":"w4:p1"}"""), "d", "c");
        // A closed answer does not answer a create.
        Assert.True(plugin.Model.Actions["d"].Sending);
        plugin.Receive(Msg("""{"kind":"created","what":"agent","pane":"w4:p1"}"""), "d", "c");
        Assert.Equal(new HerdrAction("create", 3, false, "w4:p1", "agent"), plugin.Model.Actions["d"]);
        plugin.Receive(Msg("""{"kind":"created","what":"agent","error":"late"}"""), "d", "c");
        // A second answer changes nothing.
        Assert.Null(plugin.Model.Actions["d"].Error);
        plugin.ClearAction("d", 2);
        // Only the answered action clears.
        Assert.True(plugin.Model.Actions.ContainsKey("d"));
        plugin.ClearAction("d", 3);
        Assert.False(plugin.Model.Actions.ContainsKey("d"));
    }

    [Fact]
    public void AnswersMatchTheNumberOfTheCreate()
    {
        var plugin = new HerdrPlugin();
        plugin.Model.Actions = plugin.Model.Actions.SetItem("d", new HerdrAction("create", 3, What: "agent"));
        plugin.Receive(Msg("""{"kind":"created","what":"agent","pane":"w4:p1","request":2}"""), "d", "c");
        // The answer to an earlier create does not end this one.
        Assert.True(plugin.Model.Actions["d"].Sending);
        plugin.Receive(Msg("""{"kind":"created","what":"agent","pane":"w4:p2","request":3}"""), "d", "c");
        Assert.Equal(new HerdrAction("create", 3, false, "w4:p2", "agent"), plugin.Model.Actions["d"]);
    }

    [Fact]
    public void AnswersMatchTheNumberOfTheReply()
    {
        var plugin = new HerdrPlugin();
        plugin.Model.Replies = plugin.Model.Replies.SetItem("d", new HerdrReply("w1:p1", "prompt", 4, Text: "go on"));
        plugin.Receive(Msg("""{"kind":"sent","pane":"w1:p1","action":"prompt","error":"late","request":3}"""), "d", "c");
        // The answer to an earlier reply does not end this reply.
        Assert.True(plugin.Model.Replies["d"].Sending);
        plugin.Receive(Msg("""
            {"kind":"sent","pane":"w1:p1","action":"prompt","error":"The agent waits for a choice. Pick a choice first.","code":"blocked","request":4}
            """), "d", "c");
        Assert.False(plugin.Model.Replies["d"].Sending);
        Assert.Equal("The agent waits for a choice. Pick a choice first.", plugin.Model.Replies["d"].Error);
        // The UI offers to send the text as an answer.
        Assert.True(plugin.Model.Replies["d"].Blocked);
        Assert.Equal("go on", plugin.Model.Replies["d"].Text);

        plugin.Model.Replies = plugin.Model.Replies.SetItem("d", new HerdrReply("w1:p1", "keys", 5));
        plugin.Receive(Msg("""{"kind":"sent","pane":"w1:p1","action":"keys"}"""), "d", "c");
        // An answer from an older fluxd matches by the pane.
        Assert.False(plugin.Model.Replies["d"].Sending);
        Assert.False(plugin.Model.Replies["d"].Blocked);
    }

    [Fact]
    public void APromptKeepsItsText()
    {
        var plugin = new HerdrPlugin();
        plugin.SendPrompt("d", "w1:p1", " go on ", answer: true);
        // The text can go again as an answer.
        Assert.Equal("go on", plugin.Model.Replies["d"].Text);
        Assert.Equal("The computer is not reachable", plugin.Model.Replies["d"].Error);
        Assert.False(plugin.Model.Replies["d"].Blocked);
    }

    [Fact]
    public void APromptLongerThan16KbFails()
    {
        var plugin = new HerdrPlugin();
        plugin.SendPrompt("d", "w1:p1", new string('é', HerdrWire.MaxPrompt / 2 + 1));
        Assert.Equal("The text is too long. The limit is 16 KB.", plugin.Model.Replies["d"].Error);
        Assert.Equal("prompt", plugin.Model.Replies["d"].Action);
        plugin.SendPrompt("d", "w1:p1", "  ");
        // An empty prompt sends nothing.
        Assert.Equal("The text is too long. The limit is 16 KB.", plugin.Model.Replies["d"].Error);
    }

    [Fact]
    public void CreatedWithAnError()
    {
        var plugin = new HerdrPlugin();
        plugin.Model.Actions = plugin.Model.Actions.SetItem("d", new HerdrAction("create", 1, What: "terminal"));
        plugin.Receive(Msg("""{"kind":"created","what":"terminal","error":"Terminals are off"}"""), "d", "c");
        Assert.Equal("Terminals are off", plugin.Model.Actions["d"].Error);
        Assert.Null(plugin.Model.Actions["d"].Pane);
        Assert.False(plugin.Model.Actions["d"].Sending);
    }

    [Fact]
    public void ClosedAnswersTheCloseOfItsPane()
    {
        var plugin = new HerdrPlugin();
        plugin.Model.Actions = plugin.Model.Actions.SetItem("d", new HerdrAction("close", 1, Pane: "w4:p1"));
        plugin.Receive(Msg("""{"kind":"closed","pane":"w9:p1"}"""), "d", "c");
        // The close of another pane is no answer.
        Assert.True(plugin.Model.Actions["d"].Sending);
        plugin.Receive(Msg("""{"kind":"closed","pane":"w4:p1"}"""), "d", "c");
        Assert.Equal(new HerdrAction("close", 1, false, "w4:p1"), plugin.Model.Actions["d"]);
    }

    [Fact]
    public void ActionsWithoutALinkFail()
    {
        var plugin = new HerdrPlugin();
        plugin.Create("d", "agent", "claude", "~", "");
        Assert.Equal("create", plugin.Model.Actions["d"].Action);
        Assert.Equal("agent", plugin.Model.Actions["d"].What);
        Assert.False(plugin.Model.Actions["d"].Sending);
        Assert.Equal("The computer is not reachable", plugin.Model.Actions["d"].Error);
        plugin.Close("d", "w1:p1");
        Assert.Equal("w1:p1", plugin.Model.Actions["d"].Pane);
        // Each action has a new number.
        Assert.True(plugin.Model.Actions["d"].Seq > 1);
    }

    [Fact]
    public void InputChecksItsKeysAndLength()
    {
        var plugin = new HerdrPlugin();
        plugin.SendInput("d", "w1:p2", "", []);
        // An empty input sends nothing.
        Assert.False(plugin.Model.Replies.ContainsKey("d"));
        plugin.SendInput("d", "w1:p2", "", ["f1"]);
        // A key that fluxd refuses sends nothing.
        Assert.False(plugin.Model.Replies.ContainsKey("d"));
        plugin.SendInput("d", "w1:p2", new string('x', HerdrWire.MaxPrompt + 1), ["enter"]);
        Assert.Equal("The text is too long. The limit is 16 KB.", plugin.Model.Replies["d"].Error);
        Assert.Equal("input", plugin.Model.Replies["d"].Action);
        plugin.SendInput("d", "w1:p2", "ls", ["enter"]);
        Assert.Equal("The computer is not reachable", plugin.Model.Replies["d"].Error);
    }

    [Fact]
    public void KeysOutsideTheAllowedSetSendNothing()
    {
        var plugin = new HerdrPlugin();
        plugin.SendKeys("d", "w1:p1", ["ctrl+c"]);
        Assert.False(plugin.Model.Replies.ContainsKey("d"));
        plugin.SendKeys("d", "w1:p1", Enumerable.Repeat("down", 9).ToArray());
        Assert.False(plugin.Model.Replies.ContainsKey("d"));
        plugin.SendKeys("d", "w1:p1", ["2"]);
        Assert.Equal(new HerdrReply("w1:p1", "keys", 1, false, "The computer is not reachable"), plugin.Model.Replies["d"]);
    }

    [Fact]
    public void ImmutableModelListsChangeAsAWhole()
    {
        var plugin = new HerdrPlugin();
        var before = plugin.Model.Replies;
        var changed = new List<string?>();
        plugin.Model.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        plugin.SendKeys("d", "w1:p1", ["enter"]);
        Assert.NotSame(before, plugin.Model.Replies);
        Assert.Empty(before);
        Assert.Contains(nameof(HerdrModel.Replies), changed);
        Assert.IsType<ImmutableDictionary<string, HerdrReply>>(plugin.Model.Replies);
    }
}
