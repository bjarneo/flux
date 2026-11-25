using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// File, text, and link sharing against a headless fluxd. Each test uses a
// block of 50 ports from 30000 for the links. Payloads and tunnels use 12070
// to 12099, because fluxd takes no other payload port.
public class ShareEndToEndTests
{
    // A paired core with the share feature, a fake platform, recorded
    // notifications, and a download folder in its data folder.
    sealed class Rig : IAsyncDisposable
    {
        public required Fluxd Fluxd { get; init; }
        public required TestCore T { get; init; }
        public required SharePlugin Share { get; init; }
        public required FakeSharePlatform Platform { get; init; }
        public RecordingNotifications Notifications { get; } = new();
        public required string Folder { get; init; }
        public DeviceSnapshot Computer { get; set; } = null!;

        public async ValueTask DisposeAsync()
        {
            T.Dispose();
            await Fluxd.DisposeAsync();
        }
    }

    static async Task<Rig> StartAsync(int first, bool resumable = true)
    {
        var fluxd = await Fluxd.StartAsync(first + 16, first + 20);
        var platform = new FakeSharePlatform();
        var share = new SharePlugin(platform) { Resumable = resumable };
        var t = new TestCore(new LanConfig
        {
            UdpPort = first + 31,
            PeerUdpPort = fluxd.UdpPort,
            FirstTcpPort = first + 40,
            LastTcpPort = first + 48,
            LoopbackOnly = true,
        }, [share]);
        var rig = new Rig { Fluxd = fluxd, T = t, Share = share, Platform = platform, Folder = Path.Combine(t.Data, "Received") };
        t.Core.Host.Notifier.Backend = rig.Notifications;
        share.SetDownloadFolder(rig.Folder);
        rig.Computer = await EndToEndTests.PairFromWindowsAsync(fluxd, t);
        return rig;
    }

    // Writes files with random bytes in the folder of fluxd.
    static async Task<(string Path, byte[] Data)[]> FilesAsync(string folder, params (string Name, int Size)[] files)
    {
        var made = new List<(string, byte[])>();
        foreach (var (name, size) in files)
        {
            var data = ShareTesting.RandomBytes(size);
            var path = Path.Combine(folder, name);
            await File.WriteAllBytesAsync(path, data);
            made.Add((path, data));
        }
        return made.ToArray();
    }

    static bool Arrived(string path, byte[] data) => File.Exists(path) && new FileInfo(path).Length == data.Length && File.ReadAllBytes(path).AsSpan().SequenceEqual(data);

    // The JSON objects of the node and of its children.
    static IEnumerable<JsonObject> Objects(JsonNode? node)
    {
        switch (node)
        {
            case JsonObject o:
                yield return o;
                foreach (var (_, child) in o)
                {
                    foreach (var x in Objects(child))
                    {
                        yield return x;
                    }
                }
                break;
            case JsonArray a:
                foreach (var child in a)
                {
                    foreach (var x in Objects(child))
                    {
                        yield return x;
                    }
                }
                break;
        }
    }

