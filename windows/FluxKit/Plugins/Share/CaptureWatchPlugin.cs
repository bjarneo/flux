using System.Net.Sockets;
using System.Security.Authentication;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;

namespace FluxKit;

// What the capture watch needs from Windows. The WPF app implements it, and
// tests use a fake.
public interface ICapturePlatform
{
    // The folder of new screenshots: the Screenshots known folder of
    // Windows, or null when Windows has none. The watch calls it on any
    // thread.
    string? ScreenshotFolder();
}

// The capture watch state that the UI shows.
public sealed class CaptureModel : Model
{
    bool screenshots;
    string screenshotFolder = "";

    // True while new screenshots go to the computers.
    public bool Screenshots
    {
        get => screenshots;
        internal set => Set(ref screenshots, value);
    }

    // The folder that the watch reads, or an empty text when Windows has none.
    public string ScreenshotFolder
    {
        get => screenshotFolder;
        internal set => Set(ref screenshotFolder, value);
    }
}

// Sends each new screenshot to the connected computers, when its switch is
// on. A screenshot waits until a computer connects. The watch reads the
// Screenshots folder of Windows, where Windows and Print Screen and the
// Snipping Tool save, and CapturePlanner decides what goes out, so that no
// image goes out twice. CaptureWatchPlugin.swift of the Mac app has the same
// rules. The Mac also sends new photos of the Photos library. Windows has no
// such library, so this watch sends only screenshots.
public sealed class CaptureWatchPlugin : IFluxPlugin, IDisposable
{
    internal const string ScreenshotsKey = "capture.screenshots";
    internal const string StateKey = "capture.state";

    // How long the watch waits after a change before it scans.
    internal static readonly TimeSpan ScanDelay = TimeSpan.FromSeconds(1.5);

    // A file that changed within this time is still being written.
    internal static readonly TimeSpan QuietTime = TimeSpan.FromSeconds(2);

    readonly ICapturePlatform platform;
    readonly Channel<bool?> commands = Channel.CreateUnbounded<bool?>(new UnboundedChannelOptions { SingleReader = true });
    readonly Timer timer;
    // Guards the folder watch.
    readonly Lock gate = new();
    FileSystemWatcher? watcher;
    string? watched;
    FluxCore? core;
    bool disposed;

    public CaptureWatchPlugin(ICapturePlatform platform)
    {
        this.platform = platform;
        // A command of null scans, and true or false sets the switch.
        timer = new Timer(_ => commands.Writer.TryWrite(null));
    }

    public CaptureModel Model { get; } = new();

    // The watch accepts no packets. It sends through SharePlugin.
    public IReadOnlyList<string> Incoming { get; } = [];
    public IReadOnlyList<string> Outgoing { get; } = [];

    public void Attach(FluxCore core)
    {
        this.core = core;
        var on = SendScreenshots;
        var folder = platform.ScreenshotFolder() ?? "";
        core.Host.Post(() =>
        {
            Model.Screenshots = on;
            Model.ScreenshotFolder = folder;
        });
        _ = Task.Run(RunAsync);
        Refresh();
    }

    // New images that no computer took yet go out now.
    public void OnConnected(Device device) => Poke();

    public void Handle(Packet packet, Device device)
    {
    }

    // Settings

    // Sends each new screenshot to the computers. The default is off.
    public bool SendScreenshots => core?.Settings.Bool(ScreenshotsKey, false) ?? false;

    // Turns the screenshot switch on or off. Call it on the UI thread.
    public void SetSendScreenshots(bool on)
    {
        if (core is not { } c)
        {
            return;
        }
        c.Settings.Set(ScreenshotsKey, on);
        Model.Screenshots = on;
        Model.ScreenshotFolder = platform.ScreenshotFolder() ?? "";
        commands.Writer.TryWrite(on);
        Refresh();
    }

    // Watch

    // Starts or stops the folder watch to match the switch, then scans.
    void Refresh()
    {
        Rewatch(SendScreenshots ? platform.ScreenshotFolder() : null);
        Poke();
    }

