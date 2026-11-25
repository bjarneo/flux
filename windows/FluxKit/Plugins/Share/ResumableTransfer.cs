using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace FluxKit;

// Receives the payload of 1 chunk: size bytes through the tunnel of the
// token, into the target. progress gets the bytes of this chunk.
internal delegate Task ChunkReceiver(string token, long size, Stream target, Action<long> progress, CancellationToken ct);

// Called once the transfer of a message is known to go on, with the offset
// that this device has. It returns the progress report for the bytes of the
// whole file, or it throws to stop the transfer.
internal delegate Action<long> TransferStarted(long offset);

// Receives files from the computer in chunks with flux.transfer. The partial
// file and its record stay in the folder "incoming" of the data folder, so
// that a transfer survives a lost link and a restart of the app. The
// computer sends an offer, this device answers with the offset that it has,
// and the computer sends the chunk at that offset. After the last chunk, this
// device checks the SHA-256 of the file and answers "done". The computer
// retries a failed transfer later. internal/core/resume.go of fluxd is the
// other side. ResumableTransfer.swift of the Mac app has the same rules.
internal sealed partial class ResumableTransfer(string root)
{
    // The largest chunk that the computer sends.
    public const long MaxChunk = 1 << 20;

    // The largest file of a transfer.
    public const long MaxSize = 1L << 40;

    // An offer removes the partial transfers that did not change for this time.
    public static readonly TimeSpan Keep = TimeSpan.FromDays(7);

    // The outcome of 1 offer or chunk: the answer to the computer, and the
    // saved file after the last chunk.
    public readonly record struct Outcome(string Action, long Offset, string? Saved);

    readonly Lock gate = new();
    // The transfers that run now, by folder key.
    readonly HashSet<string> active = [];
    // The running transfers that a cancel ended. Their receive marks them at its end.
    readonly HashSet<string> canceled = [];

    public string Root { get; } = root;

    // Returns the bytes that a folder can take, or null when the volume does
    // not tell. Tests replace it.
    public Func<string, long?> FreeSpace { get; init; } = SharePlugin.DiskFreeSpace;

    [GeneratedRegex(@"\A[a-f0-9]{12}\z")]
    private static partial Regex IdPattern();

    [GeneratedRegex(@"\A[a-f0-9]{64}\z")]
    private static partial Regex HashPattern();

    // Reports whether the metadata of an offer is safe: the ID and the name
    // cannot leave their folders.
    public static bool Valid(string id, string name, long size, string hash) =>
        IdPattern().IsMatch(id) && HashPattern().IsMatch(hash) && size is >= 0 and <= MaxSize &&
        name.Length > 0 && name is not ("." or "..") && !name.Any(c => c is '/' or '\\' || c < ' ');

