using System.Text.Json;
using FluxKit;

namespace FluxKit.Tests;

// The prompt slot of the Inbox. It reads the output of an agent apart from
// the output of the agent screen. Ported from HerdrPromptTests.swift.
public class HerdrPromptTests
{
    static Packet Msg(string json) => Packet.Parse($$"""{"id":1,"type":"flux.herdr","body":{{json}}}""")!;

    static readonly string[] Dialog =
    [
        "● I will run the migration.",
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
    public void AReadWithoutALinkFailsAndKeepDropsIt()
    {
        var plugin = new HerdrPlugin();
        var key = HerdrModel.PromptKey("pc", "w1:p1");
        Assert.Equal("pc|w1:p1", key);
        plugin.ReadPrompt("pc", "w1:p1");
        Assert.False(plugin.Model.Prompts[key].Loading);
        Assert.EndsWith("is not reachable", plugin.Model.Prompts[key].Error);
        Assert.Equal("w1:p1", plugin.Model.Prompt("pc", "w1:p1")?.Pane);
        // The prompt does not use the output of the agent screen.
        Assert.Empty(plugin.Model.Outputs);
        plugin.KeepPrompts([key]);
        Assert.True(plugin.Model.Prompts.ContainsKey(key));
        plugin.KeepPrompts([]);
        Assert.False(plugin.Model.Prompts.ContainsKey(key));
    }

    [Fact]
    public async Task AnOutputFillsThePromptAndNotTheWindow()
    {
        var plugin = new HerdrPlugin();
        var key = HerdrModel.PromptKey("pc", "w5:p1");
        plugin.ReadPrompt("pc", "w5:p1");
        var json = JsonSerializer.Serialize(string.Join("\n", Dialog));
        plugin.Receive(Msg($$"""{"kind":"output","pane":"w5:p1","format":"ansi","text":{{json}}}"""), "pc", "desk");
        // The parse runs in a task of the pool.
        await Wait.UntilAsync(() => plugin.Model.Prompts.GetValueOrDefault(key)?.Lines.Count > 0, "the parse of the prompt");
        var output = plugin.Model.Prompts[key];
        Assert.False(output.Loading);
        Assert.Null(output.Error);
        Assert.Equal(3, output.Choices.Count);
        var ask = AgentAsk.Find(output.Lines.Select(l => l.Text).ToArray());
        Assert.Equal("Do you want to proceed?", ask?.Question);
        Assert.Equal(["$ bin/migrate --apply"], ask?.Lines);
        // The agent screen shows no output.
        Assert.False(plugin.Model.Outputs.ContainsKey("pc"));
    }

    [Fact]
    public async Task AParseFromBeforeADropDoesNotFillTheNewPrompt()
    {
        var plugin = new HerdrPlugin();
        var key = HerdrModel.PromptKey("pc", "w5:p1");
        plugin.ReadPrompt("pc", "w5:p1");
        plugin.Receive(Msg("""{"kind":"output","pane":"w5:p1","text":"old"}"""), "pc", "desk");
        var old = plugin.PromptParses[key];
        // The agent works, so the Inbox drops its prompt. Then the agent waits again.
        plugin.KeepPrompts([]);
        Assert.False(plugin.Model.Prompts.ContainsKey(key));
        plugin.ReadPrompt("pc", "w5:p1");
        plugin.Receive(Msg("""{"kind":"output","pane":"w5:p1","text":"new"}"""), "pc", "desk");
        // A parse number is not used again after a drop.
        Assert.NotEqual(old, plugin.PromptParses[key]);
        // The parses run in tasks of the pool.
        await Wait.UntilAsync(() => plugin.Model.Prompts.GetValueOrDefault(key)?.Lines.Count > 0 &&
                                    plugin.Model.Prompts[key].Lines[0].Text == "new", "the parse of the new prompt");
        plugin.Show(new HerdrOutput("w5:p1"), "pc", null, old);
        // A late parse of the old prompt changes nothing.
        Assert.Equal(["new"], plugin.Model.Prompts[key].Lines.Select(l => l.Text));
    }

    [Fact]
    public async Task AnOutputThatNobodyAskedForIsDropped()
    {
        var plugin = new HerdrPlugin();
        plugin.Receive(Msg("""{"kind":"output","pane":"w5:p1","text":"x"}"""), "pc", "desk");
        await Task.Delay(200);
        Assert.Empty(plugin.Model.Prompts);
        Assert.Empty(plugin.Model.Outputs);
    }
}
