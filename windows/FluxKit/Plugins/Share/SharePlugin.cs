using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace FluxKit;

// An error of a share action, with a text for the user.
public sealed class ShareException(string message) : Exception(message);

// File, text, and link sharing: flux.share.request in both directions, and
// flux.transfer for resumable files from the computer. A file from the
// computer comes through a Flux tunnel. A file to the computer goes out on a
// payload port that this device opens. SharePlugin.swift of the Mac app has
// the same rules.
//
// This device never opens a received file or link by itself. The user opens
// a file from its notification or the share page, and a link from its
// notification.
public sealed class SharePlugin(ISharePlatform? platform = null, IShareNotificationLimit? notificationLimit = null) : IFluxPlugin
{
    // The largest text or link that SendText sends. The computer reads 1
    // packet as 1 line and closes the link after a line over its limit.
    public const int MaxText = 1 << 20;

    // The space that a received file leaves free on the volume, in bytes.
    internal const long FreeSpaceReserve = 256L << 20;

    // How long a payload port waits for the computer.
    static readonly TimeSpan AcceptTimeout = TimeSpan.FromSeconds(60);

    internal const string FileCategory = "share.file";
    internal const string LinkCategory = "share.link";
    internal const string FolderKey = "share.downloadFolder";

    // The name of the default folder in messages.
    internal const string DownloadsName = "Downloads";

    FluxCore? core;
    ResumableTransfer? resumable;
    IShareNotificationLimit? limit = notificationLimit;

    readonly Lock gate = new();
    // The transfers that run, so that a cancel or an unpair ends them.
    readonly Dictionary<Guid, (string DeviceId, CancellationTokenSource Cancel)> jobs = [];
    // The model entry of each resumable transfer, by its folder key. A retry
    // of the computer keeps the entry.
    readonly Dictionary<string, ResumeEntry> resumed = [];

    public ShareModel Model { get; } = new();
    public ISharePlatform? Platform { get; } = platform;

    public IReadOnlyList<string> Incoming => Resumable
        ? [PacketType.Share, PacketType.ShareUpdate, PacketType.Transfer]
        : [PacketType.Share, PacketType.ShareUpdate];

    public IReadOnlyList<string> Outgoing { get; } = [PacketType.Share, PacketType.ShareUpdate, PacketType.Tunnel, PacketType.Transfer];

    // False leaves flux.transfer out of the capabilities, so that fluxd sends
    // files only through flux.share.request, as to an older app. Tests use it.
    internal bool Resumable { get; init; } = true;

    // Returns the bytes that a folder can take, or null when the volume does
    // not tell. Tests replace it before Attach.
    internal Func<string, long?> FreeSpace { get; set; } = DiskFreeSpace;

    public void Attach(FluxCore core)
    {
        this.core = core;
        resumable = new ResumableTransfer(core.Paths.File("incoming")) { FreeSpace = FreeSpace };
        limit ??= new ShareNotificationLimit(core.Host.Notifier);
        var folder = DownloadFolder;
        Ui(m => m.DownloadFolder = folder);
        core.Host.Notifier.Register(FileCategory, [new("open", "Open"), new("reveal", "Show in folder")], (action, info, _) =>
        {
            if (Platform is not { } p || !info.TryGetValue("path", out var path))
            {
                return;
            }
            core.Host.Post(() =>
            {
                if (action == "reveal")
                {
                    p.ShowInFolder(path);
                }
                else
                {
                    p.OpenFile(path);
                }
            });
        });
        core.Host.Notifier.Register(LinkCategory, [new("open", "Open")], (_, info, _) =>
        {
            if (Platform is { } p && info.TryGetValue("url", out var link) && ShareWire.WebUrl(link) is { } url)
            {
                core.Host.Post(() => p.OpenLink(url));
            }
        });
    }

    // Settings

    // The folder for received files. The default is the Downloads folder.
    public string DownloadFolder =>
        core?.Settings.String(FolderKey) is { Length: > 0 } path ? path : core?.Host.Downloads() ?? "";

