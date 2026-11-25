using System.Collections.Concurrent;
using FluxKit;

namespace FluxKit.Tests;

// Get files against a headless fluxd: the SSH session runs in the tunnel
// through the loopback bridge, and fluxd serves the home folder of its test
// root.
public class BrowseEndToEndTests
{
    sealed class Files : IBrowseFiles
    {
        public ConcurrentQueue<string> Opened { get; } = new();
        public ConcurrentQueue<string> Revealed { get; } = new();
        public void Open(string path) => Opened.Enqueue(path);
        public void Reveal(string path) => Revealed.Enqueue(path);
    }

    [FluxdFact]
    public async Task BrowsesDownloadsAndSearchesTheHomeFolder()
    {
        await using var fluxd = await Fluxd.StartAsync(34316, 34320);
        // 300 KB needs many SFTP reads.
        var data = new byte[300_000];
        new Random(34316).NextBytes(data);
        File.WriteAllBytes(Path.Combine(fluxd.Root, "flux-report.bin"), data);
        File.WriteAllText(Path.Combine(fluxd.Root, ".hidden-report"), "secret");
        Directory.CreateDirectory(Path.Combine(fluxd.Root, "Documents", "Work"));
        File.WriteAllText(Path.Combine(fluxd.Root, "Documents", "Work", "plan-report.md"), "plan");

        var files = new Files();
        var browse = new BrowsePlugin(files);
        using var h = new ControlHarness(ControlHarness.Lan(fluxd, 34331, 34340), [browse]);
        var computer = await h.PairAsync(fluxd);
        var model = (await h.OnUi(() => browse.Browser(computer.Id)))!;
        Assert.Same(model, await h.OnUi(() => browse.Browser(computer.Id)));

        // The home folder of fluxd is the first root.
        await Wait.UntilAsync(() => !model.Loading && model.Entries.Any(e => e.Name == "flux-report.bin"), "the home folder", fluxd, 30);
        Assert.Null(model.Error);
        Assert.Equal(new BrowseRoot("Home", fluxd.Root), model.Roots[0]);
        Assert.Contains(new BrowseRoot("Downloads", Path.Combine(fluxd.Root, "Downloads")), model.Roots);
        Assert.Contains(new BrowseRoot("Documents", Path.Combine(fluxd.Root, "Documents")), model.Roots);
        Assert.Equal(fluxd.Root, model.Path);
        Assert.True(model.CanSearch);
        Assert.False(model.CanGoUp);
        Assert.Equal("Search all shared folders", model.SearchPrompt);
        Assert.DoesNotContain(model.Entries, e => e.Name.StartsWith('.'));
        var entry = model.Entries.Single(e => e.Name == "flux-report.bin");
        Assert.False(entry.Dir);
        Assert.Equal(data.Length, entry.Size);
        Assert.NotNull(entry.Modified);
        // Folders come first.
        Assert.True(model.Entries[0].Dir);

        // A download lands in the downloads folder of this computer.
        await h.OnUi(() => model.Download(entry));
        await Wait.UntilAsync(() => model.Downloads.Count == 1 && !model.Downloads[0].IsRunning, "the download", fluxd);
        var download = model.Downloads[0];
        var done = Assert.IsType<BrowseDownloadState.Done>(download.State);
        Assert.Equal(Path.Combine(h.Downloads, "flux-report.bin"), done.Path);
        Assert.Equal(data, File.ReadAllBytes(done.Path));
        Assert.False(File.Exists(done.Path + ".part"));
        Assert.Equal(data.Length, download.Received);
        Assert.Equal(1, download.Fraction);
        await Wait.UntilAsync(() => h.Toasts.Contains("Saved flux-report.bin in Downloads"), "the toast");
        var note = h.Notifications.Single();
        Assert.Equal(BrowsePlugin.DownloadCategory, note.Category);
        Assert.Equal("Downloaded flux-report.bin", note.Title);
        Assert.Equal(done.Path, note.UserInfo[BrowsePlugin.PathKey]);

        // A second download of the same file gets a free name.
        await h.OnUi(() => model.Download(entry));
        await Wait.UntilAsync(() => model.Downloads.Count == 2 && !model.Downloads[1].IsRunning, "the second download", fluxd);
        Assert.Equal("flux-report (2).bin", model.Downloads[1].Name);
        await h.OnUi(model.ClearDownloads);
        Assert.Empty(model.Downloads);

        // A click on the notification opens the file. A path outside the
        // downloads folder opens nothing.
        h.Core.Host.Notifier.Activate(BrowsePlugin.DownloadCategory, Notifier.DefaultAction, new Dictionary<string, string> { [BrowsePlugin.PathKey] = done.Path });
        h.Core.Host.Notifier.Activate(BrowsePlugin.DownloadCategory, BrowsePlugin.RevealAction, new Dictionary<string, string> { [BrowsePlugin.PathKey] = done.Path });
        h.Core.Host.Notifier.Activate(BrowsePlugin.DownloadCategory, Notifier.DefaultAction,
            new Dictionary<string, string> { [BrowsePlugin.PathKey] = Path.Combine(fluxd.Root, "flux-report.bin") });
        await Wait.UntilAsync(() => files.Opened.Count == 1 && files.Revealed.Count == 1, "the open and the reveal");
        await h.OnUi(() => { });
        Assert.Equal([done.Path], files.Opened);
        Assert.Equal([done.Path], files.Revealed);

        // A search of each shared folder finds the files by name, without
        // hidden names.
        await h.OnUi(() => model.Search("report"));
        await Wait.UntilAsync(() => !model.Searching, "the search", fluxd);
        Assert.Null(model.SearchError);
        var found = model.Found!;
        Assert.Contains(found.Results, r => r.Path == Path.Combine(fluxd.Root, "flux-report.bin") && !r.Dir && r.Size == data.Length);
        var plan = Assert.Single(found.Results, r => r.Name == "plan-report.md");
        Assert.DoesNotContain(found.Results, r => r.Name.StartsWith('.'));
        Assert.True(model.InSearch);
        Assert.True(model.CanGoBack);
        Assert.Equal("Documents/Work", model.Location(plan));

        // A folder of the results opens in place of the search.
        await h.OnUi(() => model.Activate(new BrowseEntry("Work", Path.Combine(fluxd.Root, "Documents", "Work"), true, 0)));
        await Wait.UntilAsync(() => !model.Loading && model.Entries.Any(e => e.Name == "plan-report.md"), "the folder", fluxd);
        Assert.False(model.InSearch);
        Assert.Null(model.Found);
        Assert.True(model.CanGoUp);
        Assert.Equal(["Documents", "Work"], model.Crumbs.Select(c => c.Name));
        Assert.Equal(Path.Combine(fluxd.Root, "Documents", "Work"), model.SearchScope);
        Assert.Equal("Search in Work", model.SearchPrompt);

        // A search in the folder reads only the folder.
        await h.OnUi(() => model.Search("report"));
        await Wait.UntilAsync(() => !model.Searching, "the search in the folder", fluxd);
        Assert.Equal(["plan-report.md"], model.Found!.Results.Select(r => r.Name));
        await h.OnUi(model.GoUp);
        Assert.False(model.InSearch);
        await h.OnUi(model.GoUp);
        await Wait.UntilAsync(() => !model.Loading && model.Path == Path.Combine(fluxd.Root, "Documents"), "the folder above", fluxd);

        // A path outside the roots fails.
        await h.OnUi(() => model.Open("/etc"));
        await Wait.UntilAsync(() => !model.Loading, "the refusal", fluxd);
        Assert.StartsWith("Cannot open /etc: ", model.Error);
        Assert.Empty(model.Entries);

        // The window closes, and fluxd ends the session.
        await h.OnUi(() => browse.Close(computer.Id));
        await Wait.UntilAsync(() => fluxd.Log.Contains("Browse PC stopped"), "the end of the session on fluxd", fluxd);
    }

