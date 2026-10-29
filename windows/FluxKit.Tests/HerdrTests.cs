using System.Text.Json;
using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// Ported from HerdrTests.swift of the Mac app and HerdrReplyTest.kt of the
// Android app, plus the state tracker.
public class HerdrTests
{
    internal static JsonObject Body(string json) => Packet.Parse($$"""{"id":1,"type":"flux.herdr","body":{{json}}}""")!.Body;

    const string Esc = "\u001B";

    [Fact]
    public void ParsesBasicColors()
    {
        var lines = TermText.Parse($"{Esc}[1;31mred bold{Esc}[0m plain {Esc}[42m bg {Esc}[0m");
        Assert.Single(lines);
        var spans = lines[0].Spans;
        Assert.Equal(new TermSpan("red bold", new TermStyle(Fg: TermColor.Indexed(1), Bold: true)), spans[0]);
        Assert.Equal(new TermSpan(" plain ", new TermStyle()), spans[1]);
        Assert.Equal(new TermSpan(" bg ", new TermStyle(Bg: TermColor.Indexed(2))), spans[2]);
    }

    [Fact]
    public void ParsesHerdrColorForms()
    {
        // herdr sends the basic colors as palette entries.
        var lines = TermText.Parse($"{Esc}[0m{Esc}[1m{Esc}[38;5;6m/tmp{Esc}[0m {Esc}[38;2;215;119;87mtrue{Esc}[0m {Esc}[48;5;2mbg{Esc}[39;49m");
        Assert.Single(lines);
        var spans = lines[0].Spans;
        Assert.Equal(new TermSpan("/tmp", new TermStyle(Fg: TermColor.Indexed(6), Bold: true)), spans[0]);
        Assert.Equal(new TermSpan("true", new TermStyle(Fg: TermColor.Rgb(0xD77757))), spans[2]);
        Assert.Equal(new TermSpan("bg", new TermStyle(Bg: TermColor.Indexed(2))), spans[4]);
    }

    [Fact]
    public void ParsesBrightAndColonForms()
    {
        var s = TermText.ApplySgr(new TermStyle(), "93;104");
        Assert.Equal(TermColor.Indexed(11), s.Fg);
        Assert.Equal(TermColor.Indexed(12), s.Bg);
        Assert.Equal(TermColor.Rgb(0x0A141E), TermText.ApplySgr(new TermStyle(), "38:2::10:20:30").Fg);
        Assert.Equal(TermColor.Indexed(200), TermText.ApplySgr(new TermStyle(), "48:5:200").Bg);
        Assert.True(TermText.ApplySgr(new TermStyle(), "4:3").Underline);
        Assert.False(TermText.ApplySgr(new TermStyle(Underline: true), "4:0").Underline);
    }

    [Fact]
    public void ResetsStyles()
    {
        var s = TermText.ApplySgr(new TermStyle(), "1;2;3;4;7;9;31;42");
        Assert.Equal(new TermStyle(TermColor.Indexed(1), TermColor.Indexed(2), true, true, true, true, true, true), s);
        s = TermText.ApplySgr(s, "22;23;24;27;29;39;49");
        Assert.Equal(new TermStyle(), s);
        // An empty parameter list resets.
        Assert.Equal(new TermStyle(), TermText.ApplySgr(new TermStyle(Bold: true), ""));
        Assert.Equal(new TermStyle(), TermText.ApplySgr(new TermStyle(Fg: TermColor.Indexed(3)), "0"));
    }

    [Fact]
    public void IgnoresBadColors()
    {
        // An index above 255 is not a color.
        Assert.Null(TermText.ApplySgr(new TermStyle(), "38;5;300").Fg);
        // An incomplete color is not a color.
        Assert.Null(TermText.ApplySgr(new TermStyle(), "38;2;1;2").Fg);
        // An unknown color form ends the parameters, so 9 and 1 do not become styles.
        Assert.Equal(new TermStyle(Bold: true), TermText.ApplySgr(new TermStyle(), "1;38;9;1"));
        // A private form changes nothing.
        Assert.Equal(new TermStyle(), TermText.ApplySgr(new TermStyle(), ">4"));
    }

