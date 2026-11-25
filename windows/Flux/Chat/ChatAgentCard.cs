using System.Collections.Immutable;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using FluxKit;

namespace Flux;

// The answers that the cards of the tray panel sent to the agents, by
// computer and pane. An answer shows on the card of the agent while the
// agent works on it, for 10 minutes at most. The item of an agent changes
// when its status changes, so the answers live here and not in the card.
// ChatAnswers of the Mac app has the same rules.
public sealed class ChatAnswers : Model
{
    public static ChatAnswers Shared { get; } = new();

    sealed record Entry(string Text, bool Working, DateTimeOffset At);

    ImmutableDictionary<string, Entry> entries = ImmutableDictionary<string, Entry>.Empty;

    static string Key(string deviceId, string pane) => deviceId + "|" + pane;

    // Keeps the answer text to the agent in pane.
    public void Sent(string text, string deviceId, string pane)
    {
        entries = entries.SetItem(Key(deviceId, pane), new Entry(text, false, DateTimeOffset.Now));
        Changed();
    }

    // The answer to show for the agent in pane, or null.
    public string? Answer(string deviceId, string pane) =>
        entries.TryGetValue(Key(deviceId, pane), out var e) && e.Working && DateTimeOffset.Now - e.At < TimeSpan.FromMinutes(10) ? e.Text : null;

    // The agent in pane has a new status. The answer shows while the agent
    // works, and goes when the agent stops working.
    public void Status(AgentStatus status, string deviceId, string pane)
    {
        var key = Key(deviceId, pane);
        if (!entries.TryGetValue(key, out var e))
        {
            return;
        }
        if (status == AgentStatus.Working)
        {
            if (!e.Working)
            {
                entries = entries.SetItem(key, e with { Working = true });
                Changed();
            }
        }
        else if (e.Working)
        {
            entries = entries.Remove(key);
            Changed();
        }
    }
}

// The cards of the Inbox items in the tray panel, by the key of the item. A
// card of an agent keeps its state while its item stays, so that a drawing
// of the panel does not read the output again.
public sealed class EventCards(AppModel model)
{
    readonly Dictionary<string, ChatAgentCard> agents = [];

    // The card of the item at the time at.
    public UIElement Card(InboxItem item, DateTimeOffset at)
    {
        switch (item.Content)
        {
            case InboxContent.Agent:
                if (agents.TryGetValue(item.Key, out var card))
                {
                    card.Update(item, at);
                }
                else
                {
                    agents[item.Key] = card = new ChatAgentCard(model, item, at);
                }
                return card;
            case InboxContent.Pair p when model.DeviceOf(p.DeviceId) is { } d:
                return Cards.PairCard(model, d, at);
            case InboxContent.Approval a:
                return ApproveCards.ApprovalCard(model, item, a.Request, at);
            default:
                return Cards.InCard(Cards.Head(item.StateWord, item.Tone.Brush(), string.Join(" · ", item.SourceParts), Texts.ClockTime(at)),
                    item.Title, ask: item.Kind.NeedsYou());
        }
    }

    // Forgets the cards of the items that are gone.
    public void Keep(IEnumerable<string> keys)
    {
        var live = keys.ToHashSet();
        foreach (var key in agents.Keys.Where(k => !live.Contains(k)).ToArray())
        {
            agents.Remove(key);
        }
    }
}

