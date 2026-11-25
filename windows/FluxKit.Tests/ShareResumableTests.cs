using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// ResumableTransferTests.swift of the Mac app, and the offer and chunk rules
// of internal/core/resume.go with a fake tunnel.
public class ShareResumableTests : IDisposable
{
    const string Device = "computer1";
    const string Id = "aabbccddeeff";

    readonly string dir = CoreTests.TempDir();
    string Root => Path.Combine(dir, "incoming");
    string Downloads => Path.Combine(dir, "Downloads");

    public void Dispose() => Directory.Delete(dir, true);

    static Packet Offer(string name, long size, string hash, string id = Id) =>
        new(PacketType.Transfer, new JsonObject { ["action"] = "offer", ["id"] = id, ["name"] = name, ["size"] = size, ["hash"] = hash, ["offset"] = 0 });

    // A chunk at the offset. The tunnel token carries the offset, so that the
    // fake tunnel knows which bytes to give.
    static Packet Chunk(string name, long size, string hash, long offset, long length, string? token = "") =>
        new(PacketType.Transfer, new JsonObject { ["action"] = "chunk", ["id"] = Id, ["name"] = name, ["size"] = size, ["hash"] = hash, ["offset"] = offset })
        {
            PayloadSize = length,
            PayloadTunnel = token is null ? null : offset.ToString(System.Globalization.CultureInfo.InvariantCulture),
        };

    // A tunnel that gives the bytes of the file at the offset in the token.
    static ChunkReceiver Tunnel(byte[] data) => async (token, size, target, progress, ct) =>
    {
        var offset = int.Parse(token, System.Globalization.CultureInfo.InvariantCulture);
        await target.WriteAsync(data.AsMemory(offset, (int)size), ct);
        progress(size);
    };

    static TransferStarted Started(List<long>? offsets = null, List<long>? progress = null) => offset =>
    {
        offsets?.Add(offset);
        return n => progress?.Add(n);
    };

    // Sends the whole file in chunks like fluxd and returns the saved path.
    async Task<string> SendAsync(ResumableTransfer r, string name, byte[] data)
    {
        var hash = ShareTesting.Sha256(data);
        var outcome = await r.ReceiveAsync(Offer(name, data.Length, hash), Device, Downloads, Tunnel(data), Started(), default);
        while (outcome.Action == "offset")
        {
            var length = Math.Min(ResumableTransfer.MaxChunk, data.Length - outcome.Offset);
            outcome = await r.ReceiveAsync(Chunk(name, data.Length, hash, outcome.Offset, length), Device, Downloads, Tunnel(data), Started(), default);
        }
        Assert.Equal("done", outcome.Action);
        Assert.Equal(data.Length, outcome.Offset);
        return outcome.Saved!;
    }

    [Fact]
    public void MetadataCannotEscapeItsFolder()
    {
        var hash = new string('0', 64);
        Assert.True(ResumableTransfer.Valid(Id, "empty.txt", 0, hash));
        foreach (var name in new[] { "../file", "folder/file", "folder\\file", ".", "..", "", "a\nb" })
        {
            Assert.False(ResumableTransfer.Valid(Id, name, 1, hash), name);
        }
        Assert.False(ResumableTransfer.Valid("../bad", "file", 1, hash));
        Assert.False(ResumableTransfer.Valid("AABBCCDDEEFF", "file", 1, hash));
        Assert.False(ResumableTransfer.Valid(Id, "file", -1, hash));
        Assert.False(ResumableTransfer.Valid(Id, "file", ResumableTransfer.MaxSize + 1, hash));
        Assert.False(ResumableTransfer.Valid(Id, "file", 1, hash + "\n"));
    }