    public void SetDownloadFolder(string path)
    {
        core?.Settings.Set(FolderKey, path);
        Ui(m => m.DownloadFolder = path);
    }

    // The name of a folder in messages. The default folder has the name that
    // users know.
    internal string PlaceName(string folder)
    {
        static string Clean(string p) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(p));
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (core is not null && string.Equals(Clean(folder), Clean(core.Host.Downloads()), comparison))
        {
            return DownloadsName;
        }
        return Path.GetFileName(Path.TrimEndingDirectorySeparator(folder));
    }

    // Receive

    // Text goes on the clipboard, a web link waits in a notification, and a
    // file goes to the download folder. A share.request.update only announces
    // a batch, so it needs no action. The core lock is held.
    public void Handle(Packet packet, Device device)
    {
        if (core is not { } c)
        {
            return;
        }
        if (packet.Type == PacketType.Transfer)
        {
            if (packet.String("action") is "offer" or "chunk" && device.Certificate is { } certificate)
            {
                var job = new Resume(device.Id, device.Name, certificate, packet);
                _ = Task.Run(() => ReceiveResumableAsync(job));
            }
            return;
        }
        if (packet.Type != PacketType.Share || ShareRequest.Parse(packet) is not { } request)
        {
            return;
        }
        var from = device.Name;
        switch (request)
        {
            case SharedText text:
                if (Platform is { } p)
                {
                    var id = device.Id;
                    c.Host.Post(() => p.PutText(text.Text, id));
                }
                c.Toast($"Text from {from} is on the clipboard");
                break;
            case SharedLink link:
                ReceiveLink(c, device, link.Url);
                break;
            case SharedFile file:
                if (packet.PayloadTunnel is not { } token || device.Certificate is not { } cert)
                {
                    return;
                }
                if (packet.PayloadSize <= 0)
                {
                    device.Send(Tunnel.Failed(token, "the file has no size"));
                    return;
                }
                c.Toast($"Receiving {file.Name}");
                var download = new Download(device.Id, from, token, cert, packet.PayloadSize, file.Name, file.LastModified);
                _ = Task.Run(() => DownloadAsync(download));
                break;
        }
    }

    // The link opens only after a click on its notification, like in the
    // Android app. The links share the notification limit of the computer,
    // so that a computer cannot bury the other notifications.
    void ReceiveLink(FluxCore c, Device device, Uri url)
    {
        var from = device.Name;
        c.Toast($"Link from {from}");
        if (limit is not { } l)
        {
            return;
        }
        if (!l.AllowsNow(device.Id))
        {
            FluxLog.Info("share", $"dropped a link notification: too many from {from}");
            return;
        }
        var id = LinkId(device.Id);
        l.Delivered(id, device.Id);
        c.Host.Notifier.Post(new SystemNotification(id, LinkCategory, $"Link from {from}", url.OriginalString)
        {
            UserInfo = new Dictionary<string, string> { ["url"] = url.OriginalString },
        });
    }

    // A new notification ID for a received link of the computer. The ID
    // continues with the device ID, a colon, and a GUID, like on the Mac.
    internal static string LinkId(string deviceId) => $"share-link-{deviceId}:{Guid.NewGuid()}";

    // An unpair ends the transfers of the computer. A link that only drops
    // leaves them, because they have their own connections.
    public void OnDisconnected(Device device)
    {
        if (device.Paired)
        {
            return;
        }
        CancellationTokenSource[] ended;
        lock (gate)
        {
            var mine = jobs.Where(j => j.Value.DeviceId == device.Id).ToArray();
            foreach (var j in mine)
            {
                jobs.Remove(j.Key);
            }
            ended = mine.Select(j => j.Value.Cancel).ToArray();
        }
        // The cancel runs off the core lock, because the transfers continue
        // in their callbacks.
        foreach (var cts in ended)
        {
            _ = cts.CancelAsync();
        }
    }

    // Stops a transfer that runs. A canceled resumable file from the computer
    // stays refused: its next offers get an error, so the computer does not
    // send it again.
    public void Cancel(Guid transferId)
    {
        CancellationTokenSource? cts = null;
        string? key = null;
        lock (gate)
        {
            if (jobs.TryGetValue(transferId, out var job))
            {
                cts = job.Cancel;
            }
            foreach (var (k, entry) in resumed)
            {
                if (entry.Transfer.Id == transferId)
                {
                    key = k;
                }
            }
            if (key is not null)
            {
                resumed.Remove(key);
            }
        }
        _ = cts?.CancelAsync();
        if (key is not null && resumable is { } r)
        {
            _ = Task.Run(() => r.Cancel(key));
            Ui(m => m.Finish(transferId, null, TransferState.Canceled));
        }
    }

    // Registers a new transfer, so that a cancel or an unpair ends it. It
    // returns null when the computer is no longer paired.
    CancellationTokenSource? Begin(Guid id, string deviceId)
    {
        var cts = new CancellationTokenSource();
        return Register(id, deviceId, cts) ? cts : null;
    }

    // Registers the token of a transfer. It returns false when the computer
    // is no longer paired. The core lock comes first, as in an unpair, so
    // that an unpair sees the transfer or the transfer sees the unpair.
    bool Register(Guid id, string deviceId, CancellationTokenSource cts) =>
        core?.WithDevice(deviceId, d =>
        {
            if (!d.Paired)
            {
                return false;
            }
            lock (gate)
            {
                jobs[id] = (deviceId, cts);
            }
            return true;
        }) ?? false;

    void End(Guid id)
    {
        lock (gate)
        {
            jobs.Remove(id);
        }
    }

    // 1 file that the computer offers through a tunnel.
    sealed record Download(string DeviceId, string From, string Token, byte[] Certificate, long Size, string Name, long? LastModified);

    // 1 flux.transfer packet from the computer.
    sealed record Resume(string DeviceId, string From, byte[] Certificate, Packet Packet);

    // The model entry of a resumable transfer and its progress throttle. The
    // throttle holds across the chunks.
    sealed class ResumeEntry(FileTransfer transfer)
    {
        public FileTransfer Transfer { get; } = transfer;
        public ProgressThrottle Throttle;
    }

    // Reports whether a file of the size fits in the folder with the reserve
    // left free. It is true when the volume does not tell.
    internal bool Fits(long size, string folder) => FreeSpace(folder) is not { } free || Fits(size, free);

    internal static bool Fits(long size, long free) => size >= 0 && size <= free - FreeSpaceReserve;

    internal static long? DiskFreeSpace(string folder)
    {
        try
        {
            return new DriveInfo(Path.GetFullPath(folder)).AvailableFreeSpace;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException)
        {
            return null;
        }
    }

    async Task DownloadAsync(Download job)
    {
        if (core is not { } c)
        {
            return;
        }
        var folder = DownloadFolder;
        var transfer = new FileTransfer { DeviceId = job.DeviceId, Name = job.Name, Incoming = true, Size = job.Size };
        var cts = Begin(transfer.Id, job.DeviceId);
        Ui(m => m.Start(transfer));
        string partPath;
        FileStream part;
        try
        {
            if (cts is null)
            {
                throw new ShareException($"{job.From} is not paired");
            }
            Directory.CreateDirectory(folder);
            if (!Fits(job.Size, folder))
            {
                throw new ShareException($"there is not enough free space in {PlaceName(folder)}");
            }
            (partPath, part) = CreateExclusive(folder, job.Name + ".part");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or ShareException)
        {
            End(transfer.Id);
            c.Toast($"Cannot save {job.Name}: {e.Message}");
            c.Send(Tunnel.Failed(job.Token, "cannot save the file"), job.DeviceId);
            Ui(m => m.Finish(transfer.Id, null, TransferState.Failed, e.Message));
            return;
        }
        try
        {
            await using (part.ConfigureAwait(false))
            {
                // Listen and let the computer connect.
                var stream = await Tunnel.AcceptAsync(c.Tls, job.Certificate, job.Token, p => c.Send(p, job.DeviceId), ct: cts.Token).ConfigureAwait(false);
                await using (stream.ConfigureAwait(false))
                {
                    await stream.ReceiveAsync(part, job.Size, Progress(transfer.Id), cts.Token).ConfigureAwait(false);
                }
                part.Flush(true);
            }
            var saved = MoveExclusive(partPath, folder, job.Name);
            Mark(saved);
            // The largest time that DateTimeOffset takes is the end of 9999.
            if (job.LastModified is long ms && ms > 0 && ms < 253_402_300_799_000)
            {
                TrySetModified(saved, DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime);
            }
            Ui(m => m.Finish(transfer.Id, saved, TransferState.Done));
            var name = Path.GetFileName(saved);
            c.Host.Notifier.Post(new SystemNotification($"share-{transfer.Id}", FileCategory, $"Received {name}",
                $"From {job.From}, saved in {PlaceName(folder)}")
            {
                UserInfo = new Dictionary<string, string> { ["path"] = saved },
            });
            c.Toast($"Saved {name} in {PlaceName(folder)}");
        }
        catch (Exception e) when (Expected(e))
        {
            TryDelete(partPath);
            FluxLog.Error("share", $"receive from {job.From} failed: {LogText(e)}");
            var canceled = cts.IsCancellationRequested;
            Ui(m => m.Finish(transfer.Id, null, canceled ? TransferState.Canceled : TransferState.Failed, Describe(e)));
            if (!canceled)
            {
                c.Toast($"Receiving {job.Name} failed");
            }
        }
        finally
        {
            End(transfer.Id);
        }
    }

    // Handles 1 offer or chunk of a resumable file, and answers the computer
    // with the offset, done, or an error.
    async Task ReceiveResumableAsync(Resume job)
    {
        if (core is not { } c || resumable is not { } r)
        {
            return;
        }
        var p = job.Packet;
        var id = p.String("id");
        var cts = new CancellationTokenSource();
        // The model entry. It exists once the transfer goes on, so that a
        // refused offer adds no entry.
        ResumeEntry? entry = null;
        var tunnel = false;
        try
        {
            var outcome = await r.ReceiveAsync(p, job.DeviceId, DownloadFolder, async (token, length, target, report, ct) =>
            {
                tunnel = true;
                var stream = await Tunnel.AcceptAsync(c.Tls, job.Certificate, token, t => c.Send(t, job.DeviceId), ct: ct).ConfigureAwait(false);
                await using (stream.ConfigureAwait(false))
                {
                    await stream.ReceiveAsync(target, length, report, ct).ConfigureAwait(false);
                }
            }, offset =>
            {
                entry = Entry(job, offset);
                if (!Register(entry.Transfer.Id, job.DeviceId, cts))
                {
                    throw new ShareException($"{job.From} is not paired");
                }
                return Gated(entry);
            }, cts.Token).ConfigureAwait(false);
            c.Send(new Packet(PacketType.Transfer, new JsonObject { ["id"] = id, ["action"] = outcome.Action, ["offset"] = outcome.Offset }), job.DeviceId);
            if (outcome.Action == "offset")
            {
                return;
            }
            // The file arrived before when this message made no entry, and
            // the computer missed the answer.
            var key = ResumableTransfer.Key(job.DeviceId, id!);
            lock (gate)
            {
                if (entry is null)
                {
                    resumed.TryGetValue(key, out entry);
                }
                resumed.Remove(key);
            }
            if (entry is null)
            {
                return;
            }
            var t = entry.Transfer;
            if (outcome.Saved is not { } saved)
            {
                Ui(m => m.Finish(t.Id, null, TransferState.Done));
                return;
            }
            Mark(saved);
            Ui(m => m.Finish(t.Id, saved, TransferState.Done));
            c.Host.Notifier.Post(new SystemNotification($"share-{t.Id}", FileCategory, $"Received {Path.GetFileName(saved)}", $"From {job.From}")
            {
                UserInfo = new Dictionary<string, string> { ["path"] = saved },
            });
        }
        catch (Exception e) when (Expected(e))
        {
            var canceled = cts.IsCancellationRequested;
            var message = canceled ? ResumableTransfer.CanceledText : Describe(e);
            FluxLog.Info("share", $"a resumable transfer from {job.From} stopped: {LogText(e)}");
            // The computer waits for the tunnel of a chunk that this device
            // did not take, so it gets the error at once.
            if (!tunnel && p.PayloadTunnel is { } token)
            {
                c.Send(Tunnel.Failed(token, message), job.DeviceId);
            }
            c.Send(new Packet(PacketType.Transfer, new JsonObject { ["action"] = "error", ["id"] = id, ["error"] = message }), job.DeviceId);
            if (entry is not null)
            {
                var t = entry.Transfer;
                Ui(m => m.Finish(t.Id, null, canceled ? TransferState.Canceled : TransferState.Failed, message));
            }
        }
        finally
        {
            if (entry is not null)
            {
                End(entry.Transfer.Id);
            }
        }
    }

    // The model entry of a resumable transfer. A retry of the computer shows
    // the same entry again. ResumableTransfer runs 1 message of a transfer
    // at a time, so 1 message at a time owns the entry.
    ResumeEntry Entry(Resume job, long offset)
    {
        var p = job.Packet;
        var key = ResumableTransfer.Key(job.DeviceId, p.String("id")!);
        ResumeEntry entry;
        bool known;
        lock (gate)
        {
            known = resumed.TryGetValue(key, out var found);
            entry = found ?? new ResumeEntry(new FileTransfer
            {
                DeviceId = job.DeviceId,
                Name = ShareWire.SafeName(p.String("name") ?? ""),
                Incoming = true,
                Size = p.Long("size") ?? 0,
                Bytes = offset,
            });
            resumed[key] = entry;
        }
        var t = entry.Transfer;
        Ui(m =>
        {
            if (known)
            {
                m.Resume(t);
                m.Progress(t.Id, offset);
            }
            else
            {
                m.Start(t);
            }
        });
        return entry;
    }

    // Reports the progress of a resumable transfer at most once per
    // interval across all its chunks.
    Action<long> Gated(ResumeEntry entry)
    {
        var report = Progress(entry.Transfer.Id);
        return bytes =>
        {
            bool due;
            lock (entry)
            {
                due = entry.Throttle.Due();
            }
            if (due)
            {
                report(bytes);
            }
        };
    }

    // Creates a new file for writing: name, "name (2)", and so on. It never
    // opens a file that exists.
    internal static (string Path, FileStream Stream) CreateExclusive(string folder, string name)
    {
        while (true)
        {
            var path = ShareWire.UniquePath(folder, name, Exists);
            try
            {
                return (path, new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, FileOptions.Asynchronous));
            }
            catch (IOException) when (Exists(path))
            {
            }
        }
    }

    // Renames the file to name, "name (2)", and so on in the folder. It never
    // replaces a file.
    internal static string MoveExclusive(string file, string folder, string name)
    {
        while (true)
        {
            var path = ShareWire.UniquePath(folder, name, Exists);
            try
            {
                File.Move(file, path, overwrite: false);
                return path;
            }
            catch (IOException) when (Exists(path))
            {
            }
        }
    }

    static bool Exists(string path) => File.Exists(path) || Directory.Exists(path);

    // Marks a received file as a file from another computer. A failure leaves
    // the file without the mark, like on the Mac.
    void Mark(string path)
    {
        try
        {
            Platform?.MarkDownloaded(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            FluxLog.Error("share", $"cannot mark a received file as a download: {e.GetType().Name}");
        }
    }

    static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    static void TrySetModified(string path, DateTime utc)
    {
        try
        {
            File.SetLastWriteTimeUtc(path, utc);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
        }
    }

    // Send

    // Sends files to a computer, one at a time. A folder does not go out.
    public void SendFiles(IEnumerable<string> files, string deviceId)
    {
        if (core is not { } c)
        {
            return;
        }
        var list = new List<string>();
        foreach (var path in files)
        {
            if (Directory.Exists(path))
            {
                c.Toast($"{Path.GetFileName(Path.TrimEndingDirectorySeparator(path))} is a folder. Send the files inside it");
            }
            else
            {
                list.Add(path);
            }
        }
        if (list.Count == 0)
        {
            return;
        }
        if (FindPeer(deviceId) is not { } peer)
        {
            c.Toast("Not connected. Try again in a moment");
            return;
        }
        _ = Task.Run(() => SendBatchAsync(list, peer, (_, _) => { }));
    }

    // Sends files to a connected computer in 1 batch, like SendFiles, and
    // returns after the batch ends. result gets each file with null once the
    // computer received it, or with the error. It throws when the computer is
    // not connected, and then no file goes out.
    public async Task SendAndWaitAsync(IEnumerable<string> files, string deviceId, Action<string, Exception?> result)
    {
        var peer = FindPeer(deviceId) ?? throw new ShareException("Not connected");
        await SendBatchAsync(files.ToList(), peer, result).ConfigureAwait(false);
    }

    async Task SendBatchAsync(IReadOnlyList<string> paths, Peer peer, Action<string, Exception?> result)
    {
        if (core is not { } c)
        {
            return;
        }
        var files = new List<(string Path, long Size)>();
        foreach (var path in paths)
        {
            if (FileSize(path) is not { } size)
            {
                var name = Path.GetFileName(path);
                c.Toast($"Cannot read {name}");
                result(path, new ShareException($"cannot read {name}"));
                continue;
            }
            files.Add((path, size));
        }
        if (files.Count == 0)
        {
            return;
        }
        var total = files.Sum(f => f.Size);
        c.Send(ShareWire.Update(files.Count, total), peer.Id);
        var sent = new List<string>();
        foreach (var (path, size) in files)
        {
            var name = Path.GetFileName(path);
            try
            {
                await OfferAsync(path, size, name, peer, port => ShareWire.File(name, files.Count, total, size, port)).ConfigureAwait(false);
                sent.Add(name);
                result(path, null);
            }
            catch (Exception e) when (Expected(e))
            {
                FluxLog.Error("share", $"send to {peer.Name} failed: {LogText(e)}");
                if (e is not OperationCanceledException)
                {
                    c.Toast($"Sending {name} failed");
                }
                result(path, e);
            }
        }
        if (sent.Count == 1)
        {
            c.Toast($"Sent {sent[0]}");
        }
        else if (sent.Count > 1)
        {
            c.Toast($"Sent {sent.Count} files to {peer.Name}");
        }
    }

    // Sends 1 captured file, such as a photo or a screenshot. The body gets
    // the extra fields, for example "photo" or "scan". It returns after the
    // transfer ends.
    public async Task SendCaptureAsync(string file, string name, JsonObject extra, string deviceId)
    {
        var peer = FindPeer(deviceId) ?? throw new ShareException("Not connected");
        var size = FileSize(file) ?? throw new ShareException($"cannot read {file}");
        await OfferAsync(file, size, name, peer, port => ShareWire.Capture(name, extra, size, port)).ConfigureAwait(false);
    }

    // Sends text that the camera read. The "scan" flag makes the computer save
    // it in a file. It returns false when the computer is not connected.
    public bool SendScan(string text, string deviceId)
    {
        if (core?.Send(ShareWire.Scan(text), deviceId) != true)
        {
            return false;
        }
        Ui(m => m.Record(new SentItem(deviceId, SentKind.Scan, text)));
        return true;
    }

    // Sends text, or a link when the text is 1 URL. It returns false when the
    // text did not go out.
    // Records a clip that Send clipboard sent, so that the chat shows it on
    // the side of this computer. Text is empty for a secret. Call it on the
    // UI thread.
    public void RecordClip(IReadOnlyList<string> deviceIds, string text, long stamp)
    {
        foreach (var id in deviceIds)
        {
            Model.Record(new SentItem(id, SentKind.Clip, text, clipStamp: stamp));
        }
    }

    public bool SendText(string text, string deviceId)
    {
        if (Encoding.UTF8.GetByteCount(text) > MaxText)
        {
            core?.Toast("The text is larger than 1 MB. Send it as a file");
            return false;
        }
        if (core is not { } c || FindPeer(deviceId) is not { } peer)
        {
            core?.Toast("Not connected. Try again in a moment");
            return false;
        }
        var p = ShareWire.Text(text);
        if (!c.Send(p, deviceId))
        {
            c.Toast("Not connected. Try again in a moment");
            return false;
        }
        var link = p.String("url");
        Ui(m => m.Record(new SentItem(deviceId, link is not null ? SentKind.Link : SentKind.Text, link ?? text)));
        c.Toast(link is not null ? $"Link sent to {peer.Name}" : $"Text sent to {peer.Name}");
        return true;
    }

    // The fields of a connected, paired computer that a transfer needs.
    sealed record Peer(string Id, string Name, byte[] Certificate);

    Peer? FindPeer(string id) =>
        core?.WithDevice(id, d => d is { Paired: true, Online: true, Certificate: { } cert } ? new Peer(d.Id, d.Name, cert) : null);

    // Offers 1 file on a payload port and streams it to the computer, which
    // connects as the TLS client and must present the paired certificate.
    async Task OfferAsync(string path, long size, string name, Peer peer, Func<int, Packet> packet)
    {
        if (core is not { } c)
        {
            throw new ShareException("Flux stopped");
        }
        var transfer = new FileTransfer { DeviceId = peer.Id, Name = name, Incoming = false, Size = size, File = path };
        var cts = Begin(transfer.Id, peer.Id);
        Ui(m => m.Start(transfer));
        try
        {
            if (cts is null)
            {
                throw new ShareException($"{peer.Name} is not paired");
            }
            var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            await using (file.ConfigureAwait(false))
            {
                using var server = PayloadServer.Open(c.Tls, peer.Certificate);
                if (!c.Send(packet(server.Port), peer.Id))
                {
                    throw new ShareException("Not connected");
                }
                var stream = await server.AcceptAsync(AcceptTimeout, cts.Token).ConfigureAwait(false);
                await using (stream.ConfigureAwait(false))
                {
                    await stream.SendAsync(file, size, Progress(transfer.Id), cts.Token).ConfigureAwait(false);
                }
            }
            Ui(m => m.Finish(transfer.Id, null, TransferState.Done));
        }
        catch (Exception e) when (Expected(e))
        {
            var state = cts?.IsCancellationRequested == true ? TransferState.Canceled : TransferState.Failed;
            Ui(m => m.Finish(transfer.Id, null, state, Describe(e)));
            throw;
        }
        finally
        {
            End(transfer.Id);
        }
    }

    static long? FileSize(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists ? info.Length : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    // Errors

    // The errors that a transfer can end with. Other exceptions are bugs. An
    // ArgumentException comes from a download folder that is not a path.
    static bool Expected(Exception e) =>
        e is IOException or UnauthorizedAccessException or ShareException or TimeoutException or OperationCanceledException or
            SocketException or InvalidDataException or AuthenticationException or JsonException or ObjectDisposedException or
            ArgumentException;

    static string Describe(Exception e) => e is OperationCanceledException ? "canceled" : e.Message;

    // The log never gets file names, so it gets the message only of the
    // errors that Flux writes without names.
    static string LogText(Exception e) => e is ShareException or TimeoutException ? e.Message : e.GetType().Name;

    // UI state

    Action<long> Progress(Guid id) => bytes => Ui(m => m.Progress(id, bytes));

    // Changes the model on the UI thread, in the order of the calls.
    void Ui(Action<ShareModel> change)
    {
        var model = Model;
        core?.Host.Post(() => change(model));
    }
}
