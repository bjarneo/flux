using System.Diagnostics;

namespace FluxKit;

// What the share feature needs from Windows. The WPF app implements it.
// Tests use a fake.
public interface ISharePlatform
{
    // Puts text from the computer on the clipboard. The app marks the text as
    // text from that computer, so that the clipboard sync does not send it
    // back. The core calls it on the UI thread.
    void PutText(string text, string deviceId);

    // Opens a received file with its default app, after a click of the user
    // on the notification. The core calls it on the UI thread.
    void OpenFile(string path);

    // Shows a received file selected in File Explorer. The core calls it on
    // the UI thread.
    void ShowInFolder(string path);

    // Opens a web link in the default browser, after a click of the user on
    // the notification. The link is always http or https. The core calls it
    // on the UI thread.
    void OpenLink(Uri url);

    // Marks a received file as a file from another computer, so that
    // SmartScreen and Office check it when the user opens it. The app writes
    // the Mark of the Web: the text "[ZoneTransfer]\r\nZoneId=3\r\n" in the
    // stream path + ":Zone.Identifier". The core calls it on a worker thread,
    // before it shows the file to the user.
    void MarkDownloaded(string path);
}

// The limit of the notifications that 1 computer causes. The share feature
// takes a token for each link notification. The app can give the share
// feature the limit of the notification feature, so that both features
// share 1 limit and a computer cannot bury the other notifications.
public interface IShareNotificationLimit
{
    // Takes a token of the computer now. It returns false when the
    // notification must not show.
    bool AllowsNow(string deviceId);

    // Notes the notification ID of the computer before its post. It removes
    // the oldest notifications of the computer above the cap.
    void Delivered(string id, string deviceId);
}

// The limit that the share feature uses when the app gives no other limit:
// a burst of 10 notifications per computer, then 1 per second, and at most
// 20 notifications of a computer at a time. NotificationsPlugin.swift of the
// Mac app has the same numbers.
public sealed class ShareNotificationLimit(Notifier notifier) : IShareNotificationLimit
{
    internal const double Burst = 10;
    internal const double PerSecond = 1;
    internal const int Cap = 20;

    readonly Lock gate = new();
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly Dictionary<string, (double Tokens, double At)> buckets = [];
    readonly Dictionary<string, List<string>> delivered = [];

    public bool AllowsNow(string deviceId) => Take(deviceId, clock.Elapsed.TotalSeconds);

    // Takes a token for a notification from the computer. now is in seconds.
    internal bool Take(string deviceId, double now)
    {
        lock (gate)
        {
            var last = buckets.TryGetValue(deviceId, out var b) ? b : (Tokens: Burst, At: now);
            var tokens = Math.Min(Burst, last.Tokens + Math.Max(0, now - last.At) * PerSecond);
            if (tokens < 1)
            {
                buckets[deviceId] = (tokens, now);
                return false;
            }
            buckets[deviceId] = (tokens - 1, now);
            return true;
        }
    }

    public void Delivered(string id, string deviceId)
    {
        foreach (var old in Add(id, deviceId))
        {
            notifier.Remove(old);
        }
    }

    // Adds the notification ID of the computer and returns the IDs to
    // remove, the oldest first. A post with an ID that is in the list
    // replaces that notification, so the ID moves to the end.
    internal IReadOnlyList<string> Add(string id, string deviceId)
    {
        lock (gate)
        {
            if (!delivered.TryGetValue(deviceId, out var list))
            {
                delivered[deviceId] = list = [];
            }
            list.Remove(id);
            list.Add(id);
            var extra = Math.Max(0, list.Count - Cap);
            var old = list.GetRange(0, extra);
            list.RemoveRange(0, extra);
            return old;
        }
    }
}