    [Fact]
    public async Task ChunksMakeTheFile()
    {
        var r = new ResumableTransfer(Root) { FreeSpace = _ => null };
        var data = ShareTesting.RandomBytes((int)(2.5 * ResumableTransfer.MaxChunk));
        var saved = await SendAsync(r, "report.pdf", data);
        Assert.Equal(Path.Combine(Downloads, "report.pdf"), saved);
        Assert.Equal(data, await File.ReadAllBytesAsync(saved));
        // The partial file goes, and the record keeps the saved path.
        var folder = Path.Combine(Root, ResumableTransfer.Key(Device, Id));
        Assert.False(File.Exists(Path.Combine(folder, "data")));
        Assert.Equal(saved, ResumableTransfer.Record.Read(Path.Combine(folder, "state.json"))!.Path);
        // A second offer of the same transfer gets done, without a new file.
        var again = await r.ReceiveAsync(Offer("report.pdf", data.Length, ShareTesting.Sha256(data)), Device, Downloads, Tunnel(data), Started(), default);
        Assert.Equal(new ResumableTransfer.Outcome("done", data.Length, null), again);
        Assert.Single(Directory.GetFiles(Downloads));
    }

    [Fact]
    public async Task AnEmptyFileArrivesWithTheOffer()
    {
        var r = new ResumableTransfer(Root) { FreeSpace = _ => null };
        var saved = await SendAsync(r, "empty.txt", []);
        Assert.Empty(await File.ReadAllBytesAsync(saved));
    }

    [Fact]
    public async Task ATransferResumesAfterARestart()
    {
        var data = ShareTesting.RandomBytes(3 * (int)ResumableTransfer.MaxChunk / 2);
        var hash = ShareTesting.Sha256(data);
        var offsets = new List<long>();
        var progress = new List<long>();
        var first = new ResumableTransfer(Root) { FreeSpace = _ => null };
        var o = await first.ReceiveAsync(Offer("a.bin", data.Length, hash), Device, Downloads, Tunnel(data), Started(offsets), default);
        Assert.Equal(new ResumableTransfer.Outcome("offset", 0, null), o);
        o = await first.ReceiveAsync(Chunk("a.bin", data.Length, hash, 0, ResumableTransfer.MaxChunk), Device, Downloads, Tunnel(data), Started(offsets, progress), default);
        Assert.Equal(ResumableTransfer.MaxChunk, o.Offset);
        Assert.Equal(ResumableTransfer.MaxChunk, progress[^1]);

        // A new app run takes the offset from the partial file.
        var second = new ResumableTransfer(Root) { FreeSpace = _ => null };
        o = await second.ReceiveAsync(Offer("a.bin", data.Length, hash), Device, Downloads, Tunnel(data), Started(offsets, progress), default);
        Assert.Equal(new ResumableTransfer.Outcome("offset", ResumableTransfer.MaxChunk, null), o);
        o = await second.ReceiveAsync(Chunk("a.bin", data.Length, hash, o.Offset, data.Length - o.Offset), Device, Downloads, Tunnel(data), Started(offsets, progress), default);
        Assert.Equal("done", o.Action);
        Assert.Equal(data, await File.ReadAllBytesAsync(o.Saved!));
        Assert.Equal([0, 0, ResumableTransfer.MaxChunk, ResumableTransfer.MaxChunk], offsets);
        // The progress counts the bytes of the whole file.
        Assert.Equal(data.Length, progress[^1]);
    }