    [Fact]
    public void DropsOtherSequencesAndControls()
    {
        var text = $"a{Esc}[2Kb{Esc}]8;;https://example.com{Esc}\\link{Esc}]8;;\u0007c{Esc}(Bd{Esc}7e\r\u0001f";
        Assert.Equal(["ablinkcdef"], TermText.Parse(text).Select(l => l.Text));
        // A lone escape at the end goes.
        Assert.Equal(["x"], TermText.Parse($"x{Esc}").Select(l => l.Text));
    }

    [Fact]
    public void DropsC1AndMarksBidiControls()
    {
        var text = "ok \u202Eexe.sh\u202C \u0085done\u009B\u2066x\u2069\u2028";
        Assert.Equal(["ok \uFFFDexe.sh\uFFFD done\uFFFDx\uFFFD\uFFFD"], TermText.Parse(text).Select(l => l.Text));
    }

    [Fact]
    public void ExpandsTabsAndSplitsLines()
    {
        var lines = TermText.Parse("a\tb\r\n\tc\n");
        Assert.Equal(["a       b", "        c"], lines.Select(l => l.Text));
        // A no-break space becomes a space.
        Assert.Equal(["❯ x"], TermText.Parse("❯\u00A0x").Select(l => l.Text));
    }

    [Fact]
    public void StylesContinueOnTheNextLine()
    {
        var lines = TermText.Parse($"{Esc}[32mone\ntwo{Esc}[0m");
        Assert.Equal([new TermStyle(Fg: TermColor.Indexed(2))], lines[1].Spans.Select(s => s.Style));
    }

    [Fact]
    public void TidiesStyledLines()
    {
        var rule = $"{Esc}[38;5;4m" + new string('─', 80) + $"{Esc}[0m";
        var lines = TermText.Lines($"{rule}\n{Esc}[1mbold{Esc}[0m   {Esc}[41m   {Esc}[0m\n\n  \n");
        Assert.Equal(2, lines.Count);
        var fitted = TermText.Fit(lines, 32);
        Assert.Equal(new string('─', 32), fitted[0].Text);
        // A shortened rule keeps its color.
        Assert.Equal([TermColor.Indexed(4)], fitted[0].Spans.Select(s => s.Style.Fg));
        // Trailing blanks go, also with a background.
        Assert.Equal([new TermSpan("bold", new TermStyle(Bold: true))], lines[1].Spans);
    }

    [Fact]
    public void ComputesThePalette()
    {
        Assert.Null(TermText.PaletteRgb(15));
        Assert.Equal(0x000000, TermText.PaletteRgb(16));
        Assert.Equal(0xFFFFFF, TermText.PaletteRgb(231));
        Assert.Equal(0xD7875F, TermText.PaletteRgb(173));
        Assert.Equal(0x080808, TermText.PaletteRgb(232));
        Assert.Equal(0xEEEEEE, TermText.PaletteRgb(255));
    }

    static readonly string[] ClaudeDialog =
    [
        "● I will run the migration.",
        "Steps:",
        "1. Check the schema",
        "2. Apply the change",
        new string('─', 32),
        " Bash command",
        "",
        "   bin/migrate --apply",
        "",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and don't ask again for bin/migrate commands",
        "   3. No, and tell Claude what to do differently (esc)",
    ];

    [Fact]
    public void FindsTheChoicesOfADialog()
    {
        Assert.Equal(
        [
            new AgentChoice("1", "Yes", selected: true),
            new AgentChoice("2", "Yes, and don't ask again for bin/migrate commands"),
            new AgentChoice("3", "No, and tell Claude what to do differently (esc)"),
        ], AgentChoice.Find(ClaudeDialog));
    }