    // The folder name of a transfer: the SHA-256 of the device ID and the
    // transfer ID, like in fluxd.
    public static string Key(string deviceId, string id) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(deviceId + ":" + id)));

    // Handles 1 offer or chunk of the device and saves the file in the folder
    // after the last chunk. An error throws, and the caller answers "error".
    public async Task<Outcome> ReceiveAsync(Packet p, string deviceId, string folder, ChunkReceiver receive, TransferStarted started, CancellationToken ct)
    {
        var id = p.String("id");
        var name = p.String("name");
        var hash = p.String("hash");
        var size = p.Long("size") ?? 0;
        if (id is null || name is null || hash is null || !Valid(id, name, size, hash))
        {
            throw new ShareException("Invalid transfer metadata");
        }
        var key = Key(deviceId, id);
        lock (gate)
        {
            if (!active.Add(key))
            {
                throw new ShareException("The transfer is busy");
            }
        }
        try
        {
            return await ReceiveLockedAsync(p, key, name, size, hash, folder, receive, started, ct).ConfigureAwait(false);
        }
        finally
        {
            bool mark;
            lock (gate)
            {
                mark = canceled.Remove(key);
            }
            if (mark)
            {
                MarkCanceled(key);
            }
            lock (gate)
            {
                active.Remove(key);
            }
        }
    }

    async Task<Outcome> ReceiveLockedAsync(Packet p, string key, string name, long size, string hash, string folder,
                                           ChunkReceiver receive, TransferStarted started, CancellationToken ct)
    {
        var action = p.String("action");
        if (action == "offer")
        {
            Prune(DateTime.UtcNow - Keep);
        }
        var dir = Path.Combine(Root, key);
        Directory.CreateDirectory(dir);
        Directory.SetLastWriteTimeUtc(dir, DateTime.UtcNow);
        var state = Path.Combine(dir, "state.json");
        var part = Path.Combine(dir, "data");
        var record = new Record(name, size, hash);
        if (File.Exists(state))
        {
            var old = Record.Read(state);
            if (old is null || old.Name != name || old.Size != size || old.Hash != hash)
            {
                throw new ShareException("Transfer metadata changed");
            }
            record = old;
        }
        else
        {
            record.Save(state);
        }
        if (record.Canceled)
        {
            throw new ShareException(CanceledText);
        }
        if (record.Path is not null)
        {
            return new Outcome("done", size, null);
        }
        var file = new FileStream(part, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 64 * 1024, FileOptions.Asynchronous);
        await using var fileScope = file.ConfigureAwait(false);
        var offset = file.Length;
        if (offset > size)
        {
            throw new ShareException("Partial file exceeds the transfer size");
        }
        var progress = started(offset);
        // The rest of the file goes to the data folder first, and the whole
        // file then goes to the download folder.
        if (action == "offer" && (!Fits(size - offset, Root) || !Fits(size, folder)))
        {
            throw new ShareException("There is not enough free space on this computer");
        }
        if (action == "chunk")
        {
            if (p.Long("offset") != offset || p.PayloadSize <= 0 || p.PayloadSize > Math.Min(MaxChunk, size - offset) ||
                p.PayloadTunnel is not { } token)
            {
                throw new ShareException("Invalid transfer chunk");
            }
            file.Seek(offset, SeekOrigin.Begin);
            var start = offset;
            await receive(token, p.PayloadSize, file, n => progress(start + n), ct).ConfigureAwait(false);
            file.Flush(true);
            offset = file.Length;
        }
        if (offset != size)
        {
            return new Outcome("offset", offset, null);
        }
        file.Seek(0, SeekOrigin.Begin);
        var sum = Convert.ToHexStringLower(await SHA256.HashDataAsync(file, ct).ConfigureAwait(false));
        if (sum != hash)
        {
            file.SetLength(0);
            throw new ShareException("The file checksum does not match");
        }
        Directory.CreateDirectory(folder);
        var target = ShareWire.SafeName(name);
        var (stagingPath, staging) = SharePlugin.CreateExclusive(folder, target + ".part");
        try
        {
            await using (staging.ConfigureAwait(false))
            {
                file.Seek(0, SeekOrigin.Begin);
                await file.CopyToAsync(staging, ct).ConfigureAwait(false);
                staging.Flush(true);
            }
            var saved = SharePlugin.MoveExclusive(stagingPath, folder, target);
            try
            {
                (record with { Path = saved }).Save(state);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                File.Delete(saved);
                throw;
            }
            await file.DisposeAsync().ConfigureAwait(false);
            TryDelete(part);
            return new Outcome("done", size, saved);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or OperationCanceledException)
        {
            TryDelete(stagingPath);
            throw;
        }
    }

    // The error text of a transfer that the user canceled.
    public const string CanceledText = "The transfer was canceled on this computer";

    // Ends a transfer for good: its record refuses each later offer, and its
    // partial file goes. A receive that runs marks the record at its end.
    public void Cancel(string key)
    {
        lock (gate)
        {
            if (active.Contains(key))
            {
                canceled.Add(key);
                return;
            }
            active.Add(key);
        }
        try
        {
            MarkCanceled(key);
        }
        finally
        {
            lock (gate)
            {
                active.Remove(key);
            }
        }
    }

    void MarkCanceled(string key)
    {
        var dir = Path.Combine(Root, key);
        var state = Path.Combine(dir, "state.json");
        try
        {
            // A file that arrived stays done.
            if (Record.Read(state) is { } record && record.Path is null)
            {
                (record with { Canceled = true }).Save(state);
            }
            TryDelete(Path.Combine(dir, "data"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            FluxLog.Error("share", $"cannot cancel a resumable transfer: {e.GetType().Name}");
        }
    }

    bool Fits(long size, string folder) => FreeSpace(folder) is not { } free || SharePlugin.Fits(size, free);

    // Removes the transfer folders that did not change since the time. A
    // transfer that runs stays.
    internal void Prune(DateTime before)
    {
        if (!Directory.Exists(Root))
        {
            return;
        }
        foreach (var dir in Directory.EnumerateDirectories(Root))
        {
            var name = Path.GetFileName(dir);
            if (!HashPattern().IsMatch(name))
            {
                continue;
            }
            lock (gate)
            {
                if (active.Contains(name))
                {
                    continue;
                }
            }
            try
            {
                if (Directory.GetLastWriteTimeUtc(dir) < before)
                {
                    Directory.Delete(dir, true);
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                FluxLog.Error("share", $"cannot remove an old partial transfer: {e.GetType().Name}");
            }
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

    // The record of 1 transfer in state.json. Path is the saved file after
    // the last chunk.
    internal sealed record Record(string Name, long Size, string Hash, string? Path = null, bool Canceled = false)
    {
        public static Record? Read(string path)
        {
            try
            {
                if (JsonNode.Parse(File.ReadAllBytes(path)) is not JsonObject o ||
                    Json.String(o["name"]) is not { } name || Json.Long(o["size"]) is not { } size || Json.String(o["hash"]) is not { } hash)
                {
                    return null;
                }
                return new Record(name, size, hash, Json.String(o["path"]), Json.Bool(o["canceled"]) ?? false);
            }
            catch (Exception e) when (e is JsonException or FileNotFoundException or DirectoryNotFoundException)
            {
                return null;
            }
        }

        public void Save(string path)
        {
            var o = new JsonObject { ["name"] = Name, ["size"] = Size, ["hash"] = Hash };
            if (Path is not null)
            {
                o["path"] = Path;
            }
            if (Canceled)
            {
                o["canceled"] = true;
            }
            FileStore.WriteAtomic(path, JsonSerializer.SerializeToUtf8Bytes(o));
        }
    }
}
