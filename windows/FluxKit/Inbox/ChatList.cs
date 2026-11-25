namespace FluxKit;

// 1 row of the Chats list. Id stays the same while the row is the same, so
// the list keeps its place. It is a port of ChatList.swift of the Mac app
// and ChatList.kt of the Android app.
public abstract record ChatRow
{
    // The ID of the row.
    public abstract string Id { get; }

    // The time of the row. A computer with no entry has DateTimeOffset.MinValue.
    public abstract DateTimeOffset At { get; }

    // The key that SeenClock keeps for the row. An agent with a new status is new.
    internal virtual string SeenKey => Id;

    // A sudo, polkit, or enrollment request that waits for Windows Hello.
    // The list shows it as a card with Deny and Approve.
    public sealed record Approval(ApproveRequest Request, DateTimeOffset Time) : ChatRow
    {
        public override string Id => $"approve|{Request.ComputerId}|{Request.Id}";
        public override DateTimeOffset At => Time;
    }

    // A computer that is not paired and asks to pair. ComputerName is its name.
    public sealed record Pair(string DeviceId, string ComputerName, DateTimeOffset Time) : ChatRow
    {
        public override string Id => "pair|" + DeviceId;
        public override DateTimeOffset At => Time;
    }

    // A herdr agent on the computer ComputerName: 1 chat. Time is the start
    // of its status. Control is true when the computer takes replies.
    public sealed record Agent(string DeviceId, string ComputerName, HerdrAgent Value, bool Control, DateTimeOffset Time) : ChatRow
    {
        public override string Id => $"agent|{DeviceId}|{Value.Pane}";
        public override DateTimeOffset At => Time;
        internal override string SeenKey => $"{Id}|{Value.Status.Wire()}";
    }

    // A paired computer: 1 chat. Last is the newest entry of its chat, or
    // the newest entry that matches the search.
    public sealed record Computer(DeviceSnapshot Device, ChatEntry? Last) : ChatRow
    {
        public override string Id => "computer|" + Device.Id;
        public override DateTimeOffset At => Last?.At ?? DateTimeOffset.MinValue;
    }
}

// The rows of the Chats list in 3 groups. Needs holds the approvals, the
// pair requests, and the agents that wait for input, the newest first.
// Agents holds the other agents: the agents that work, then the agents that
// are done, then the idle agents. Computers holds the paired computers, the
// online computers first.
public sealed record ChatList(ValueList<ChatRow> Needs, ValueList<ChatRow> Agents, ValueList<ChatRow> Computers)
{
    public static readonly ChatList Empty = new(ValueList<ChatRow>.Empty, ValueList<ChatRow>.Empty, ValueList<ChatRow>.Empty);

    public bool IsEmpty => Needs.Count == 0 && Agents.Count == 0 && Computers.Count == 0;
}

// The texts of a chat entry for the list of chats.
public static class ChatEntryTexts
{
    // The text of the entry for the search: the link or the text, the file
    // name, the clip, or the service of an answer. An event has none.
    public static string? Text(this ChatEntry entry) => entry switch
    {
        ChatEntry.Sent s => s.Item.Text,
        ChatEntry.File f => f.Transfer.Name,
        ChatEntry.Clip c => c.Value.Preview,
        ChatEntry.Answer a => a.Record.Request?.Service ?? a.Record.Summary,
        _ => null,
    };

    // The entry in 1 line for the list of chats, such as "You: Dinner at 7"
    // or "invoice-0042.pdf". Windows syncs no images, so a clip is text.
    public static string Preview(this ChatEntry entry)
    {
        var flat = (entry.Text() ?? "").Replace('\n', ' ');
        switch (entry)
        {
            case ChatEntry.Sent s:
                return s.Item.Kind == SentKind.ClipImage ? "You: an image" : "You: " + flat;
            case ChatEntry.File { Transfer: var t }:
                if (t.Incoming)
                {
                    return t.State == TransferState.Running ? "Receiving " + flat : flat;
                }
                return t.State switch
                {
                    TransferState.Running => "You: sending " + flat,
                    TransferState.Done => "You: " + flat,
                    _ => "You: not sent, " + flat,
                };
            case ChatEntry.Clip:
                return "Clipboard: " + flat;
            case ChatEntry.Answer a:
                return a.Record.Outcome.Kind switch
                {
                    ApproveOutcomeKind.Approved or ApproveOutcomeKind.Enrolled => "Approved " + flat,
                    ApproveOutcomeKind.Denied => "Denied " + flat,
                    _ => flat,
                };
            default:
                return "";
        }
    }
}

// The list of chats: 1 chat for each agent and each paired computer.
public static class Chats
{
    // The order of an agent in the Agents group: the agents that work first, then the agents that are done.
    static int Rank(AgentStatus s) => s switch
    {
        AgentStatus.Working => 0,
        AgentStatus.Done => 1,
        _ => 2,
    };