    // fluxd lists the transfer flux.transfer as the device accepts it. Then
    // the outbox sends each file in chunks of 1 MiB through tunnels.
    [FluxdFact]
    public async Task FilesFromFluxdArriveInResumableChunks()
    {
        await using var rig = await StartAsync(30000);
        var files = await FilesAsync(rig.Fluxd.Root, ("small notes.txt", 10_000), ("big video.bin", 5 << 20));
        await rig.Fluxd.CliAsync("send", files[0].Path, files[1].Path);
        foreach (var (path, data) in files)
        {
            var target = Path.Combine(rig.Folder, Path.GetFileName(path));
            await Wait.UntilAsync(() => Arrived(target, data), $"{Path.GetFileName(path)} on this side", rig.Fluxd, 60);
        }
        // The resumable path keeps a record of each file in the data folder.
        var records = Directory.GetFiles(rig.T.Core.Paths.File("incoming"), "state.json", SearchOption.AllDirectories);
        Assert.Equal(2, records.Length);
        Assert.All(records, r => Assert.False(File.Exists(Path.Combine(Path.GetDirectoryName(r)!, "data"))));
        // fluxd ends both transfers.
        await Wait.UntilAsync(async () =>
        {
            var list = await rig.Fluxd.CliAsync("transfers");
            return list.Split('\n').Count(l => l.Contains(" done ", StringComparison.Ordinal)) == 2;
        }, "the transfers on fluxd", rig.Fluxd);
        var saved = files.Select(f => Path.Combine(rig.Folder, Path.GetFileName(f.Path))).ToArray();
        await Wait.UntilAsync(() => rig.Notifications.Shown.Count == 2, "the notifications", rig.Fluxd);
        foreach (var path in saved)
        {
            var n = Assert.Single(rig.Notifications.Shown, n => n.Title == $"Received {Path.GetFileName(path)}");
            Assert.Equal(SharePlugin.FileCategory, n.Category);
            Assert.Equal($"From {rig.Computer.Name}", n.Body);
            Assert.Equal(path, n.UserInfo["path"]);
            Assert.Contains(path, rig.Platform.Marked);
        }
        await Wait.UntilAsync(() => rig.Share.Model.Transfers.Count == 2 && rig.Share.Model.Transfers.All(t => t.State == TransferState.Done),
            "the transfers in the model", rig.Fluxd);
        var big = rig.Share.Model.Transfers.Single(t => t.Name == "big video.bin");
        Assert.True(big.Incoming);
        Assert.Equal(5 << 20, big.Bytes);
        Assert.Equal(saved[1], big.File);
        // A click on the notification shows the file.
        var shown = rig.Notifications.Shown.First();
        rig.T.Core.Host.Notifier.Activate(shown.Category, "reveal", shown.UserInfo);
        await Wait.UntilAsync(() => rig.Platform.Shown.Contains(shown.UserInfo["path"]), "the file in the folder");
    }

    // A cancel on this side refuses the file for good. fluxd keeps the
    // transfer with the error, and its retries get the same error.
    [FluxdFact]
    public async Task ACanceledFileFromFluxdStaysRefused()
    {
        await using var rig = await StartAsync(30300);
        var file = (await FilesAsync(rig.Fluxd.Root, ("large.bin", 64 << 20)))[0];
        var canceled = 0;
        rig.Share.Model.PropertyChanged += (_, _) =>
        {
            if (rig.Share.Model.Transfers.FirstOrDefault() is { State: TransferState.Running, Bytes: > 0 } t && Interlocked.Exchange(ref canceled, 1) == 0)
            {
                rig.Share.Cancel(t.Id);
            }
        };
        await rig.Fluxd.CliAsync("send", file.Path);
        await Wait.UntilAsync(async () => (await rig.Fluxd.CliAsync("transfers")).Contains(ResumableTransfer.CanceledText, StringComparison.Ordinal),
            "the error on fluxd", rig.Fluxd, 30);
        await Wait.UntilAsync(() => rig.Share.Model.Transfers.SingleOrDefault()?.State == TransferState.Canceled, "the canceled entry", rig.Fluxd);
        Assert.False(File.Exists(Path.Combine(rig.Folder, "large.bin")));
        Assert.Empty(Directory.GetFiles(rig.T.Core.Paths.File("incoming"), "data", SearchOption.AllDirectories));
        Assert.Empty(rig.Notifications.Shown);
    }

