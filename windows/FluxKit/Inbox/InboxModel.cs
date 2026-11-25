using System.Text.RegularExpressions;

namespace FluxKit;

// The link state of the paired computers in a scope: the number that are
// online, and the computers that are not reachable. The Inbox cannot show
// the agents of a computer that is not reachable.
public sealed record InboxReach(int Online, ValueList<DeviceSnapshot> Offline)
{
    // True when the scope has paired computers and none of them is online.
    public bool NoneOnline => Online == 0 && Offline.Count > 0;
}

// The computer for a Send or Control action.
public abstract record ActionTarget
{
    // The only computer that can take it.
    public sealed record One(DeviceSnapshot Device) : ActionTarget;

    // The user picks 1 of these computers.
    public sealed record Ask(ValueList<DeviceSnapshot> Devices) : ActionTarget;

    // No computer can take it now. Device is the computer in scope, or null.
    public sealed record Unavailable(DeviceSnapshot? Device) : ActionTarget;
}

// The Inbox: it collects the items of all computers that have a state now.
// The chat puts them in time order, see Chat.Entries. It is a port of
// InboxModel.swift of the Mac app and InboxModel.kt of the Android app.
public static partial class Inbox
{
    // How far from the end of the output the question can start, in lines.
    internal const int PromptScanLines = 40;

    // Collects the Inbox items of all computers: the agents that wait, are
    // done, or work, the pair requests, and the open approval. A computer
    // that is not reachable adds no agents. Each key shows once, because a
    // computer can report 2 agents on 1 pane.
    public static IReadOnlyList<InboxItem> Items(IEnumerable<DeviceSnapshot> devices, IReadOnlyDictionary<string, HerdrState> herdr,
                                                 ApproveRequest? approval = null)
    {
        var output = new List<InboxItem>();
        foreach (var d in devices)
        {
            if (!d.Paired)
            {
                if (d.PairState == PairState.Incoming)
                {
                    output.Add(new InboxItem(new InboxContent.Pair(d.Id), d.Name));
                }
                continue;
            }
            if (!d.Online || !herdr.TryGetValue(d.Id, out var h) || !h.Running)
            {
                continue;
            }
            foreach (var a in h.Agents.Where(a => a.Status is AgentStatus.Blocked or AgentStatus.Done or AgentStatus.Working))
            {
                output.Add(new InboxItem(new InboxContent.Agent(d.Id, a, h.Control), d.Name));
            }
        }
        if (approval is not null)
        {
            output.Add(new InboxItem(new InboxContent.Approval(approval), approval.ComputerName));
        }
        var seen = new HashSet<string>();
        return output.Where(i => seen.Add(i.Key)).ToArray();
    }

    // The items from the plugin models of core. devices is the device list
    // that the app shows.
    public static IReadOnlyList<InboxItem> Items(FluxCore core, IEnumerable<DeviceSnapshot> devices) =>
        Items(devices, (IReadOnlyDictionary<string, HerdrState>?)core.Plugin<HerdrPlugin>()?.Model.States ?? new Dictionary<string, HerdrState>(),
            core.Plugin<ApprovePlugin>()?.Model.Current);

    // The number of items that need the user.
    public static int NeedsYou(IEnumerable<InboxItem> items) => items.Count(i => i.Kind.NeedsYou());

    // The items of the computer scope, or all items when scope is null. An
    // item with no computers shows in every scope.
    public static IReadOnlyList<InboxItem> InScope(IEnumerable<InboxItem> items, string? scope) =>
        scope is null ? items.ToArray() : items.Where(i => i.DeviceIds.Count == 0 || i.DeviceIds.Contains(scope)).ToArray();

    // The link state of the paired computers in scope, or of all paired
    // computers when scope is null.
    public static InboxReach Reach(string? scope, IEnumerable<DeviceSnapshot> devices)
    {
        var paired = devices.Where(d => d.Paired && (scope is null || d.Id == scope)).ToArray();
        return new InboxReach(paired.Count(d => d.Online), ValueList.From(paired.Where(d => !d.Online)));
    }

    // Finds the computer for an action. A computer in scope is the target
    // when it is online and can take the action. With all computers in
    // scope, the only online computer that can take it is the target, and
    // with more than 1 the user picks.
    public static ActionTarget Target(string? scope, IEnumerable<DeviceSnapshot> devices, Func<DeviceSnapshot, bool>? can = null)
    {
        can ??= _ => true;
        var paired = devices.Where(d => d.Paired).ToArray();
        if (scope is not null)
        {
            if (paired.FirstOrDefault(d => d.Id == scope) is not { } d)
            {
                return new ActionTarget.Unavailable(null);
            }
            return d.Online && can(d) ? new ActionTarget.One(d) : new ActionTarget.Unavailable(d);
        }
        var ready = paired.Where(d => d.Online && can(d)).ToArray();
        return ready.Length switch
        {
            0 => new ActionTarget.Unavailable(null),
            1 => new ActionTarget.One(ready[0]),
            _ => new ActionTarget.Ask(ValueList.From(ready)),
        };
    }

    // True when a paired computer in scope has a feature, also while it is
    // not reachable.
    public static bool HasFeature(string? scope, IEnumerable<DeviceSnapshot> devices, Func<DeviceSnapshot, bool> can) =>
        devices.Any(d => d.Paired && (scope is null || d.Id == scope) && can(d));

    // Prompt

    // The first numbered choice of a dialog. Kotlin \s is [ \t\n\x0B\f\r],
    // and .NET \s also takes Unicode spaces, so the class is written out.
    [GeneratedRegex(@"^[ \t\n\x0B\f\r]*([❯›>][ \t\n\x0B\f\r]*)?1[.)][ \t\n\x0B\f\r]+.+$")]
    private static partial Regex FirstChoice();

    // A line of only rule characters.
    [GeneratedRegex(@"^[ \t\n\x0B\f\r─━═╌┄╍┈┉\-_]+$")]
    private static partial Regex RuleLine();

    // Finds the question of an agent in its output lines: the lines above
    // the first numbered choice, up to maxLines lines that are not empty. A
    // rule line ends the question. Without choices, it gives the last lines
    // that are not empty. The lines nearest the choices stay, because they
    // hold the command that a choice approves. With dropAsk, the last line
    // above the choices goes when it ends with a question mark, because the
    // choices ask the same question. The command then gets that line. The
    // input is the plain text of each line: the Text of HerdrOutput.Lines.
    public static string AgentPrompt(IReadOnlyList<string> lines, int maxLines = 4, bool dropAsk = false)
    {
        var from = Math.Max(0, lines.Count - PromptScanLines);
        int? choice = null;
        for (var j = lines.Count - 1; j >= from; j--)
        {
            if (FirstChoice().IsMatch(lines[j]))
            {
                choice = j;
                break;
            }
        }
        var output = new List<string>();
        var i = (choice ?? lines.Count) - 1;
        var ask = dropAsk && choice is not null;
        while (i >= from && output.Count < maxLines)
        {
            var t = lines[i].Trim();
            i--;
            if (t.Length == 0)
            {
                continue;
            }
            if (RuleLine().IsMatch(t))
            {
                break;
            }
            if (ask)
            {
                ask = false;
                if (t.EndsWith('?'))
                {
                    continue;
                }
            }
            output.Insert(0, t);
        }
        return string.Join("\n", output);
    }

    // A short form of a clip for the Inbox: 1 line with single spaces, cut
    // at limit characters. A cut text ends with "…".
    public static string ClipPreview(string text, int limit = ClipEvent.PreviewLength) => ClipEvent.MakePreview(text, limit);
}
