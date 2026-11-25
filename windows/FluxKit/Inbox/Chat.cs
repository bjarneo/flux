using System.Collections.Immutable;
using System.Text.RegularExpressions;

namespace FluxKit;

// 1 entry of the chat. The computers write the files that come in, the last
// clip, the answers to approvals, and the Inbox items. This device writes the
// links, texts, clips, and files that it sent. Chat.swift of the Mac app has
// the same entries.
public abstract record ChatEntry
{
    // The ID of the entry. It stays the same while the entry is the same.
    public abstract string Id { get; }

    // The time of the entry.
    public abstract DateTimeOffset At { get; }

    // True when the entry shows in scope, or always when scope is null.
    public abstract bool Shows(string? scope);

    // A link, a text, a scan, or a clip that this device sent.
    public sealed record Sent(SentItem Item) : ChatEntry
    {
        public override string Id => "sent|" + Item.Id;
        public override DateTimeOffset At => Item.At;
        public override bool Shows(string? scope) => scope is null || Item.DeviceId == scope;
    }

    // A file, in either direction.
    public sealed record File(FileTransfer Transfer) : ChatEntry
    {
        public override string Id => "file|" + Transfer.Id;
        public override DateTimeOffset At => Transfer.Started;
        public override bool Shows(string? scope) => scope is null || Transfer.DeviceId == scope;
    }

    // The last clip from a computer.
    public sealed record Clip(ClipEvent Value) : ChatEntry
    {
        public override string Id => "clip";
        public override DateTimeOffset At => Value.At;
        public override bool Shows(string? scope) => scope is null || Value.DeviceIds.Contains(scope);
    }

    // The answer of this device to an approval. It takes the time that the
    // answer ended.
    public sealed record Answer(ApproveRecord Record) : ChatEntry
    {
        public override string Id => "answer|" + Record.Id;
        public override DateTimeOffset At => Record.Resolved ?? Record.Received;
        public override bool Shows(string? scope) => scope is null || Record.ComputerId == scope;
    }

    // An agent, an approval, or a pair request, at the time Time that it got its state.
    public sealed record Event(InboxItem Item, DateTimeOffset Time) : ChatEntry
    {
        public override string Id => Item.Key;
        public override DateTimeOffset At => Time;

        // A pair request shows in every scope.
        public override bool Shows(string? scope) => scope is null || Item.DeviceIds.Count == 0 || Item.DeviceIds.Contains(scope);
    }
}

// Keeps the first time that the chat showed each Inbox item, for the items
// whose start is not known: an approval, a pair request, and an agent whose
// status started before this device connected, see AgentClock. It forgets
// an item that is gone for more than Grace, so that an item that comes back
// after a short disconnect keeps its place.
public sealed class SeenClock(TimeSpan? grace = null)
{
    readonly Dictionary<string, DateTimeOffset> first = [];
    readonly Dictionary<string, DateTimeOffset> goneAt = [];

    // How long the clock keeps the time of an item that is gone, 10 minutes by default.
    public TimeSpan Grace { get; } = grace ?? TimeSpan.FromMinutes(10);

    // Takes the keys of the items at the time now and returns the first
    // time of each key.
    public ImmutableDictionary<string, DateTimeOffset> Update(IEnumerable<string> keys, DateTimeOffset now)
    {
        var live = keys.ToHashSet();
        foreach (var k in first.Keys.Where(k => !live.Contains(k) && !goneAt.ContainsKey(k)).ToArray())
        {
            goneAt[k] = now;
        }
        foreach (var k in goneAt.Where(e => now - e.Value > Grace).Select(e => e.Key).ToArray())
        {
            first.Remove(k);
            goneAt.Remove(k);
        }
        var output = ImmutableDictionary.CreateBuilder<string, DateTimeOffset>();
        foreach (var k in live)
        {
            if (!first.TryGetValue(k, out var t))
            {
                first[k] = t = now;
            }
            goneAt.Remove(k);
            output[k] = t;
        }
        return output.ToImmutable();
    }
}

// The chat: 1 thread of the computers and this device, oldest first. It is a
// port of Chat.swift of the Mac app and ChatFeed.kt of the Android app.
public static partial class Chat
{
    // The entries of the chat in scope, oldest first. clip shows only when
    // it came from a computer. answers are the approval records, and only
    // the approved, enrolled, and denied ones with a Resolved time show. An
    // agent takes the start time of its status from since, by computer and
    // pane. Any other item, and an agent with no start time, takes its time
    // from seen, by key. Entries with the same time keep the order of the
    // arguments.
    public static IReadOnlyList<ChatEntry> Entries(IEnumerable<SentItem> sent, IEnumerable<FileTransfer> transfers, ClipEvent? clip,
                                                   IEnumerable<ApproveRecord> answers, IEnumerable<InboxItem> items,
                                                   Func<string, string, DateTimeOffset?> since, IReadOnlyDictionary<string, DateTimeOffset> seen,
                                                   string? scope = null)
    {
        var output = new List<ChatEntry>();
        output.AddRange(sent.Select(s => new ChatEntry.Sent(s)));
        output.AddRange(transfers.Select(t => new ChatEntry.File(t)));
        if (clip is { Sent: false })
        {
            output.Add(new ChatEntry.Clip(clip));
        }
        output.AddRange(answers
            .Where(r => r.Resolved is not null && r.Outcome.Kind is ApproveOutcomeKind.Approved or ApproveOutcomeKind.Enrolled or ApproveOutcomeKind.Denied)
            .Select(r => new ChatEntry.Answer(r)));
        foreach (var item in items)
        {
            DateTimeOffset? start = item.Content is InboxContent.Agent a ? since(a.DeviceId, a.Value.Pane) : null;
            var at = start ?? (seen.TryGetValue(item.Key, out var s) ? s : DateTimeOffset.UnixEpoch);
            output.Add(new ChatEntry.Event(item, at));
        }
        // OrderBy is stable, so entries with the same time keep their order.
        return output.Where(e => e.Shows(scope)).OrderBy(e => e.At).ToArray();
    }

    // True when the choice lets the user write what the agent must do in
    // its place, for example "No, and tell Codex what to do differently (esc)".
    public static bool IsTellChoice(AgentChoice c) => TellChoice().IsMatch(c.Label);

    [GeneratedRegex(@"\btell\b.*\bdifferently\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex TellChoice();
}