    // Watches the folder for new files, or nothing when folder is null.
    void Rewatch(string? folder)
    {
        lock (gate)
        {
            if (disposed || (watcher is not null && watched == folder))
            {
                return;
            }
            watcher?.Dispose();
            watcher = null;
            watched = null;
            if (folder is null)
            {
                return;
            }
            try
            {
                // Windows makes the folder at the first screenshot. The watch
                // makes it first, so that it sees that screenshot.
                Directory.CreateDirectory(folder);
                var w = new FileSystemWatcher(folder)
                {
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime,
                    IncludeSubdirectories = false,
                };
                w.Created += (_, _) => Poke();
                w.Renamed += (_, _) => Poke();
                w.Changed += (_, _) => Poke();
                // After an overflow, the next scan reads the whole folder and watches it again.
                w.Error += (_, e) =>
                {
                    FluxLog.Info("capture", $"the folder watch failed: {e.GetException().Message}");
                    lock (gate)
                    {
                        if (watcher == w)
                        {
                            watcher = null;
                            watched = null;
                        }
                    }
                    w.Dispose();
                    Poke();
                };
                w.EnableRaisingEvents = true;
                watcher = w;
                watched = folder;
            }
            catch (Exception e) when (e is IOException or ArgumentException or UnauthorizedAccessException or PlatformNotSupportedException)
            {
                FluxLog.Error("capture", $"cannot watch the screenshot folder: {e.Message}");
            }
        }
    }

    // Scans soon. A new file or a computer that connects calls it. More
    // calls in a row give 1 scan.
    public void Poke()
    {
        lock (gate)
        {
            if (!disposed)
            {
                timer.Change(ScanDelay, Timeout.InfiniteTimeSpan);
            }
        }
    }

    // Worker

    // Runs the commands one at a time, in order.
    async Task RunAsync()
    {
        await foreach (var command in commands.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            try
            {
                if (command is { } on)
                {
                    var state = LoadState();
                    SaveState(on ? state.Enable(CaptureKind.Screenshot, Micros(DateTime.UtcNow)) : state.Disable(CaptureKind.Screenshot));
                }
                else
                {
                    await ScanAsync().ConfigureAwait(false);
                }
            }
            catch (Exception e)
            {
                // A bug must not stop the watch.
                FluxLog.Error("capture", $"a scan failed: {e}");
            }
        }
    }

    // Scans the new images and sends the ones that CapturePlanner picks.
    async Task ScanAsync()
    {
        if (core is not { } c || !SendScreenshots || platform.ScreenshotFolder() is not { } folder)
        {
            return;
        }
        Rewatch(folder);
        c.Host.Post(() => Model.ScreenshotFolder = folder);
        var now = DateTime.UtcNow;
        var state = LoadState();
        var (items, files) = ReadScreenshots(folder, state.Baseline, now);
        var plan = CapturePlanner.Plan(state, items, new DateTimeOffset(now).ToUnixTimeSeconds());
        state = plan.State;
        SaveState(state);
        // A file that is still being written needs another look.
        if (items.Any(i => i.Pending))
        {
            Poke();
        }
        if (plan.Waiting > 0)
        {
            FluxLog.Info("capture", $"{plan.Waiting} images wait for the next scan, because 1 scan sends at most {CapturePlanner.MaxSend}");
        }
        if (plan.Send.Count == 0)
        {
            return;
        }
        var targets = c.ConnectedPairedIds(PacketType.Share);
        if (targets.Count == 0 || c.Plugin<SharePlugin>() is not { } share)
        {
            return;
        }
        var any = false;
        foreach (var (item, _) in plan.Send)
        {
            // A switch that turned off during the scan stops the rest.
            if (!SendScreenshots)
            {
                break;
            }
            if (!files.TryGetValue(item.Id, out var path))
            {
                continue;
            }
            if (await SendAsync(item, path, targets, share).ConfigureAwait(false))
            {
                any = true;
                state = state.MarkSent(item.Id);
                SaveState(state);
            }
        }
        // The sent images can move the baseline now. Images that wait go
        // with the next change, connect, or start, not at once, so that a
        // large batch does not go out in a row of scans.
        if (any && plan.Waiting == 0)
        {
            Poke();
        }
    }