    // True when query is empty or when 1 of fields holds it, without case.
    static bool Matches(string query, params string?[] fields) =>
        query.Length == 0 || fields.Any(f => f?.Contains(query, StringComparison.OrdinalIgnoreCase) == true);

    // Builds the Chats list: 1 chat for each agent and each paired computer,
    // and the approval and the pair requests on top. A computer that is not
    // reachable adds no agents. An agent takes the start time of its status
    // from since, by computer and pane, and an approval the time of its
    // request. Any other row with no time takes the time that seen first saw
    // it at now. log holds the chat entries of all computers, see
    // Chat.Entries, and gives each computer its newest entry. A query keeps
    // only the rows that hold it: a computer also stays when an entry of its
    // chat holds it, and that entry shows.
    public static ChatList List(IEnumerable<DeviceSnapshot> devices, IReadOnlyDictionary<string, HerdrState> herdr, ApproveRequest? approval,
                                IEnumerable<ChatEntry> log, Func<string, string, DateTimeOffset?> since, SeenClock seen, DateTimeOffset now,
                                string query = "")
    {
        var q = query.Trim();
        var all = devices.ToArray();
        var paired = all.Where(d => d.Paired).ToArray();
        var rows = new List<ChatRow>();
        if (approval is not null && paired.Any(d => d.Id == approval.ComputerId))
        {
            rows.Add(new ChatRow.Approval(approval, approval.Time > 0 ? DateTimeOffset.FromUnixTimeSeconds(approval.Time) : DateTimeOffset.MinValue));
        }
        foreach (var d in all.Where(d => !d.Paired && d.PairState == PairState.Incoming))
        {
            rows.Add(new ChatRow.Pair(d.Id, d.Name, DateTimeOffset.MinValue));
        }
        foreach (var d in paired)
        {
            if (!d.Online || !herdr.TryGetValue(d.Id, out var h) || !h.Running)
            {
                continue;
            }
            var panes = new HashSet<string>();
            foreach (var a in h.Agents.Where(a => panes.Add(a.Pane)))
            {
                rows.Add(new ChatRow.Agent(d.Id, d.Name, a, h.Control, since(d.Id, a.Pane) ?? DateTimeOffset.MinValue));
            }
        }
        var times = seen.Update(rows.Select(r => r.SeenKey), now);
        var timed = rows.Select(r =>
        {
            var first = times.TryGetValue(r.SeenKey, out var t) ? t : now;
            return r switch
            {
                ChatRow.Approval a when a.Time == DateTimeOffset.MinValue => a with { Time = first },
                ChatRow.Pair p => p with { Time = first },
                ChatRow.Agent a when a.Time == DateTimeOffset.MinValue => a with { Time = first },
                _ => r,
            };
        }).Where(r => r switch
        {
            ChatRow.Approval a => Matches(q, a.Request.Service, a.Request.Host, a.Request.ComputerName, a.Request.User),
            ChatRow.Pair p => Matches(q, p.ComputerName),
            ChatRow.Agent a => Matches(q, a.Value.Title, a.Value.Agent, a.Value.Project, a.Value.Workspace, a.Value.Pane, a.ComputerName),
            _ => true,
        }).ToArray();
        // OrderBy is stable, so rows with the same time keep their order.
        var needs = timed.Where(r => r is not ChatRow.Agent a || a.Value.Status == AgentStatus.Blocked).OrderByDescending(r => r.At);
        var agents = timed.OfType<ChatRow.Agent>().Where(a => a.Value.Status != AgentStatus.Blocked)
            .OrderBy(a => Rank(a.Value.Status)).ThenByDescending(a => a.At);
        var entries = log.Where(e => e is not ChatEntry.Event).ToArray();
        var computers = new List<ChatRow.Computer>();
        foreach (var d in paired)
        {
            var mine = entries.Where(e => e.Shows(d.Id));
            var named = Matches(q, d.Name);
            // MaxBy keeps the first of the entries with the same time, and gives null for none.
            var last = (named ? mine : mine.Where(e => Matches(q, e.Text()))).MaxBy(e => e.At);
            if (q.Length > 0 && last is null && !named)
            {
                continue;
            }
            computers.Add(new ChatRow.Computer(d, last));
        }
        var sorted = computers.OrderByDescending(c => c.Device.Online).ThenByDescending(c => c.At)
            .ThenBy(c => c.Device.Name.ToLowerInvariant(), StringComparer.Ordinal);
        return new ChatList(ValueList.From(needs), ValueList.From<ChatRow>(agents), ValueList.From<ChatRow>(sorted));
    }
}
