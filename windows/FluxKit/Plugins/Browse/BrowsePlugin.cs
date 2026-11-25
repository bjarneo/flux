namespace FluxKit;

// Opens the files that Get files downloaded. The Windows app implements it
// with the shell and File Explorer.
public interface IBrowseFiles
{
    // Opens the file with its app.
    void Open(string path);

    // Shows the file in File Explorer.
    void Reveal(string path);
}

// Get files: browse the files of the computer, read-only. This computer
// asks with flux.sftp.request. The Omarchy computer answers with flux.sftp:
// a tunnel token, the user, and a one-time password. fluxd then connects to
// a tunnel listener on this computer, and the SSH session runs inside the
// tunnel. BrowsePlugin.swift of the Mac app has the same rules.
public sealed class BrowsePlugin(IBrowseFiles? files = null) : IFluxPlugin
{
    // The notification category of finished downloads.
    public const string DownloadCategory = "browse.download";

    // The user info key with the path of the downloaded file.
    public const string PathKey = "path";

    // The notification action that shows the file in File Explorer.
    public const string RevealAction = "reveal";

    FluxCore? core;
    // The open browse windows by device ID. Only the UI thread uses it.
    readonly Dictionary<string, BrowseModel> browsers = [];

    public IReadOnlyList<string> Incoming { get; } = [PacketType.Sftp];
    public IReadOnlyList<string> Outgoing { get; } = [PacketType.SftpRequest, PacketType.Tunnel];

    public void Attach(FluxCore core)
    {
        this.core = core;
        core.Host.Notifier.Register(DownloadCategory, [new NotificationAction(RevealAction, "Show in File Explorer")], (action, info, _) =>
        {
            if (files is null || !info.TryGetValue(PathKey, out var path) || !Downloaded(core, path))
            {
                return;
            }
            core.Host.Post(() =>
            {
                if (action == RevealAction)
                {
                    files.Reveal(path);
                }
                else if (action == Notifier.DefaultAction)
                {
                    files.Open(path);
                }
            });
        });
    }

    // True for a file in the downloads folder. A notification opens only
    // such a file, also when another program makes the activation.
    static bool Downloaded(FluxCore core, string path)
    {
        var folder = Path.GetFullPath(core.Host.Downloads());
        var full = Path.GetFullPath(path);
        var inside = full.StartsWith(Path.TrimEndingDirectorySeparator(folder) + Path.DirectorySeparatorChar,
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
        return inside && File.Exists(full);
    }

    // The browser of a computer. A new browser asks the computer for a
    // session. Call it on the UI thread.
    public BrowseModel? Browser(string deviceId)
    {
        if (browsers.TryGetValue(deviceId, out var b))
        {
            return b;
        }
        if (core is null)
        {
            return null;
        }
        b = new BrowseModel(core, deviceId);
        browsers[deviceId] = b;
        b.Start();
        return b;
    }

    // Ends the session of the browser of a computer, when its window
    // closes. Call it on the UI thread.
    public void Close(string deviceId)
    {
        if (browsers.Remove(deviceId, out var b))
        {
            b.Close();
        }
    }

    public void Handle(Packet packet, Device device)
    {
        if (core is not { } c)
        {
            return;
        }
        var tls = c.Tls;
        var certificate = device.Certificate;
        var id = device.Id;
        c.Host.Post(() => browsers.GetValueOrDefault(id)?.Receive(packet, tls, certificate));
    }

    public void OnConnected(Device device)
    {
        var id = device.Id;
        core?.Host.Post(() => browsers.GetValueOrDefault(id)?.Connected());
    }

    public void OnDisconnected(Device device)
    {
        var id = device.Id;
        core?.Host.Post(() => browsers.GetValueOrDefault(id)?.Disconnected());
    }
}
