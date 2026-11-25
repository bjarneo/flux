namespace FluxKit;

// Keeps the time that each agent of 1 computer got its status, as this
// device saw it. The first state after a connection only sets the start
// values, so the time of a status that started before is not known. An
// unknown status keeps the last known status and its time.
public sealed class AgentClock
{
    // The status of each pane and the time that it started, or null when the time is not known.
    readonly Dictionary<string, (AgentStatus Status, DateTimeOffset? At)> since = [];
    bool fresh = true;

    // Makes the next state set the start values. Call it when the computer connects.
    public void Restart() => fresh = true;

    // Takes a new agent list at the time now and returns the start time of
    // the status of each agent by pane. An agent whose start time is not
    // known is not in the result.
    public IReadOnlyDictionary<string, DateTimeOffset> Update(IEnumerable<HerdrAgent> agents, DateTimeOffset now)
    {
        var seen = new HashSet<string>();
        foreach (var a in agents)
        {
            seen.Add(a.Pane);
            if (a.Status == AgentStatus.Unknown)
            {
                continue;
            }
            var known = since.TryGetValue(a.Pane, out var prev);
            if (known && prev.Status == a.Status)
            {
                continue;
            }
            since[a.Pane] = (a.Status, !known && fresh ? null : now);
        }
        foreach (var pane in since.Keys.Where(p => !seen.Contains(p)).ToArray())
        {
            since.Remove(pane);
        }
        fresh = false;
        return Times;
    }

    // The start time of the status of each agent whose start time is known, by pane.
    public IReadOnlyDictionary<string, DateTimeOffset> Times =>
        since.Where(e => e.Value.At is not null).ToDictionary(e => e.Key, e => e.Value.At!.Value);
}

// The time at the end of an agent row: "3m" for an agent that waits, "2:14"
// for an agent that works, and "done" for a finished agent. A time that this
// device did not see is empty.
public static class AgentTime
{
    public static string When(AgentStatus status, DateTimeOffset? since, DateTimeOffset now)
    {
        if (status == AgentStatus.Done)
        {
            return "done";
        }
        if (since is not { } start)
        {
            return "";
        }
        var sec = Math.Max(0, (int)(now - start).TotalSeconds);
        switch (status)
        {
            case AgentStatus.Working:
                return sec >= 3600 ? $"{sec / 3600}:{sec / 60 % 60:00}:{sec % 60:00}" : $"{sec / 60}:{sec % 60:00}";
            case AgentStatus.Blocked:
            case AgentStatus.Idle:
                if (sec < 60)
                {
                    return "now";
                }
                if (sec < 3600)
                {
                    return $"{sec / 60}m";
                }
                return $"{sec / 3600}h";
            default:
                return "";
        }
    }
}

// How long ago a time was: "just now", "3 min ago", "2 h ago", "1 day ago",
// or "4 days ago".
public static class AgoText
{
    public static string Text(DateTimeOffset at, DateTimeOffset now)
    {
        var min = (int)((now - at).TotalSeconds / 60);
        if (min < 1)
        {
            return "just now";
        }
        if (min < 60)
        {
            return $"{min} min ago";
        }
        if (min < 24 * 60)
        {
            return $"{min / 60} h ago";
        }
        if (min < 2 * 24 * 60)
        {
            return "1 day ago";
        }
        return $"{min / (24 * 60)} days ago";
    }
}