// An agent in the tray panel: what it waits for, what it works on, or that
// it is done. The rules of an agent that waits:
// - The card reads the output when it shows and when its window comes to
//   the front. Only an output that comes after that read is fresh, and only
//   a fresh output gives choices.
// - The question keeps the lines nearest the choices, and it is never cut.
// - Each answer asks for Windows Hello first, see ReplyLock.
// - After an answer, the choices stay off until a new output comes.
// - A choice that rejects the action opens the chat of the agent in the
//   main window, where the user writes what the agent must do.
// ChatAgentCard of the Mac app has the same rules.
public sealed class ChatAgentCard : View
{
    readonly AppModel model;
    readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(1) };
    readonly TextBlock detailText = Ui.Text("", 12, color: Tn.Current.Sub, mono: true, wrap: true);
    InboxItem item;
    DateTimeOffset at;
    // True after this card asked for the output.
    bool didRead;
    // The output that the user answered.
    HerdrOutput? answered;
    string? lockError;
    Window? host;
    // The last parse of the output, so that a drawing parses only a new output.
    HerdrOutput? parsed;
    AgentThread? thread;
    AgentAsk? ask;

    public ChatAgentCard(AppModel model, InboxItem item, DateTimeOffset at)
    {
        this.model = model;
        this.item = item;
        this.at = at;
        Watch(model);
        Watch(Plugin?.Model);
        Watch(ChatAnswers.Shared);
        clock.Tick += (_, _) => detailText.Text = Detail();
        Loaded += (_, _) =>
        {
            host = Window.GetWindow(this);
            if (host is not null)
            {
                host.Activated += OnFront;
            }
            if (!didRead)
            {
                Read();
            }
            if (Agent.Status == AgentStatus.Working)
            {
                clock.Start();
            }
        };
        Unloaded += (_, _) =>
        {
            if (host is not null)
            {
                host.Activated -= OnFront;
            }
            host = null;
            clock.Stop();
        };
        ChatAnswers.Shared.Status(Agent.Status, DeviceId, Agent.Pane);
        Redraw();
    }

    HerdrPlugin? Plugin => model.Core.Plugin<HerdrPlugin>();
    InboxContent.Agent AgentItem => (InboxContent.Agent)item.Content;
    HerdrAgent Agent => AgentItem.Value;
    string DeviceId => AgentItem.DeviceId;

    // Takes the item again after a drawing of the thread. The key stays, so
    // the title or the time can change.
    public void Update(InboxItem next, DateTimeOffset time)
    {
        if (next == item && time == at)
        {
            return;
        }
        item = next;
        at = time;
        Redraw();
    }

    // Only an agent that waits or works reads its output, as on Android. A
    // read of an idle pane makes herdr scroll it.
    void Read()
    {
        if (Agent.Status is not (AgentStatus.Blocked or AgentStatus.Working) || Plugin is not { } plugin)
        {
            return;
        }
        plugin.ReadPrompt(DeviceId, Agent.Pane);
        didRead = true;
    }

    // A window that comes to the front reads the output again.
    void OnFront(object? sender, EventArgs e) => Read();

    // The output when it came after the read of this card, else null.
    HerdrOutput? Fresh()
    {
        if (!didRead || Plugin?.Model.Prompt(DeviceId, Agent.Pane) is not { Loading: false, Error: null } output)
        {
            return null;
        }
        return output;
    }

    // Parses a new output for the question or the thread.
    void Parse(HerdrOutput? fresh)
    {
        if (ReferenceEquals(fresh, parsed))
        {
            return;
        }
        parsed = fresh;
        var texts = fresh?.Lines.Select(l => l.Text).ToArray();
        var blocked = Agent.Status == AgentStatus.Blocked;
        ask = blocked && texts is not null ? AgentAsk.Find(texts, 4) : null;
        thread = !blocked && texts is not null ? AgentThread.Parse(texts) : null;
    }

    // The line under the title: the answer, the step, and the time of a
    // working agent. A done agent reads no output, so it shows that it waits
    // for the next prompt.
    string Detail()
    {
        switch (Agent.Status)
        {
            case AgentStatus.Blocked:
                return "";
            case AgentStatus.Working:
                var answer = ChatAnswers.Shared.Answer(DeviceId, Agent.Pane) is { } a ? $"You answered: {a}" : "";
                var since = Plugin?.Model.AgentSince(DeviceId, Agent.Pane);
                var elapsed = since is { } s ? AgentTime.When(AgentStatus.Working, s, DateTimeOffset.Now) : thread?.Elapsed ?? "";
                var parts = new[] { answer, thread?.Step ?? "", elapsed }.Where(p => p.Length > 0).ToArray();
                return parts.Length == 0 ? "Working" : string.Join(" · ", parts);
            default:
                var worked = thread?.Worked ?? "";
                return worked.Length == 0 ? "Waits for the next prompt" : $"Done in {worked}";
        }
    }

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        var plugin = Plugin;
        var blocked = Agent.Status == AgentStatus.Blocked;
        var output = plugin?.Model.Prompt(DeviceId, Agent.Pane);
        var fresh = Fresh();
        Parse(fresh);
        var choices = blocked && fresh is not null ? fresh.Choices : ValueList<AgentChoice>.Empty;
        var reply = plugin?.Model.Reply(DeviceId, Agent.Pane);
        var sending = reply?.Sending == true;
        var many = model.Scope is null && model.Paired.Count > 1;
        var source = string.Join(" · ", item.SourceParts.Concat(many ? [item.Computer] : []));
        var extra = new List<UIElement?>();
        if (blocked)
        {
            if (output?.Error is { } error)
            {
                extra.Add(Ui.Text(error, 12, color: tn.Red, wrap: true));
            }
            else if (ask is not null)
            {
                // No line limit: the command that a choice approves shows in full.
                if (!ask.Command && ask.Question.Length > 0)
                {
                    extra.Add(Ui.Text(ask.Question, 13, wrap: true));
                }
                if (ask.Lines.Count > 0)
                {
                    extra.Add(PromptLines(ask.Lines));
                }
            }
            else if (fresh is not null)
            {
                var prompt = FluxKit.Inbox.AgentPrompt(fresh.Lines.Select(l => l.Text).ToArray(), 4);
                if (prompt.Length > 0)
                {
                    extra.Add(PromptLines(prompt.Split('\n')));
                }
            }
            else
            {
                extra.Add(AgentParts.Skeleton([0.8, 0.55], "Reading the question"));
            }
            if (fresh is not null && choices.Count > 0)
            {
                var open = AgentItem.Control && !sending && fresh != answered;
                var buttons = choices.Select((c, i) => (UIElement)AgentParts.AskChoiceButton(c, i == 0, open, () => Answer(c, fresh), 40));
                extra.Add(Ui.V(6, buttons).Margin(0, 6, 0, 0));
            }
            if ((lockError ?? reply?.Error) is { } problem)
            {
                extra.Add(Ui.Text(problem, 12, color: tn.Red, wrap: true));
            }
            if (!AgentItem.Control)
            {
                extra.Add(Ui.Text($"To answer from this computer, turn on Agent control in Flux on {item.Computer}, on the Access card.", 12, color: tn.Sub, wrap: true));
            }
            if (sending)
            {
                extra.Add(Ui.H(8, Parts.Spinner(14), Ui.Text("Sending", 12, color: tn.Sub)));
            }
        }
        else
        {
            detailText.Text = Detail();
            detailText.Foreground = tn.Sub;
            extra.Add(detailText);
        }
        if (Agent.Status == AgentStatus.Working)
        {
            clock.Start();
        }
        else
        {
            clock.Stop();
        }
        var card = Cards.InCard(Cards.Head(item.StateWord, item.Tone.Brush(), source, Texts.ClockTime(at), AgentParts.StatusMark(Agent.Status, 8, 11)),
            item.Title, ask: blocked, extra: extra.Count == 0 ? null : Ui.V(6, extra), action: choices.Count > 0 ? null : OpenAction());
        return card;
    }

    // The command or the question in mono, in the second ink. The lines are never cut.
    static UIElement PromptLines(IReadOnlyList<string> lines) =>
        Ui.SelectableText(string.Join("\n", lines), 12, color: Tn.Current.Sub);

    // Open thread. The choices take its place.
    UIElement OpenAction() => Cards.TextAction("Open thread", OpenChat, "Open the chat of the agent in Flux");

    // Shows the chat of the agent in the main window.
    void OpenChat()
    {
        model.OpenChat(new ChatKey.Agent(DeviceId, Agent.Pane));
        model.ShowMain?.Invoke();
    }

    // Sends the keys of the choice after Windows Hello. The question on
    // screen must still be the question that the user read. A choice that
    // rejects the action opens the chat of the agent, where the dock shows
    // the same question and the field for the text.
    void Answer(AgentChoice choice, HerdrOutput output)
    {
        if (answered == output)
        {
            return;
        }
        if (Chat.IsTellChoice(choice))
        {
            OpenChat();
            return;
        }
        lockError = null;
        var deviceId = DeviceId;
        var pane = Agent.Pane;
        // The tray panel hides when Windows Hello takes the focus, so the prompt belongs to the main window.
        var owner = Application.Current?.MainWindow;
        ReplyLock.Run($"answer agents on {item.Computer}", owner, () =>
        {
            if (Plugin is not { } plugin || answered == output)
            {
                return;
            }
            if (!Equals(plugin.Model.Prompt(deviceId, pane)?.Lines, output.Lines))
            {
                lockError = "The question changed. Read it, then answer again.";
                Invalidate();
                return;
            }
            answered = output;
            ChatAnswers.Shared.Sent(choice.Label, deviceId, pane);
            plugin.SendKeys(deviceId, pane, choice.Keys);
            Invalidate();
        }, message =>
        {
            lockError = message;
            Invalidate();
        });
    }
}