    [Fact]
    public async Task ABadChunkIsRefused()
    {
        var r = new ResumableTransfer(Root) { FreeSpace = _ => null };
        var data = ShareTesting.RandomBytes(3 * (int)ResumableTransfer.MaxChunk);
        var hash = ShareTesting.Sha256(data);
        await r.ReceiveAsync(Offer("a.bin", data.Length, hash), Device, Downloads, Tunnel(data), Started(), default);
        var bad = new[]
        {
            Chunk("a.bin", data.Length, hash, 5, 10),
            Chunk("a.bin", data.Length, hash, 0, ResumableTransfer.MaxChunk + 1),
            Chunk("a.bin", data.Length, hash, 0, 0),
            Chunk("a.bin", data.Length, hash, 0, 10, token: null),
        };
        foreach (var p in bad)
        {
            var e = await Assert.ThrowsAsync<ShareException>(() => r.ReceiveAsync(p, Device, Downloads, Tunnel(data), Started(), default));
            Assert.Equal("Invalid transfer chunk", e.Message);
        }
        // A chunk on a payload port of the computer cannot come.
        var noTunnel = new Packet(PacketType.Transfer, new JsonObject { ["action"] = "chunk", ["id"] = Id, ["name"] = "a.bin", ["size"] = data.Length, ["hash"] = hash, ["offset"] = 0 })
        {
            PayloadSize = 10,
            PayloadPort = 12070,
        };
        await Assert.ThrowsAsync<ShareException>(() => r.ReceiveAsync(noTunnel, Device, Downloads, Tunnel(data), Started(), default));
        // Changed metadata does not mix 2 files.
        var changed = await Assert.ThrowsAsync<ShareException>(() =>
            r.ReceiveAsync(Offer("a.bin", data.Length - 1, hash), Device, Downloads, Tunnel(data), Started(), default));
        Assert.Equal("Transfer metadata changed", changed.Message);
        await Assert.ThrowsAsync<ShareException>(() =>
            r.ReceiveAsync(Offer("../a.bin", data.Length, hash), Device, Downloads, Tunnel(data), Started(), default));
    }

    [Fact]
    public async Task AWrongChecksumStartsTheFileAgain()
    {
        var r = new ResumableTransfer(Root) { FreeSpace = _ => null };
        var data = ShareTesting.RandomBytes(1000);
        var hash = ShareTesting.Sha256([1, 2, 3]);
        await r.ReceiveAsync(Offer("a.bin", data.Length, hash), Device, Downloads, Tunnel(data), Started(), default);
        var e = await Assert.ThrowsAsync<ShareException>(() =>
            r.ReceiveAsync(Chunk("a.bin", data.Length, hash, 0, data.Length), Device, Downloads, Tunnel(data), Started(), default));
        Assert.Equal("The file checksum does not match", e.Message);
        var o = await r.ReceiveAsync(Offer("a.bin", data.Length, hash), Device, Downloads, Tunnel(data), Started(), default);
        Assert.Equal(0, o.Offset);
        Assert.False(Directory.Exists(Downloads) && Directory.EnumerateFileSystemEntries(Downloads).Any());
    }

    [Fact]
    public async Task TheSavedNameIsSafeAndNew()
    {
        var r = new ResumableTransfer(Root) { FreeSpace = _ => null };
        Directory.CreateDirectory(Downloads);
        await File.WriteAllTextAsync(Path.Combine(Downloads, "notes.txt"), "old");
        var notes = await SendAsync(r, "notes.txt", [1]);
        Assert.Equal(Path.Combine(Downloads, "notes (2).txt"), notes);
        Assert.Equal("old", await File.ReadAllTextAsync(Path.Combine(Downloads, "notes.txt")));
        var r2 = new ResumableTransfer(Path.Combine(dir, "other")) { FreeSpace = _ => null };
        Assert.Equal(Path.Combine(Downloads, "_CON.txt"), await SendAsync(r2, "CON.txt", [2]));
        var r3 = new ResumableTransfer(Path.Combine(dir, "third")) { FreeSpace = _ => null };
        Assert.Equal(Path.Combine(Downloads, "a_b.txt"), await SendAsync(r3, "a:b.txt", [3]));
    }

    [Fact]
    public async Task AFileThatDoesNotFitIsRefused()
    {
        var r = new ResumableTransfer(Root) { FreeSpace = _ => (256L << 20) + 10 };
        var hash = ShareTesting.Sha256(new byte[11]);
        var e = await Assert.ThrowsAsync<ShareException>(() =>
            r.ReceiveAsync(Offer("big.bin", 11, hash), Device, Downloads, Tunnel(new byte[11]), Started(), default));
        Assert.Equal("There is not enough free space on this computer", e.Message);
        var fits = await r.ReceiveAsync(Offer("big.bin", 10, ShareTesting.Sha256(new byte[10]), "aabbccddee00"), Device, Downloads, Tunnel(new byte[10]), Started(), default);
        Assert.Equal("offset", fits.Action);
    }

