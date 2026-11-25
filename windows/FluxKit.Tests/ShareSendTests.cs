using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// ShareSendTests.swift of the Mac app, and the packets from the computer
// without a network.
public class ShareSendTests
{
    // A core with the share feature, a fake platform, and recorded
    // notifications. The network does not start.
    sealed class Rig : IDisposable
    {
        public FakeSharePlatform Platform { get; } = new();
        public RecordingNotifications Notifications { get; } = new();
        public SharePlugin Share { get; }
        public TestCore T { get; }

        public Rig()
        {
            Share = new SharePlugin(Platform);
            T = new TestCore(new LanConfig { LoopbackOnly = true }, [Share]);
            T.Core.Host.Notifier.Backend = Notifications;
        }

        public void Dispose() => T.Dispose();
    }

    [Fact]
    public async Task TextToAComputerThatIsNotConnectedFails()
    {
        using var rig = new Rig();
        var (t, share) = (rig.T, rig.Share);
        Assert.False(share.SendText("hello", "nobody"));
        await Wait.UntilAsync(() => t.Toasts.Contains("Not connected. Try again in a moment"), "the toast");
    }

    [Fact]
    public async Task TextAboveTheLimitDoesNotGoOut()
    {
        using var rig = new Rig();
        var (t, share) = (rig.T, rig.Share);
        Assert.False(share.SendText(new string('a', SharePlugin.MaxText + 1), "nobody"));
        await Wait.UntilAsync(() => t.Toasts.Contains("The text is larger than 1 MB. Send it as a file"), "the toast");
    }

    [Fact]
    public async Task WaitedFilesToAComputerThatIsNotConnectedThrow()
    {
        using var rig = new Rig();
        var (t, share) = (rig.T, rig.Share);
        var file = Path.Combine(t.Data, "x.txt");
        await File.WriteAllTextAsync(file, "x");
        await Assert.ThrowsAsync<ShareException>(() => share.SendAndWaitAsync([file], "nobody", (_, _) => Assert.Fail("no file goes out")));
    }

    [Fact]
    public async Task AFolderDoesNotGoOut()
    {
        using var rig = new Rig();
        var (t, share) = (rig.T, rig.Share);
        var folder = Path.Combine(t.Data, "photos");
        Directory.CreateDirectory(folder);
        share.SendFiles([folder + Path.DirectorySeparatorChar], "nobody");
        await Wait.UntilAsync(() => t.Toasts.Contains("photos is a folder. Send the files inside it"), "the toast");
        Assert.DoesNotContain("Not connected. Try again in a moment", t.Toasts);
    }

    [Fact]
    public async Task TextFromTheComputerGoesOnTheClipboard()
    {
        using var rig = new Rig();
        var (t, share, platform) = (rig.T, rig.Share, rig.Platform);
        var computer = ShareTesting.PairedComputer(t.Core);
        share.Handle(new Packet(PacketType.Share, new JsonObject { ["text"] = "hello" }), computer);
        // A url that is not a web link is text.
        share.Handle(new Packet(PacketType.Share, new JsonObject { ["url"] = "file:///C:/Windows/notepad.exe" }), computer);
        await Wait.UntilAsync(() => platform.Texts.Count == 2, "the clipboard");
        Assert.Equal([("hello", "computer1"), ("file:///C:/Windows/notepad.exe", "computer1")], platform.Texts);
        await Wait.UntilAsync(() => t.Toasts.Contains("Text from Omarchy is on the clipboard"), "the toast");
        Assert.Empty(platform.Links);
    }

    [Fact]
    public async Task LinkWaitsInANotification()
    {
        using var rig = new Rig();
        var (t, share, platform, notifications) = (rig.T, rig.Share, rig.Platform, rig.Notifications);
        var computer = ShareTesting.PairedComputer(t.Core);
        share.Handle(new Packet(PacketType.Share, new JsonObject { ["url"] = "https://omarchy.org/docs?a=1" }), computer);
        var n = Assert.Single(notifications.Shown);
        Assert.Equal(SharePlugin.LinkCategory, n.Category);
        Assert.Equal("Link from Omarchy", n.Title);
        Assert.Equal("https://omarchy.org/docs?a=1", n.Body);
        Assert.StartsWith("share-link-computer1:", n.Id);
        await Wait.UntilAsync(() => t.Toasts.Contains("Link from Omarchy"), "the toast");
        // The link opens only after a click.
        Assert.Empty(platform.Links);
        t.Core.Host.Notifier.Activate(n.Category, "open", n.UserInfo);
        await Wait.UntilAsync(() => !platform.Links.IsEmpty, "the link");
        Assert.Equal("https://omarchy.org/docs?a=1", platform.Links.Single().OriginalString);
        // A user info that is not a web link opens nothing.
        t.Core.Host.Notifier.Activate(n.Category, "open", new Dictionary<string, string> { ["url"] = "file:///C:/x.exe" });
        await Task.Delay(100);
        Assert.Single(platform.Links);
    }

