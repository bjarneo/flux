using FluxKit;

namespace FluxKit.Tests;

// A screenshot folder in a test folder.
sealed class FakeCapturePlatform(string? folder) : ICapturePlatform
{
    public string? Folder { get; set; } = folder;

    public string? ScreenshotFolder() => Folder;
}

// The capture watch: the files that a scan reads, the switch, and the send
// of new screenshots to a headless fluxd. Each end-to-end test uses a block
// of 50 ports from 38000 for the links. Payloads use 12070 to 12099,
// because fluxd takes no other payload port.
public class CaptureWatchTests
{
    static byte[] Png() => CameraImages.Png(2, 2, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 0, 0, 0, 0]);

    [Fact]
    public void AScanReadsTheFilesAfterTheBaseline()
    {
        var folder = CoreTests.TempDir();
        try
        {
            File.WriteAllBytes(Path.Combine(folder, "Screenshot (1).png"), Png());
            File.WriteAllText(Path.Combine(folder, "notes.txt"), "a");
            File.WriteAllText(Path.Combine(folder, ".hidden.png"), "a");
            Directory.CreateDirectory(Path.Combine(folder, "inner.png"));
            var now = DateTime.UtcNow;
            var (items, files) = CaptureWatchPlugin.ReadScreenshots(folder, 0, now);
            Assert.Equal(2, items.Count);
            var shot = Assert.Single(items, i => i.Name == "Screenshot (1).png");
            Assert.Equal(CaptureKind.Screenshot, shot.Kind);
            Assert.True(shot.Pending, "a file that changed just now is still being written");
            Assert.Equal(Path.Combine(folder, "Screenshot (1).png"), files[shot.Id]);
            Assert.Null(Assert.Single(items, i => i.Name == "notes.txt").Kind);
            // 3 seconds later, the file is complete.
            Assert.All(CaptureWatchPlugin.ReadScreenshots(folder, 0, now.AddSeconds(3)).Items, i => Assert.False(i.Pending));
            // The baseline hides the files that are done.
            Assert.Empty(CaptureWatchPlugin.ReadScreenshots(folder, items.Max(i => i.Id), now).Items);
            // A folder that is gone gives nothing.
            Assert.Empty(CaptureWatchPlugin.ReadScreenshots(Path.Combine(folder, "gone"), 0, now).Items);
        }
        finally
        {
            Directory.Delete(folder, true);
        }
    }

    [Fact]
    public async Task TheSwitchIsOffByDefaultAndStays()
    {
        var folder = CoreTests.TempDir();
        var capture = new CaptureWatchPlugin(new FakeCapturePlatform(folder));
        using (var t = new TestCore(new LanConfig { LoopbackOnly = true }, [capture]))
        {
            await Wait.UntilAsync(() => capture.Model.ScreenshotFolder == folder, "the folder in the model");
            Assert.False(capture.SendScreenshots);
            Assert.False(capture.Model.Screenshots);
            capture.SetSendScreenshots(true);
            Assert.True(capture.Model.Screenshots);
            Assert.True(t.Core.Settings.Bool(CaptureWatchPlugin.ScreenshotsKey, false));
            // The switch stores the time that it turned on.
            await Wait.UntilAsync(() => CaptureState.FromJson(t.Core.Settings.Node(CaptureWatchPlugin.StateKey)).From.ContainsKey(CaptureKind.Screenshot),
                "the state of the switch");
            capture.SetSendScreenshots(false);
            await Wait.UntilAsync(() => CaptureState.FromJson(t.Core.Settings.Node(CaptureWatchPlugin.StateKey)).From.Count == 0, "the state after off");
            capture.Dispose();
        }
        Directory.Delete(folder, true);
    }

    // A screenshot that Windows saves while no computer is connected waits.
    // After the pairing, it goes to fluxd once, as a screenshot. An image
    // from before the switch and a file that is not an image stay home.
    [FluxdFact]
    public async Task NewScreenshotsGoToTheComputer()
    {
        var folder = CoreTests.TempDir();
        await using var fluxd = await Fluxd.StartAsync(38016, 38020);
        var share = new SharePlugin(new FakeSharePlatform());
        using var capture = new CaptureWatchPlugin(new FakeCapturePlatform(folder));
        using var t = new TestCore(new LanConfig
        {
            UdpPort = 38031,
            PeerUdpPort = fluxd.UdpPort,
            FirstTcpPort = 38040,
            LastTcpPort = 38048,
            LoopbackOnly = true,
        }, [share, capture]);
        await File.WriteAllBytesAsync(Path.Combine(folder, "Screenshot (1).png"), Png());
        await Task.Delay(100);
        capture.SetSendScreenshots(true);
        await Task.Delay(100);
        var shot = Png().Concat(new byte[] { 1, 2, 3 }).ToArray();
        await File.WriteAllBytesAsync(Path.Combine(folder, "Screenshot (2).png"), shot);
        await File.WriteAllTextAsync(Path.Combine(folder, "notes.txt"), "stays home");
        // The scans wait for a computer.
        await Task.Delay(TimeSpan.FromSeconds(4));
        Assert.Empty(share.Model.Transfers);

        await EndToEndTests.PairFromWindowsAsync(fluxd, t);
        var screenshots = Path.Combine(fluxd.Root, "Pictures", "flux", "screenshots");
        var target = Path.Combine(screenshots, "Screenshot (2).png");
        await Wait.UntilAsync(() => File.Exists(target) && File.ReadAllBytes(target).AsSpan().SequenceEqual(shot), "the screenshot on fluxd", fluxd, 30);
        // The next scans send nothing again.
        capture.Poke();
        await Task.Delay(TimeSpan.FromSeconds(3));
        Assert.Equal(["Screenshot (2).png"], Directory.GetFiles(screenshots).Select(Path.GetFileName));
        Assert.False(Directory.Exists(Path.Combine(fluxd.Root, "Downloads", "notes.txt")));
        Assert.Single(share.Model.Transfers);
        var state = CaptureState.FromJson(t.Core.Settings.Node(CaptureWatchPlugin.StateKey));
        Assert.Empty(state.Sent);
        Assert.True(state.Baseline > 0);
        Directory.Delete(folder, true);
    }
}