    [Fact]
    public void FindsChoicesWithDescriptionsAndARule()
    {
        string[] lines =
        [
            "Which database do you want?",
            "❯ 1. Postgres",
            "     The default for new services",
            "  2. SQLite",
            "     A file on the disk",
            "  3. Type something.",
            new string('─', 32),
            "  4. Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ];
        Assert.Equal(["1", "2", "3", "4"], AgentChoice.Find(lines).Select(c => c.Key));
    }

    [Fact]
    public void FindsNoChoicesInProse()
    {
        // A single choice is not a dialog.
        Assert.Empty(AgentChoice.Find(["1. Only one"]));
        // A list far from the end is not a dialog.
        var prose = new[] { "1. Check the schema", "2. Apply the change" }.Concat(Enumerable.Range(0, 20).Select(i => $"more output {i}")).ToArray();
        Assert.Empty(AgentChoice.Find(prose));
        Assert.Empty(AgentChoice.Find([]));
        // A choice needs a blank after its number.
        Assert.Empty(AgentChoice.Find(["1.x", "2)y"]));
        Assert.Equal(["1", "2"], AgentChoice.Find(["1) a", "2) b", "123. c"]).Select(c => c.Key));
    }

    [Fact]
    public void ANumberedListAboveTheInputIsNotADialog()
    {
        string[] list = ["● I would add these.", "", "  1. Notify when an agent needs you.", "  2. Hide finished agents.", ""];
        var rule = new string('─', 32);
        // The input of Claude Code.
        Assert.Empty(AgentChoice.Find([.. list, "✻ Cogitated for 24s · done 10:00 AM", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on"]));
        // The input of Codex.
        Assert.Empty(AgentChoice.Find([.. list, "› Ask Codex to do anything", "", "  100% context left"]));
        // The input in a box.
        Assert.Empty(AgentChoice.Find([.. list, "╭────────╮", "│ >      │", "╰────────╯"]));
        // A dialog has no input.
        Assert.Equal(["1", "2", "3"], AgentChoice.Find([.. ClaudeDialog, "", " Esc to cancel · Tab to amend"]).Select(c => c.Key));
    }

    [Fact]
    public void OutputKeepsColorsAndFindsChoices()
    {
        var text = string.Join("\n", ClaudeDialog).Replace(" ❯ 1. Yes", $" {Esc}[38;5;4m❯ 1. Yes{Esc}[0m");
        var json = JsonSerializer.Serialize(text);
        var o = HerdrWire.Output(Body($$"""{"kind":"output","pane":"w5:p1","format":"ansi","text":{{json}}}""")) ?? throw new Xunit.Sdk.XunitException("no output");
        Assert.Equal(string.Join("\n", ClaudeDialog), o.Text);
        Assert.Equal(TermColor.Indexed(4), o.Lines[10].Spans[^1].Style.Fg);
        Assert.Equal(3, o.Choices.Count);
        Assert.False(o.Loading);
    }

    [Fact]
    public void OutputWithAnError()
    {
        var o = HerdrWire.Output(Body("""{"kind":"output","pane":"w5:p1","error":"The agent in w5:p1 is gone","text":"x"}"""))!;
        Assert.Equal("The agent in w5:p1 is gone", o.Error);
        Assert.Empty(o.Lines);
        // An output needs a pane.
        Assert.Null(HerdrWire.Output(Body("""{"kind":"output","text":"x"}""")));
    }

    [Fact]
    public void ParsesState()
    {
        var s = HerdrWire.State(Body("""
            {"kind":"state","enabled":true,"running":true,"control":false,"agents":[
              {"pane":"w1:p1","agent":"codex","status":"idle","title":"","project":"flux","workspace":"flux"},
              {"pane":"w5:p1","agent":"claude","status":"blocked","title":"Custom skin loading","project":"cliamp","workspace":"cliamp"},
              {"pane":"w6:p2","agent":"","status":"thinking"},
              {"pane":"w7:p1","agent":"pi","status":"working"},
              {"pane":"","agent":"lost","status":"done"},
              {"pane":"w8:p1","agent":"amp","status":"done"}]}
            """))!;
        Assert.True(s.Enabled);
        Assert.True(s.Running);
        // An agent needs a pane.
        Assert.Equal(5, s.Agents.Count);
        // An agent with no name gets a name.
        Assert.Equal("agent", s.Agent("w6:p2")?.Agent);
        Assert.Equal(AgentStatus.Unknown, s.Agent("w6:p2")?.Status);
        Assert.Equal(1, s.Blocked);
        // Blocked, done, working, idle, then unknown.
        Assert.Equal(["w5:p1", "w8:p1", "w7:p1", "w1:p1", "w6:p2"], s.Sorted.Select(a => a.Pane));
        Assert.Equal(new HerdrAgent("w5:p1", "claude", AgentStatus.Blocked, "Custom skin loading", "cliamp", "cliamp"), s.Agent("w5:p1"));
    }

    [Fact]
    public void SortKeepsTheHerdrOrderInAGroup()
    {
        var agents = new[] { "a", "b", "c", "d" }.Select(p => new HerdrAgent(p, "claude", p == "c" ? AgentStatus.Blocked : AgentStatus.Working));
        Assert.Equal(["c", "a", "b", "d"], new HerdrState(true, true, agents).Sorted.Select(a => a.Pane));
    }

    [Fact]
    public void ParsesControl()
    {
        Assert.True(HerdrWire.State(Body("""{"kind":"state","enabled":true,"running":true,"control":true,"agents":[]}"""))!.Control);
        // A missing control field is false.
        Assert.False(HerdrWire.State(Body("""{"kind":"state","enabled":true,"running":true,"agents":[]}"""))!.Control);
        var off = HerdrWire.State(Body("""{"kind":"state","enabled":false,"control":true,"running":true}"""))!;
        // A computer with herdr off takes no replies.
        Assert.False(off.Control);
        Assert.False(off.Running);
        Assert.Null(HerdrWire.State(Body("""{"kind":"output","pane":"w5:p1"}""")));
    }

    [Fact]
    public void ParsesTheBridge()
    {
        var s = HerdrWire.State(Body("""{"kind":"state","enabled":true,"running":true,"control":true,"bridge":["observe","control","",3],"agents":[]}"""))!;
        Assert.Equal(["observe", "control"], s.Bridge);
        Assert.Empty(HerdrWire.State(Body("""{"kind":"state","enabled":true,"running":true,"agents":[]}"""))!.Bridge);
    }

    [Fact]
    public void ParsesSent()
    {
        Assert.Equal(new HerdrSent("w5:p1", "keys", null), HerdrWire.Sent(Body("""{"kind":"sent","pane":"w5:p1","action":"keys"}""")));
        var e = HerdrWire.Sent(Body("""{"kind":"sent","pane":"w5:p1","action":"prompt","error":"Replies from the phone are off on this computer."}"""))!;
        Assert.Equal("prompt", e.Action);
        Assert.Equal("Replies from the phone are off on this computer.", e.Error);
        // A sent answer needs a pane.
        Assert.Null(HerdrWire.Sent(Body("""{"kind":"sent","action":"keys"}""")));
        var blocked = HerdrWire.Sent(Body("""{"kind":"sent","pane":"w5:p1","action":"prompt","error":"Pick a choice first.","code":"blocked","request":7}"""))!;
        Assert.Equal(HerdrWire.BlockedCode, blocked.Code);
        Assert.Equal(7, blocked.Request);
        Assert.Null(e.Code);
        // An older fluxd sends no number.
        Assert.Null(e.Request);
        // An output is not a sent answer.
        Assert.Null(HerdrWire.Sent(Body("""{"kind":"output","pane":"w5:p1"}""")));
    }

    [Fact]
    public void KeysMatchTheComputer()
    {
        foreach (var k in new[] { "enter", "esc", "tab", "shift+tab", "up", "down", "left", "right", "backspace", "space", "y", "n", "0", "9" })
        {
            Assert.Contains(k, HerdrWire.AllowedKeys);
        }
        Assert.DoesNotContain("ctrl+c", HerdrWire.AllowedKeys);
        Assert.Equal(22, HerdrWire.AllowedKeys.Count);
        Assert.True(HerdrWire.Allowed(["shift+tab"]));
        Assert.False(HerdrWire.Allowed([]));
        // fluxd takes at most 8 keys.
        Assert.False(HerdrWire.Allowed(Enumerable.Repeat("up", 9).ToArray()));
        Assert.False(HerdrWire.Allowed(["enter", "ctrl+c"]));
    }

    internal static void AssertBody(string json, Packet p) =>
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(json), p.Body), $"{p.Body.ToJsonString()} is not {json}");

    [Fact]
    public void PacketsMatchTheComputer()
    {
        var read = HerdrWire.Read("w5:p1");
        Assert.Equal("flux.herdr", read.Type);
        AssertBody("""{"kind":"read","pane":"w5:p1","lines":1000,"format":"ansi"}""", read);
        AssertBody("""{"kind":"keys","pane":"w5:p1","keys":["2"]}""", HerdrWire.Keys("w5:p1", ["2"]));
        AssertBody("""{"kind":"prompt","pane":"w5:p1","text":"go on"}""", HerdrWire.Prompt("w5:p1", "go on"));
        // fluxd types into the dialog of an agent that waits for a choice
        // only with "answer".
        AssertBody("""{"kind":"prompt","pane":"w5:p1","text":"3","answer":true}""", HerdrWire.Prompt("w5:p1", "3", answer: true));
        AssertBody("""{"kind":"request"}""", HerdrWire.Request());
        AssertBody("""{"kind":"read","pane":"w5:p1","format":"diff","path":"a.go","request":4,"lines":1000}""",
            HerdrWire.ViewRead("w5:p1", "diff", "a.go", 4));
        Assert.Equal("flux.herdr", PacketType.Herdr);
    }

    [Fact]
    public void OutputKeepsTheEndOfALongText()
    {
        Assert.Equal("short", HerdrWire.Tail("short", 10).Text);
        Assert.False(HerdrWire.Tail("short", 10).Cut);
        var (end, cut) = HerdrWire.Tail("line 1\nline 2\nline 3", 10);
        Assert.True(cut);
        // The end starts at a line.
        Assert.Equal("line 3", end);
        // The end starts at a whole character.
        Assert.Equal("éééé", HerdrWire.Tail(new string('é', 20), 9).Text);

        var text = new string('x', HerdrWire.MaxText + 10);
        var o = HerdrWire.Output(new JsonObject { ["kind"] = "output", ["pane"] = "w5:p1", ["text"] = text })!;
        Assert.True(o.Truncated);
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(o.Text) <= HerdrWire.MaxText);
    }

    // Tracker

    static HerdrAgent Agent(string pane, AgentStatus status) => new(pane, "claude", status, Project: "flux");

    [Fact]
    public void FirstListPostsNothing()
    {
        var t = new HerdrTracker();
        // The first list only clears the notification of a working agent.
        Assert.Equal([new AgentAlert.Clear("p3")],
            t.Update([Agent("p1", AgentStatus.Blocked), Agent("p2", AgentStatus.Done), Agent("p3", AgentStatus.Working)]));
        Assert.Empty(t.Update([Agent("p1", AgentStatus.Blocked), Agent("p2", AgentStatus.Done), Agent("p3", AgentStatus.Working)]));
    }

    [Fact]
    public void FindsTheChanges()
    {
        var t = new HerdrTracker();
        t.Update([Agent("p1", AgentStatus.Working), Agent("p2", AgentStatus.Idle)]);
        Assert.Equal([new AgentAlert.NeedsInput(Agent("p1", AgentStatus.Blocked))],
            t.Update([Agent("p1", AgentStatus.Blocked), Agent("p2", AgentStatus.Idle)]));
        // Working again removes the notification.
        Assert.Equal([new AgentAlert.Clear("p1")], t.Update([Agent("p1", AgentStatus.Working), Agent("p2", AgentStatus.Idle)]));
        Assert.Equal([new AgentAlert.Finished(Agent("p1", AgentStatus.Done))],
            t.Update([Agent("p1", AgentStatus.Done), Agent("p2", AgentStatus.Idle)]));
        // Done to idle is no new finish.
        Assert.Equal([new AgentAlert.Clear("p1")], t.Update([Agent("p1", AgentStatus.Idle), Agent("p2", AgentStatus.Idle)]));
    }

    [Fact]
    public void UnknownKeepsTheLastStatus()
    {
        var t = new HerdrTracker();
        t.Update([Agent("p1", AgentStatus.Working)]);
        Assert.Empty(t.Update([Agent("p1", AgentStatus.Unknown)]));
        Assert.Equal([new AgentAlert.Finished(Agent("p1", AgentStatus.Done))], t.Update([Agent("p1", AgentStatus.Done)]));
    }

    [Fact]
    public void NewAndGoneAgents()
    {
        var t = new HerdrTracker();
        t.Update([Agent("p1", AgentStatus.Working)]);
        // A new agent that is already blocked posts nothing.
        Assert.Empty(t.Update([Agent("p1", AgentStatus.Working), Agent("p2", AgentStatus.Blocked)]));
        Assert.Equal([new AgentAlert.Clear("p1")], t.Update([Agent("p2", AgentStatus.Blocked)]));
        Assert.Equal([new AgentAlert.Clear("p2")], t.Update([]));
    }

    [Fact]
    public void RestartSetsTheStartValuesAgain()
    {
        var t = new HerdrTracker();
        t.Update([Agent("p1", AgentStatus.Working)]);
        t.Restart();
        // The first list after a reconnect posts nothing.
        Assert.Empty(t.Update([Agent("p1", AgentStatus.Blocked)]));
        Assert.Equal([new AgentAlert.Clear("p1")], t.Update([Agent("p1", AgentStatus.Working)]));
    }

    // Clock

    [Fact]
    public void ClockKnowsOnlyTheTimesThatItSaw()
    {
        var clock = new AgentClock();
        var start = new DateTimeOffset(2026, 10, 15, 12, 0, 0, TimeSpan.Zero);
        // The first list after a connection only sets the start values.
        Assert.Empty(clock.Update([Agent("p1", AgentStatus.Working)], start));
        var later = start.AddMinutes(1);
        Assert.Equal(later, clock.Update([Agent("p1", AgentStatus.Blocked), Agent("p2", AgentStatus.Working)], later)["p1"]);
        // A new agent after the first list gets its time.
        Assert.Equal(later, clock.Times["p2"]);
        // An unknown status keeps the last status and its time.
        Assert.Equal(later, clock.Update([Agent("p1", AgentStatus.Unknown)], later.AddMinutes(1))["p1"]);
        Assert.Equal("3m", AgentTime.When(AgentStatus.Blocked, later, later.AddMinutes(3)));
        Assert.Equal("now", AgentTime.When(AgentStatus.Idle, later, later.AddSeconds(30)));
        Assert.Equal("2h", AgentTime.When(AgentStatus.Idle, later, later.AddHours(2)));
        Assert.Equal("2:14", AgentTime.When(AgentStatus.Working, later, later.AddSeconds(134)));
        Assert.Equal("1:02:03", AgentTime.When(AgentStatus.Working, later, later.AddSeconds(3723)));
        Assert.Equal("done", AgentTime.When(AgentStatus.Done, null, later));
        Assert.Equal("", AgentTime.When(AgentStatus.Working, null, later));
        Assert.Equal("just now", AgoText.Text(later, later.AddSeconds(59)));
        Assert.Equal("3 min ago", AgoText.Text(later, later.AddMinutes(3)));
        Assert.Equal("2 h ago", AgoText.Text(later, later.AddHours(2)));
        Assert.Equal("1 day ago", AgoText.Text(later, later.AddHours(30)));
        Assert.Equal("4 days ago", AgoText.Text(later, later.AddDays(4)));
    }
}