    [FluxdFact]
    public async Task SessionEndsWhenFluxdStopsItAndStartsAgain()
    {
        await using var fluxd = await Fluxd.StartAsync(34416, 34420);
        var browse = new BrowsePlugin();
        using var h = new ControlHarness(ControlHarness.Lan(fluxd, 34431, 34440), [browse]);
        var computer = await h.PairAsync(fluxd);
        var model = (await h.OnUi(() => browse.Browser(computer.Id)))!;
        await Wait.UntilAsync(() => !model.Loading && model.Entries.Count > 0, "the home folder", fluxd, 30);

        // flux-cli browse stop ends the session on fluxd.
        await fluxd.CliAsync("browse", "stop");
        await Wait.UntilAsync(() => model.Error == $"The session with {computer.Name} ended.", "the end of the session", fluxd);
        Assert.False(model.CanGoUp);

        // Retry asks for a new session.
        await h.OnUi(model.Retry);
        await Wait.UntilAsync(() => !model.Loading && model.Error is null && model.Entries.Count > 0, "the new session", fluxd, 30);

        // The next stop ends the new session too.
        await fluxd.CliAsync("browse", "stop");
        await Wait.UntilAsync(() => model.Error is not null, "the second end", fluxd);
        await h.OnUi(model.Close);
    }

    [FluxdFact]
    public async Task FluxdRefusesBrowsingWhenTheDeviceMayNot()
    {
        await using var fluxd = await Fluxd.StartAsync(34516, 34520);
        var browse = new BrowsePlugin();
        using var h = new ControlHarness(ControlHarness.Lan(fluxd, 34531, 34540), [browse]);
        var computer = await h.PairAsync(fluxd);
        await fluxd.CliAsync("device-settings", "shareHome", "false");
        var model = (await h.OnUi(() => browse.Browser(computer.Id)))!;
        await Wait.UntilAsync(() => !model.Loading, "the answer", fluxd);
        Assert.Equal("Browsing is off on this computer. Set share_home = true in ~/.config/flux/config.toml", model.Error);
        Assert.Empty(model.Roots);
        await h.OnUi(() => browse.Close(computer.Id));
    }
}