    // Without flux.transfer, fluxd sends the file as flux.share.request with
    // a tunnel, as to an older app.
    [FluxdFact]
    public async Task FilesFromFluxdArriveThroughATunnel()
    {
        await using var rig = await StartAsync(30050, resumable: false);
        var files = await FilesAsync(rig.Fluxd.Root, ("photo.jpg", 5 << 20), ("a.txt", 3));
        await rig.Fluxd.CliAsync("send", files[0].Path, files[1].Path);
        foreach (var (path, data) in files)
        {
            var target = Path.Combine(rig.Folder, Path.GetFileName(path));
            await Wait.UntilAsync(() => Arrived(target, data), $"{Path.GetFileName(path)} on this side", rig.Fluxd, 60);
        }
        Assert.False(Directory.Exists(rig.T.Core.Paths.File("incoming")));
        await Wait.UntilAsync(() => rig.T.Toasts.Contains($"Saved photo.jpg in Received") && rig.T.Toasts.Contains("Saved a.txt in Received"),
            "the toasts", rig.Fluxd);
        Assert.Contains("Receiving photo.jpg", rig.T.Toasts);
        var n = Assert.Single(rig.Notifications.Shown, n => n.Title == "Received photo.jpg");
        Assert.Equal($"From {rig.Computer.Name}, saved in Received", n.Body);
        Assert.Equal(2, rig.Platform.Marked.Count);
        // No partial file stays.
        Assert.Equal(["a.txt", "photo.jpg"], Directory.GetFiles(rig.Folder).Select(Path.GetFileName).Order());
        // A second file with the same name gets a new name.
        await rig.Fluxd.CliAsync("send", files[1].Path);
        await Wait.UntilAsync(() => Arrived(Path.Combine(rig.Folder, "a (2).txt"), files[1].Data), "a (2).txt", rig.Fluxd, 60);
    }

    [FluxdFact]
    public async Task FilesFromThisSideArriveInTheDownloadsOfFluxd()
    {
        await using var rig = await StartAsync(30100);
        var files = await FilesAsync(rig.T.Data, ("report.pdf", 20_000), ("big video.bin", 5 << 20));
        var results = new List<(string, Exception?)>();
        await rig.Share.SendAndWaitAsync(files.Select(f => f.Path), rig.Computer.Id, (path, error) =>
        {
            lock (results)
            {
                results.Add((path, error));
            }
        });
        Assert.Equal(files.Select(f => (f.Path, (Exception?)null)), results);
        foreach (var (path, data) in files)
        {
            var target = Path.Combine(rig.Fluxd.Downloads, Path.GetFileName(path));
            await Wait.UntilAsync(() => Arrived(target, data), $"{Path.GetFileName(path)} on fluxd", rig.Fluxd, 30);
        }
        await Wait.UntilAsync(() => rig.T.Toasts.Contains($"Sent 2 files to {rig.Computer.Name}"), "the toast", rig.Fluxd);
        await Wait.UntilAsync(() => rig.Share.Model.Transfers.Count == 2 && rig.Share.Model.Transfers.All(t => t is { State: TransferState.Done, Incoming: false }),
            "the transfers in the model", rig.Fluxd);
        Assert.Equal(files[0].Path, rig.Share.Model.Transfers.Single(t => t.Name == "report.pdf").File);

        // 1 file without a wait.
        var one = (await FilesAsync(rig.T.Data, ("one.txt", 100)))[0];
        rig.Share.SendFiles([one.Path], rig.Computer.Id);
        await Wait.UntilAsync(() => Arrived(Path.Combine(rig.Fluxd.Downloads, "one.txt"), one.Data), "one.txt on fluxd", rig.Fluxd, 30);
        await Wait.UntilAsync(() => rig.T.Toasts.Contains("Sent one.txt"), "the toast", rig.Fluxd);
    }

    [FluxdFact]
    public async Task LinkFromFluxdWaitsInANotification()
    {
        await using var rig = await StartAsync(30150);
        await rig.Fluxd.CliAsync("url", "https://omarchy.org/docs?a=1");
        await Wait.UntilAsync(() => !rig.Notifications.Shown.IsEmpty, "the link notification", rig.Fluxd);
        var n = rig.Notifications.Shown.Single();
        Assert.Equal(SharePlugin.LinkCategory, n.Category);
        Assert.Equal($"Link from {rig.Computer.Name}", n.Title);
        Assert.Equal("https://omarchy.org/docs?a=1", n.Body);
        Assert.StartsWith($"share-link-{rig.Computer.Id}:", n.Id);
        await Wait.UntilAsync(() => rig.T.Toasts.Contains($"Link from {rig.Computer.Name}"), "the toast", rig.Fluxd);
        // The link opens only after a click.
        Assert.Empty(rig.Platform.Links);
        rig.T.Core.Host.Notifier.Activate(n.Category, "open", n.UserInfo);
        await Wait.UntilAsync(() => !rig.Platform.Links.IsEmpty, "the open link");
        Assert.Equal("https://omarchy.org/docs?a=1", rig.Platform.Links.Single().OriginalString);
        Assert.Empty(rig.Platform.Texts);
    }

