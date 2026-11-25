namespace FluxKit;

// The kinds of Inbox items. The first 3 kinds need the user: an agent that
// waits for input, an approval, and a pair request. The agents that are done
// or that work follow. The chat shows the items in the order of their time,
// see Chat.Entries. Nothing stores the order. InboxItem.swift of the Mac app
// has the same kinds.
public enum InboxKind
{
    AgentInput,
    Approval,
    PairRequest,
    AgentDone,
    AgentWorking,
}

public static class InboxKinds
{
    // True for the kinds that need the user.
    public static bool NeedsYou(this InboxKind kind) => kind is InboxKind.AgentInput or InboxKind.Approval or InboxKind.PairRequest;

    // "AgentInput", "Approval", "PairRequest", "AgentDone", or
    // "AgentWorking", as on Android. Item keys use it.
    public static string KeyName(this InboxKind kind) => kind switch
    {
        InboxKind.AgentInput => "AgentInput",
        InboxKind.Approval => "Approval",
        InboxKind.PairRequest => "PairRequest",
        InboxKind.AgentDone => "AgentDone",
        _ => "AgentWorking",
    };
}

// The color role of the state of an item. The apps map it to the palette.
// Red marks only what needs the user and errors.
public enum InboxTone
{
    Red,
    Green,
    Accent,
    Cyan,
    Sub,
}

// What an Inbox item is about. Each content gives its kind, its key, its
// computers, and its texts: an agent, an approval, or a pair request.
public abstract record InboxContent
{
    public abstract InboxKind Kind { get; }

    // The key of the item. See InboxItem.Key.
    public abstract string Key { get; }

    // The computers of the item. An item with none shows in every scope.
    public abstract IReadOnlyList<string> DeviceIds { get; }

    // The state as a short word in sentence case.
    public abstract string StateWord { get; }

    // The source parts before the blank parts go, see InboxItem.SourceParts.
    public abstract IReadOnlyList<string> Source { get; }

    // The title of the card. computer is the name of the computer of the item.
    public abstract string Title(string computer);

    // A herdr agent that waits for input, finished, or works. Control is
    // true when the computer takes replies.
    public sealed record Agent(string DeviceId, HerdrAgent Value, bool Control) : InboxContent
    {
        public override InboxKind Kind => Value.Status switch
        {
            AgentStatus.Blocked => InboxKind.AgentInput,
            AgentStatus.Done => InboxKind.AgentDone,
            _ => InboxKind.AgentWorking,
        };

        // A new status of an agent is a new key, so an agent with a new
        // status is a new chat entry.
        public override string Key => $"agent|{DeviceId}|{Value.Pane}|{Kind.KeyName()}";

        public override IReadOnlyList<string> DeviceIds => [DeviceId];

        public override string StateWord => Kind switch
        {
            InboxKind.AgentInput => "Needs input",
            InboxKind.AgentDone => "Done",
            _ => "Working",
        };

        public override IReadOnlyList<string> Source => [Value.Agent, Value.Project.Length == 0 ? Value.Workspace : Value.Project];

        public override string Title(string computer)
        {
            if (Value.Title.Length > 0)
            {
                return Value.Title;
            }
            return Value.Project.Length == 0 ? Value.Pane : Value.Project;
        }
    }

    // A sudo, polkit, or enrollment request that waits for Windows Hello.
    // The approval feature gives the open request, see ApproveModel.Current.
    public sealed record Approval(ApproveRequest Request) : InboxContent
    {
        public override InboxKind Kind => InboxKind.Approval;
        public override string Key => $"approve|{Request.ComputerId}|{Request.Id}";
        public override IReadOnlyList<string> DeviceIds => [Request.ComputerId];
        public override string StateWord => "Needs approval";
        public override IReadOnlyList<string> Source => [Request.Service];

        // "Approve sudo on omarchy-xps?", or the enrollment form.
        public override string Title(string computer) => ApproveTexts.Title(Request);
    }

    // A computer that is not paired and asks to pair. It has no computers,
    // so it shows in every scope.
    public sealed record Pair(string DeviceId) : InboxContent
    {
        public override InboxKind Kind => InboxKind.PairRequest;
        public override string Key => "pair|" + DeviceId;
        public override IReadOnlyList<string> DeviceIds => [];
        public override string StateWord => "Pair request";
        public override IReadOnlyList<string> Source => [];
        public override string Title(string computer) => $"{computer} asks to pair";
    }
}

// 1 item of the Inbox: something on a computer that has a state now. Key
// stays the same while the item is the same, so the UI keeps its place.
// Computer is the name of the computer.
public sealed record InboxItem(InboxContent Content, string Computer)
{
    public InboxKind Kind => Content.Kind;

    public string Key => Content.Key;

    // The computers of the item. An item with no computers shows in every scope.
    public IReadOnlyList<string> DeviceIds => Content.DeviceIds;

    // The state as a short word in sentence case, for the top row of a card
    // and for a screen reader.
    public string StateWord => Content.StateWord;

    // The color role of the state dot and the state word.
    public InboxTone Tone => Kind.NeedsYou() ? InboxTone.Red : Kind == InboxKind.AgentDone ? InboxTone.Green : InboxTone.Accent;

    // The source of the item for the top row of its card, without the
    // computer: for example the agent and its project. Blank parts go.
    public IReadOnlyList<string> SourceParts => Content.Source.Where(p => p.Trim().Length > 0).ToArray();

    // The title of the card of the item.
    public string Title => Content.Title(Computer);
}
