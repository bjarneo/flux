using System.Collections.Concurrent;
using System.Security.Cryptography;
using FluxKit;

namespace FluxKit.Tests;

// Records what the share feature asks of Windows.
sealed class FakeSharePlatform : ISharePlatform
{
    public ConcurrentQueue<(string Text, string DeviceId)> Texts { get; } = new();
    public ConcurrentQueue<string> Opened { get; } = new();
    public ConcurrentQueue<string> Shown { get; } = new();
    public ConcurrentQueue<Uri> Links { get; } = new();
    public ConcurrentQueue<string> Marked { get; } = new();

    public void PutText(string text, string deviceId) => Texts.Enqueue((text, deviceId));
    public void OpenFile(string path) => Opened.Enqueue(path);
    public void ShowInFolder(string path) => Shown.Enqueue(path);
    public void OpenLink(Uri url) => Links.Enqueue(url);
    public void MarkDownloaded(string path) => Marked.Enqueue(path);
}

// Records the system notifications.
sealed class RecordingNotifications : INotificationBackend
{
    public ConcurrentQueue<SystemNotification> Shown { get; } = new();
    public ConcurrentQueue<string> Removed { get; } = new();

    public void Show(SystemNotification notification, IReadOnlyList<NotificationAction> actions) => Shown.Enqueue(notification);
    public void Remove(string id) => Removed.Enqueue(id);
}

static class ShareTesting
{
    // A paired computer of the core without a link, for packets that a test
    // gives to the plugin.
    public static Device PairedComputer(FluxCore core, string id = "computer1", string name = "Omarchy")
    {
        var d = new Device(core, new Identity(id, name, "desktop", Identity.Version, [PacketType.Tunnel, PacketType.Share], [PacketType.Share]));
        d.PairState = PairState.Paired;
        return d;
    }

    public static byte[] RandomBytes(int size)
    {
        var data = new byte[size];
        Random.Shared.NextBytes(data);
        return data;
    }

    public static string Sha256(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));
}