    // A headless fluxd puts shared text on its own clipboard and in its
    // clipboard history. It opens a link with xdg-open, which the test
    // container does not have, and keeps the link in the history.
    [FluxdFact]
    public async Task TextAndLinkFromThisSideReachFluxd()
    {
        await using var rig = await StartAsync(30200);
        Assert.True(rig.Share.SendText("hello from windows", rig.Computer.Id));
        Assert.True(rig.Share.SendText("  https://omarchy.org/windows \n", rig.Computer.Id));
        await Wait.UntilAsync(async () =>
        {
            var history = Objects(JsonNode.Parse(await rig.Fluxd.CliAsync("clipboard"))).ToList();
            return history.Any(e => Json.String(e["text"]) == "hello from windows" && Json.String(e["dir"]) == "in" && Json.String(e["source"]) == "share") &&
                   history.Any(e => Json.String(e["text"]) == "https://omarchy.org/windows" && Json.String(e["dir"]) == "in" && Json.String(e["source"]) == "link");
        }, "the text and the link in the history of fluxd", rig.Fluxd);
        Assert.Contains("https://omarchy.org/windows", rig.Fluxd.Log);
        Assert.Contains($"Text sent to {rig.Computer.Name}", rig.T.Toasts);
        Assert.Contains($"Link sent to {rig.Computer.Name}", rig.T.Toasts);
        await Wait.UntilAsync(() => rig.Share.Model.Sent.Count == 2, "the sent items");
        Assert.Equal([SentKind.Text, SentKind.Link], rig.Share.Model.Sent.Select(s => s.Kind));
        Assert.Equal("https://omarchy.org/windows", rig.Share.Model.Sent[1].Text);
    }

    // Text from fluxd goes on the clipboard of this computer. flux-cli has no
    // command for shared text, so the test calls the API of fluxd.
    [FluxdFact]
    public async Task TextFromFluxdGoesOnTheClipboard()
    {
        await using var rig = await StartAsync(30250);
        await ApiAsync(rig.Fluxd, "share.text", new JsonObject { ["device"] = rig.T.Core.Local.DeviceId, ["text"] = "hello from omarchy" });
        await Wait.UntilAsync(() => !rig.Platform.Texts.IsEmpty, "the text on the clipboard", rig.Fluxd);
        Assert.Equal(("hello from omarchy", rig.Computer.Id), rig.Platform.Texts.Single());
        await Wait.UntilAsync(() => rig.T.Toasts.Contains($"Text from {rig.Computer.Name} is on the clipboard"), "the toast", rig.Fluxd);
        Assert.Empty(rig.Notifications.Shown);
    }

    // Calls a method of the fluxd API: 1 JSON request line on its socket, and
    // the response line with the same ID.
    static async Task<JsonNode?> ApiAsync(Fluxd fluxd, string method, JsonObject parameters)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        using var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        await socket.ConnectAsync(new UnixDomainSocketEndPoint(Path.Combine(fluxd.Root, "run", "flux", "fluxd.sock")), timeout.Token);
        await using var stream = new NetworkStream(socket, ownsSocket: false);
        var request = new JsonObject { ["id"] = 1, ["method"] = method, ["params"] = parameters };
        await stream.WriteAsync(Encoding.UTF8.GetBytes(request.ToJsonString() + "\n"), timeout.Token);
        using var reader = new StreamReader(stream);
        while (await reader.ReadLineAsync(timeout.Token) is { } line)
        {
            var message = JsonNode.Parse(line);
            if (Json.Long(message?["id"]) != 1)
            {
                continue;
            }
            if (message?["error"] is { } error)
            {
                throw new InvalidOperationException($"{method} failed: {error.ToJsonString()}");
            }
            return message?["result"];
        }
        throw new IOException("fluxd closed the API connection");
    }
}
