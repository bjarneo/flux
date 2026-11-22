using System.Globalization;

namespace FluxKit;

// The 3 link states of an agent thread.
public enum ThreadLink
{
    Connected,
    Connecting,
    Unreachable,
}

// The note above the dock of an agent thread. Title is the first line.
// Detail is the second line, or empty. For Connected, Detail is the age of
// the output, such as now or 3m.
public sealed record ThreadNote(ThreadLink State, string Title, string Detail);

// The texts about the link to a computer. The thread of an agent and the
// rows of Chats show them, so that the apps use the same words. It is a port
// of LinkNote.kt of the Android app, with the same test vectors. A caller
// gives time a function that formats a time in the format of the user.
public static class LinkNote
{
    // HH:MM of a time in the local zone, for a caller with no format of its own.
    public static string Clock(DateTimeOffset at) => at.ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture);

    // The note of a thread, or null when it has no note: the computer is
    // connected and the app has no output yet. outputAt is the time of the
    // last output, or null when it is not known.
    public static ThreadNote? ThreadNote(bool online, bool connecting, string name, DateTimeOffset? outputAt, DateTimeOffset now,
                                         Func<DateTimeOffset, string>? time = null)
    {
        time ??= Clock;
        if (online)
        {
            return outputAt is { } at ? new ThreadNote(ThreadLink.Connected, $"Output from {time(at)}", Age(now - at)) : null;
        }
        if (connecting)
        {
            return new ThreadNote(ThreadLink.Connecting, $"Connecting to {name}", "");
        }
        return new ThreadNote(ThreadLink.Unreachable, $"{name} is not reachable.", outputAt is { } seen ? $"This output is from {time(seen)}." : "");
    }

    // The line of a row of a computer that is not reachable, or null when the
    // computer is online. lastSeen is null when it is not known.
    public static string? RowLine(bool online, DateTimeOffset? lastSeen, Func<DateTimeOffset, string>? time = null)
    {
        if (online)
        {
            return null;
        }
        return lastSeen is { } at ? $"Not reachable since {(time ?? Clock)(at)}" : "Not reachable";
    }

    // The age of an output: now under 1 minute, then 3m, 2h, or 4d.
    public static string Age(TimeSpan span)
    {
        var min = (long)Math.Max(0, span.TotalMilliseconds) / 60_000;
        return min switch
        {
            < 1 => "now",
            < 60 => $"{min}m",
            < 24 * 60 => $"{min / 60}h",
            _ => $"{min / (24 * 60)}d",
        };
    }
}
