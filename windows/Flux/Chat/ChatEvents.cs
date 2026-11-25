using System.Collections.Immutable;
using System.ComponentModel;
using FluxKit;

namespace Flux;

// The chats and their times: the open chat of Chats, the time that each
// computer went offline, and the first time that this computer saw each
// Inbox item. AppModel.swift of the Mac app has the same parts.
public sealed partial class AppModel
{
    readonly SeenClock seenClock = new();
    readonly Dictionary<string, DateTimeOffset> lastSeen = [];
    ImmutableDictionary<string, DateTimeOffset> seen = ImmutableDictionary<string, DateTimeOffset>.Empty;
    ChatKey? chat;
    bool watchingEvents;

    // The first time that this computer saw each Inbox item of all
    // computers, by key. See WatchEvents.
    public IReadOnlyDictionary<string, DateTimeOffset> Seen => seen;

    // The chat that the user opened last, or null. See ShownChat.
    public ChatKey? Chat
    {
        get => chat;
        private set => Set(ref chat, value);
    }

    // The chat in the detail column of Chats: the open chat while its
    // computer is paired, else the chat of the first paired computer, the
    // online computers first. It is null before the first pairing.
    public ChatKey? ShownChat =>
        chat is { } c && PairedDevice(c.DeviceId) is not null
            ? c
            : Paired.OrderByDescending(d => d.Online).Select(d => (ChatKey)new ChatKey.Computer(d.Id)).FirstOrDefault();

    // Opens a chat in the detail column of Chats. The computer of the chat
    // takes the scope, so that the theme and Control follow it. herdr keeps
    // 1 output of each computer, so while the agents window of the computer
    // is open, its agents show there.
    public void OpenChat(ChatKey key)
    {
        if (key is ChatKey.Agent agent && AgentsWindows.IsOpen(agent.DeviceId))
        {
            AgentsWindows.Show(this, agent.DeviceId, agent.Pane);
            return;
        }
        Chat = key;
        if (PairedDevice(key.DeviceId) is not null)
        {
            Scope = key.DeviceId;
        }
        Go(Destination.Chat);
    }

    // Shows the chat of the computer in the place of an agent chat of the
    // same computer, when its agents window opens. See OpenChat.
    internal void YieldAgentChat(string deviceId)
    {
        if (chat is ChatKey.Agent a && a.DeviceId == deviceId)
        {
            Chat = new ChatKey.Computer(deviceId);
        }
    }

    // The time that the paired computer went offline while Flux ran, or null.
    public DateTimeOffset? LastSeen(string id) => lastSeen.TryGetValue(id, out var at) ? at : null;

    // The Inbox items of all computers: the agents, the approval, and the pair requests.
    public IReadOnlyList<InboxItem> InboxItems() => FluxKit.Inbox.Items(Core, State.Devices);

    // Keeps the times and the prompts of the Inbox items of all computers
    // while the app runs, also while no window shows them. It runs again
    // after each change of the computers or of the agents. Call it once at
    // the start.
    public void WatchEvents()
    {
        if (watchingEvents)
        {
            return;
        }
        watchingEvents = true;
        PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(State))
            {
                EventsChanged();
            }
        };
        if (Core.Plugin<HerdrPlugin>() is { } herdr)
        {
            herdr.Model.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName == nameof(HerdrModel.States))
                {
                    EventsChanged();
                }
            };
        }
        if (Core.Plugin<ApprovePlugin>() is { } approve)
        {
            approve.Model.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName == nameof(ApproveModel.Current))
                {
                    EventsChanged();
                }
            };
        }
        EventsChanged();
    }

    // Records the first time of each new item, and keeps the prompt of each
    // agent that waits or works. A new set of items changes Seen, so that
    // the views that count the items draw again.
    void EventsChanged()
    {
        var items = InboxItems();
        var next = seenClock.Update(items.Select(i => i.Key), DateTimeOffset.Now);
        if (next.Count != seen.Count || next.Any(e => !seen.TryGetValue(e.Key, out var at) || at != e.Value))
        {
            seen = next;
            Changed(nameof(Seen));
        }
        var keys = new HashSet<string>();
        foreach (var item in items)
        {
            if (item.Content is InboxContent.Agent { Value.Status: AgentStatus.Blocked or AgentStatus.Working } a)
            {
                keys.Add(HerdrModel.PromptKey(a.DeviceId, a.Value.Pane));
            }
        }
        Core.Plugin<HerdrPlugin>()?.KeepPrompts(keys);
    }

    // The times of the chat for the items: the first time of each item, or
    // now for an item that WatchEvents did not record yet.
    public IReadOnlyDictionary<string, DateTimeOffset> ChatSeen(IEnumerable<InboxItem> items, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.Now;
        var missing = items.Where(i => !seen.ContainsKey(i.Key)).ToArray();
        if (missing.Length == 0)
        {
            return seen;
        }
        var output = seen.ToBuilder();
        foreach (var item in missing)
        {
            output[item.Key] = at;
        }
        return output.ToImmutable();
    }

    // The models that a view of the Inbox items watches: the app model, the
    // agents, and the approvals.
    public IEnumerable<INotifyPropertyChanged> InboxModels() =>
        new INotifyPropertyChanged?[] { this, Core.Plugin<HerdrPlugin>()?.Model, Core.Plugin<ApprovePlugin>()?.Model }.OfType<INotifyPropertyChanged>();
}
