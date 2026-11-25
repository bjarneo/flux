using System.Collections.Immutable;
using System.Text.Json.Nodes;

namespace FluxKit;

// The herdr agents of each computer for the UI. HerdrPlugin changes it on
// the UI thread. Each property is an immutable dictionary by device ID, and
// a change sets a new dictionary.
public sealed class HerdrModel : Model
{
    ImmutableDictionary<string, HerdrState> states = ImmutableDictionary<string, HerdrState>.Empty;
    ImmutableDictionary<string, HerdrOutput> outputs = ImmutableDictionary<string, HerdrOutput>.Empty;
    ImmutableDictionary<string, HerdrReply> replies = ImmutableDictionary<string, HerdrReply>.Empty;
    ImmutableDictionary<string, HerdrAction> actions = ImmutableDictionary<string, HerdrAction>.Empty;
    ImmutableDictionary<string, FirstTask> firstTasks = ImmutableDictionary<string, FirstTask>.Empty;
    ImmutableDictionary<string, HerdrOutput> prompts = ImmutableDictionary<string, HerdrOutput>.Empty;
    ImmutableDictionary<string, ImmutableDictionary<string, DateTimeOffset>> since =
        ImmutableDictionary<string, ImmutableDictionary<string, DateTimeOffset>>.Empty;
    ImmutableDictionary<string, DateTimeOffset> outputTimes = ImmutableDictionary<string, DateTimeOffset>.Empty;
    ImmutableDictionary<string, string> sessionChoices = ImmutableDictionary<string, string>.Empty;
    bool inputAlerts = true;
    bool doneAlerts = true;
    string dictationLanguage = "";
    FluxSettings? settings;

    // The agents of each computer by device ID. A computer has no entry
    // before its first agent list.
    public ImmutableDictionary<string, HerdrState> States { get => states; internal set => Set(ref states, value); }

    // The output of the agent that the agent screen of a computer shows.
    public ImmutableDictionary<string, HerdrOutput> Outputs { get => outputs; internal set => Set(ref outputs, value); }

    // The last reply from the agent screen of a computer.
    public ImmutableDictionary<string, HerdrReply> Replies { get => replies; internal set => Set(ref replies, value); }

    // The last new agent, new terminal, or close on a computer.
    public ImmutableDictionary<string, HerdrAction> Actions { get => actions; internal set => Set(ref actions, value); }

    // The first task of the last new agent on a computer.
    public ImmutableDictionary<string, FirstTask> FirstTasks { get => firstTasks; internal set => Set(ref firstTasks, value); }

    // The output that the Inbox reads for the question of 1 agent, by
    // PromptKey. It is apart from Outputs, so that the Inbox and an agent
    // screen do not replace each other's output.
    public ImmutableDictionary<string, HerdrOutput> Prompts { get => prompts; internal set => Set(ref prompts, value); }

    // The time that each agent got its status, by device ID and pane. See AgentClock.
    public ImmutableDictionary<string, ImmutableDictionary<string, DateTimeOffset>> Since { get => since; internal set => Set(ref since, value); }

    // The time that the agent screen took the last output of each pane, by
    // PromptKey. The note of a thread shows it. The time is not part of
    // HerdrOutput, so that 2 reads with the same lines stay equal.
    public ImmutableDictionary<string, DateTimeOffset> OutputTimes { get => outputTimes; internal set => Set(ref outputTimes, value); }

    // The herdr session that the user picked for the agent list of each
    // computer, by device ID. A computer without an entry shows the default
    // session. The choice stays while its session is gone, and the list
    // shows the default session meanwhile, see Session.
    public ImmutableDictionary<string, string> SessionChoices { get => sessionChoices; internal set => Set(ref sessionChoices, value); }

    // Notify when an agent on a computer needs input. It applies to all computers.
    public bool InputAlerts
    {
        get => inputAlerts;
        set
        {
            Set(ref inputAlerts, value);
            settings?.Set(HerdrPlugin.InputAlertsKey, value);
        }
    }

    // Notify when an agent on a computer finishes. It applies to all computers.
    public bool DoneAlerts
    {
        get => doneAlerts;
        set
        {
            Set(ref doneAlerts, value);
            settings?.Set(HerdrPlugin.DoneAlertsKey, value);
        }
    }

    // The dictation language as a tag such as de-DE. Empty means Automatic.
    public string DictationLanguage
    {
        get => dictationLanguage;
        set
        {
            Set(ref dictationLanguage, value);
            settings?.Set(HerdrPlugin.DictationLanguageKey, value);
        }
    }