    // Lists the files in the screenshot folder that arrived after the
    // baseline, and the path of each. The ID of a file is the time that it
    // was made in the folder: a copy into the folder gets a new time, as a
    // new screenshot does.
    internal static (List<CaptureItem> Items, Dictionary<long, string> Files) ReadScreenshots(string folder, long baseline, DateTime now)
    {
        var items = new List<CaptureItem>();
        var files = new Dictionary<long, string>();
        IEnumerable<string> paths;
        try
        {
            paths = Directory.EnumerateFiles(folder).ToArray();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            FluxLog.Error("capture", $"cannot read the screenshot folder: {e.GetType().Name}");
            return (items, files);
        }
        var found = new List<(FileInfo Info, DateTime Added, DateTime Changed)>();
        foreach (var path in paths)
        {
            try
            {
                // Windows does not hide a name that starts with a dot, as
                // other systems do, so the scan skips such names itself.
                var info = new FileInfo(path);
                if (info.Exists && !info.Name.StartsWith('.') && (info.Attributes & (FileAttributes.Hidden | FileAttributes.System)) == 0)
                {
                    found.Add((info, info.CreationTimeUtc, info.LastWriteTimeUtc));
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // The file went away during the scan.
            }
        }
        // The clock of the file system moves in steps of a few milliseconds,
        // so files that a copy adds at once can have the same time. Such
        // files get the IDs after that time in the order of their names, 1
        // microsecond apart, so that each file keeps its own ID in each scan.
        foreach (var same in found.GroupBy(f => Micros(f.Added)))
        {
            var index = 0;
            foreach (var (info, added, changed) in same.OrderBy(f => f.Info.Name, StringComparer.Ordinal))
            {
                var id = same.Key + index++;
                if (id <= baseline)
                {
                    continue;
                }
                items.Add(new CaptureItem(id, CaptureRules.IsScreenshot(info.Name) ? CaptureKind.Screenshot : null, info.Name,
                    now - changed < QuietTime, new DateTimeOffset(added).ToUnixTimeSeconds()));
                files[id] = info.FullName;
            }
        }
        return (items, files);
    }

    // Sends 1 image to each target. It returns true when at least 1 target took it.
    async Task<bool> SendAsync(CaptureItem item, string path, IReadOnlyList<string> targets, SharePlugin share)
    {
        // The photo marker too, so that an older fluxd saves it as a photo.
        var extra = new JsonObject { ["photo"] = true, ["screenshot"] = true };
        var any = false;
        foreach (var id in targets)
        {
            try
            {
                await share.SendCaptureAsync(path, item.Name, extra, id).ConfigureAwait(false);
                any = true;
                FluxLog.Info("capture", $"sent a screenshot to {id}");
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ShareException or TimeoutException or OperationCanceledException or
                                          SocketException or AuthenticationException or ObjectDisposedException or InvalidDataException or JsonException or ArgumentException)
            {
                FluxLog.Error("capture", $"a screenshot did not go to {id}: {e.GetType().Name}");
            }
        }
        return any;
    }

    // Storage

    CaptureState LoadState() => CaptureState.FromJson(core?.Settings.Node(StateKey));

    void SaveState(CaptureState state) => core?.Settings.Set(StateKey, state.ToJson());

    internal static long Micros(DateTime utc) => (utc.ToUniversalTime() - DateTime.UnixEpoch).Ticks / 10;

    public void Dispose()
    {
        lock (gate)
        {
            disposed = true;
            watcher?.Dispose();
            watcher = null;
            watched = null;
        }
        timer.Dispose();
        commands.Writer.TryComplete();
    }
}