    [Fact]
    public async Task ACanceledTransferStaysRefused()
    {
        var r = new ResumableTransfer(Root) { FreeSpace = _ => null };
        var data = ShareTesting.RandomBytes(2 * (int)ResumableTransfer.MaxChunk);
        var hash = ShareTesting.Sha256(data);
        await r.ReceiveAsync(Offer("a.bin", data.Length, hash), Device, Downloads, Tunnel(data), Started(), default);
        await r.ReceiveAsync(Chunk("a.bin", data.Length, hash, 0, ResumableTransfer.MaxChunk), Device, Downloads, Tunnel(data), Started(), default);
        var key = ResumableTransfer.Key(Device, Id);
        r.Cancel(key);
        Assert.False(File.Exists(Path.Combine(Root, key, "data")));
        var started = new List<long>();
        var e = await Assert.ThrowsAsync<ShareException>(() =>
            new ResumableTransfer(Root).ReceiveAsync(Offer("a.bin", data.Length, hash), Device, Downloads, Tunnel(data), Started(started), default));
        Assert.Equal(ResumableTransfer.CanceledText, e.Message);
        Assert.Empty(started);
    }

    [Fact]
    public async Task ACancelDuringAChunkMarksTheTransfer()
    {
        var r = new ResumableTransfer(Root) { FreeSpace = _ => null };
        var data = ShareTesting.RandomBytes(100);
        var hash = ShareTesting.Sha256(data);
        await r.ReceiveAsync(Offer("a.bin", data.Length, hash), Device, Downloads, Tunnel(data), Started(), default);
        var entered = new TaskCompletionSource();
        using var cts = new CancellationTokenSource();
        var running = r.ReceiveAsync(Chunk("a.bin", data.Length, hash, 0, data.Length), Device, Downloads, async (_, _, _, _, ct) =>
        {
            entered.SetResult();
            await Task.Delay(Timeout.Infinite, ct);
        }, Started(), cts.Token);
        await entered.Task;
        // A second message of the same transfer waits for none.
        var busy = await Assert.ThrowsAsync<ShareException>(() =>
            r.ReceiveAsync(Offer("a.bin", data.Length, hash), Device, Downloads, Tunnel(data), Started(), default));
        Assert.Equal("The transfer is busy", busy.Message);
        r.Cancel(ResumableTransfer.Key(Device, Id));
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => running);
        var e = await Assert.ThrowsAsync<ShareException>(() =>
            r.ReceiveAsync(Offer("a.bin", data.Length, hash), Device, Downloads, Tunnel(data), Started(), default));
        Assert.Equal(ResumableTransfer.CanceledText, e.Message);
    }

    [Fact]
    public async Task AnOfferRemovesOldPartialTransfers()
    {
        var r = new ResumableTransfer(Root) { FreeSpace = _ => null };
        var old = Path.Combine(Root, new string('a', 64));
        var recent = Path.Combine(Root, new string('b', 64));
        var other = Path.Combine(Root, "keep-me");
        foreach (var d in new[] { old, recent, other })
        {
            Directory.CreateDirectory(d);
            await File.WriteAllTextAsync(Path.Combine(d, "data"), "x");
        }
        Directory.SetLastWriteTimeUtc(old, DateTime.UtcNow - ResumableTransfer.Keep - TimeSpan.FromHours(1));
        Directory.SetLastWriteTimeUtc(other, DateTime.UtcNow - TimeSpan.FromDays(30));
        await r.ReceiveAsync(Offer("a.bin", 1, ShareTesting.Sha256([9])), Device, Downloads, Tunnel([9]), Started(), default);
        Assert.False(Directory.Exists(old));
        Assert.True(Directory.Exists(recent));
        Assert.True(Directory.Exists(other));
    }

    [Fact]
    public void TheKeyMatchesFluxd()
    {
        // The SHA-256 of "computer1:aabbccddeeff" in hex, as fluxd names the folder.
        Assert.Equal(ShareTesting.Sha256(System.Text.Encoding.UTF8.GetBytes("computer1:aabbccddeeff")), ResumableTransfer.Key(Device, Id));
        Assert.Matches("^[a-f0-9]{64}$", ResumableTransfer.Key(Device, Id));
    }
}