    // Opens the output of an agent: the device ID and the pane. The app sets
    // it, and a click on an agent notification calls it.
    public Action<string, string>? Open { get; set; }

    internal void Load(FluxSettings settings)
    {
        InputAlerts = settings.Bool(HerdrPlugin.InputAlertsKey, true);
        DoneAlerts = settings.Bool(HerdrPlugin.DoneAlertsKey, true);
        DictationLanguage = settings.String(HerdrPlugin.DictationLanguageKey) ?? "";
        var choices = ImmutableDictionary.CreateBuilder<string, string>();
        if (settings.Node(HerdrPlugin.SessionsKey) is JsonObject o)
        {
            foreach (var (id, value) in o)
            {
                if (Json.String(value) is { } name)
                {
                    choices[id] = name;
                }
            }
        }
        SessionChoices = choices.ToImmutable();
        this.settings = settings;
    }

    // The herdr session that the agent list of a computer shows: the picked
    // session while the computer has it, else the default session. Null
    // before the first agent list.
    public HerdrSession? Session(string deviceId) =>
        States.TryGetValue(deviceId, out var s) ? s.Session(SessionChoices.GetValueOrDefault(deviceId)) : null;

    // The agents, terminals, and workspaces of a computer in the session
    // that its agent list shows, see HerdrState.ScopedTo. Null before the
    // first agent list.
    public HerdrState? Scoped(string deviceId) =>
        States.TryGetValue(deviceId, out var s) ? s.ScopedTo(SessionChoices.GetValueOrDefault(deviceId)) : null;

    // Scoped of each computer, by device ID.
    public IReadOnlyDictionary<string, HerdrState> ScopedStates =>
        States.ToDictionary(e => e.Key, e => e.Value.ScopedTo(SessionChoices.GetValueOrDefault(e.Key)));

    // The session for a new workspace on a computer, for HerdrPlugin.Create:
    // the name of the shown session, or empty for the default session.
    public string CreateSession(string deviceId) => Session(deviceId) is { IsDefault: false } s ? s.Name : "";

    // Shows the herdr session name in the agent list of a computer. This
    // device keeps the choice.
    public void SelectSession(string deviceId, string name)
    {
        var known = States.GetValueOrDefault(deviceId)?.Sessions.FirstOrDefault(s => s.Name == name);
        var isDefault = known?.IsDefault ?? name == HerdrSession.DefaultName;
        string? next = isDefault ? null : name;
        if (SessionChoices.GetValueOrDefault(deviceId) == next)
        {
            return;
        }
        SessionChoices = next is null ? SessionChoices.Remove(deviceId) : SessionChoices.SetItem(deviceId, next);
        var node = new JsonObject();
        foreach (var (id, choice) in SessionChoices)
        {
            node[id] = choice;
        }
        settings?.Set(HerdrPlugin.SessionsKey, node);
    }

    // Shows the session of pane in the agent list of a computer, so that the
    // list has the agent that a notification opens.
    public void Reveal(string deviceId, string pane)
    {
        if (!States.TryGetValue(deviceId, out var state))
        {
            return;
        }
        var name = state.Agent(pane)?.Session ?? state.Terminal(pane)?.Session;
        if (name is null || name == Session(deviceId)?.Name)
        {
            return;
        }
        SelectSession(deviceId, name);
    }

    // The output of pane on a computer, or null when the agent screen shows no output of it.
    public HerdrOutput? Output(string deviceId, string pane) =>
        Outputs.TryGetValue(deviceId, out var o) && o.Pane == pane ? o : null;

    // The time of the last output of pane on a computer, or null when this device has none.
    public DateTimeOffset? OutputAt(string deviceId, string pane) =>
        OutputTimes.TryGetValue(PromptKey(deviceId, pane), out var at) ? at : null;

    // The last reply to pane on a computer.
    public HerdrReply? Reply(string deviceId, string pane) =>
        Replies.TryGetValue(deviceId, out var r) && r.Pane == pane ? r : null;

    // The time that the agent in pane on a computer got its status, or null when this device did not see it.
    public DateTimeOffset? AgentSince(string deviceId, string pane) =>
        Since.TryGetValue(deviceId, out var times) && times.TryGetValue(pane, out var at) ? at : null;

    // The key of the prompt of pane on a computer in Prompts.
    public static string PromptKey(string deviceId, string pane) => deviceId + "|" + pane;

    // The output that the Inbox read for pane on a computer, or null before the first read.
    public HerdrOutput? Prompt(string deviceId, string pane) => Prompts.GetValueOrDefault(PromptKey(deviceId, pane));
}