    // The links share the notification limit of the computer, so that a
    // computer cannot bury the other notifications.
    [Fact]
    public void LinksCountTowardTheNotificationLimit()
    {
        using var rig = new Rig();
        var (t, share, notifications) = (rig.T, rig.Share, rig.Notifications);
        var computer = ShareTesting.PairedComputer(t.Core);
        for (var i = 0; i < 15; i++)
        {
            share.Handle(new Packet(PacketType.Share, new JsonObject { ["url"] = $"https://omarchy.org/{i}" }), computer);
        }
        Assert.Equal((int)ShareNotificationLimit.Burst, notifications.Shown.Count);
        // Another computer has its own limit.
        share.Handle(new Packet(PacketType.Share, new JsonObject { ["url"] = "https://omarchy.org/x" }), ShareTesting.PairedComputer(t.Core, "computer2", "Other"));
        Assert.Equal((int)ShareNotificationLimit.Burst + 1, notifications.Shown.Count);
    }

    [Fact]
    public void TheAppCanGiveTheSharedLimit()
    {
        var limit = new SharedLimit();
        var share = new SharePlugin(new FakeSharePlatform(), limit);
        using var t = new TestCore(new LanConfig { LoopbackOnly = true }, [share]);
        var notifications = new RecordingNotifications();
        t.Core.Host.Notifier.Backend = notifications;
        var computer = ShareTesting.PairedComputer(t.Core);
        share.Handle(new Packet(PacketType.Share, new JsonObject { ["url"] = "https://omarchy.org" }), computer);
        Assert.Empty(notifications.Shown);
        limit.Allow = true;
        share.Handle(new Packet(PacketType.Share, new JsonObject { ["url"] = "https://omarchy.org" }), computer);
        Assert.Equal(notifications.Shown.Single().Id, limit.Delivered.Single());
    }

    sealed class SharedLimit : IShareNotificationLimit
    {
        public bool Allow { get; set; }
        public List<string> Delivered { get; } = [];
        public bool AllowsNow(string deviceId) => Allow;
        void IShareNotificationLimit.Delivered(string id, string deviceId) => Delivered.Add(id);
    }

    [Fact]
    public void NotificationLimitRefillsAndKeepsACap()
    {
        var notifier = new Notifier();
        var removed = new RecordingNotifications();
        notifier.Backend = removed;
        var limit = new ShareNotificationLimit(notifier);
        for (var i = 0; i < ShareNotificationLimit.Burst; i++)
        {
            Assert.True(limit.Take("a", 0));
        }
        Assert.False(limit.Take("a", 0.5));
        // 1 token comes back each second.
        Assert.True(limit.Take("a", 1.6));
        Assert.False(limit.Take("a", 1.7));

        for (var i = 0; i < ShareNotificationLimit.Cap + 2; i++)
        {
            limit.Delivered($"n{i}", "a");
        }
        Assert.Equal(["n0", "n1"], removed.Removed);
        // A post with a known ID moves it to the end.
        limit.Delivered("n2", "a");
        limit.Delivered("n99", "a");
        Assert.Equal(["n0", "n1", "n3"], removed.Removed);
    }

    [Fact]
    public async Task FileNotificationOpensOrShowsTheFile()
    {
        using var rig = new Rig();
        var (t, platform) = (rig.T, rig.Platform);
        var info = new Dictionary<string, string> { ["path"] = @"C:\Users\me\Downloads\a.txt" };
        t.Core.Host.Notifier.Activate(SharePlugin.FileCategory, Notifier.DefaultAction, info);
        t.Core.Host.Notifier.Activate(SharePlugin.FileCategory, "open", info);
        t.Core.Host.Notifier.Activate(SharePlugin.FileCategory, "reveal", info);
        await Wait.UntilAsync(() => platform.Opened.Count == 2 && platform.Shown.Count == 1, "the platform calls");
    }

    [Fact]
    public async Task AFileWithoutSizeIsRefused()
    {
        using var rig = new Rig();
        var (t, share) = (rig.T, rig.Share);
        var computer = ShareTesting.PairedComputer(t.Core);
        var p = Packet.Parse("""{"id":1,"type":"flux.share.request","body":{"filename":"a.txt"},"payloadSize":-1,"payloadTransferInfo":{"tunnel":"t1"}}""")!;
        share.Handle(p, computer);
        await Task.Delay(200);
        Assert.DoesNotContain(t.Toasts, m => m.StartsWith("Receiving", StringComparison.Ordinal));
        Assert.Empty(share.Model.Transfers);
    }
}
