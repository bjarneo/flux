using System.Text.Json;
using System.Text.Json.Nodes;

namespace FluxKit;

// An enrolled approval key, as the UI shows it.
public sealed record ApproveKeyInfo(
    string ComputerId,
    string Host,
    string User,
    // The public key as base64 SubjectPublicKeyInfo DER.
    string PublicKey,
    DateTimeOffset Enrolled)
{
    // The key code that the terminal asked for at enrollment.
    public string Code => ApproveMessage.Fingerprint(Convert.FromBase64String(PublicKey));
}

// The key of 1 computer: the name of the key in the platform and its public
// key in DER.
internal sealed record ApproveKeyRecord(string Name, byte[] PublicKey, string Host, string User, long Enrolled);

// The approval keys of this computer, 1 for each paired computer.
//
// The platform keeps each private key in its secure hardware, see
// IApproveSigner. This store keeps the name of the key in the platform and
// the public key in <data>/approve/<computer ID>.json. The file also holds
// the host, the user, and the time of the enrollment. Only the user can read
// the file.
//
// An enrollment replaces the key only after the computer got the new key:
// the new key waits in <computer ID>.pending until Commit. A Windows Hello
// key stays in the platform until something deletes it, so each replace,
// discard, and delete also deletes the key in the platform. ApproveKeys.swift of the Mac
// app has the same rules. docs/approve.md is the design.
internal sealed class ApproveKeys(string folder, Action<string> deleteKey)
{
    public string Folder { get; } = folder;

    string? CurrentPath(string computerId) =>
        Identity.ValidDeviceId(computerId) ? Path.Combine(Folder, computerId + ".json") : null;

    // The new key of an enrollment that did not end.
    string? StagedPath(string computerId) =>
        Identity.ValidDeviceId(computerId) ? Path.Combine(Folder, computerId + ".pending") : null;

    static ApproveKeyRecord? Read(string? path)
    {
        if (path is null || !File.Exists(path))
        {
            return null;
        }
        try
        {
            if (JsonNode.Parse(File.ReadAllBytes(path)) is not JsonObject o ||
                Json.String(o["key"]) is not { Length: > 0 } name ||
                Json.String(o["publicKey"]) is not { Length: > 0 } publicKey ||
                Json.Long(o["enrolled"]) is not { } enrolled)
            {
                return null;
            }
            return new ApproveKeyRecord(name, Convert.FromBase64String(publicKey), Json.String(o["host"]) ?? "", Json.String(o["user"]) ?? "", enrolled);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or FormatException)
        {
            FluxLog.Error("approve", $"cannot read the approval key in {Path.GetFileName(path)}: {e.Message}");
            return null;
        }
    }

    // The current key of the computer, or null.
    public ApproveKeyRecord? Current(string computerId) => Read(CurrentPath(computerId));

    public bool Has(string computerId) => Current(computerId) is not null;

    // Every enrolled key, by computer ID in order.
    public ValueList<ApproveKeyInfo> All()
    {
        string[] files;
        try
        {
            files = Directory.Exists(Folder) ? Directory.GetFiles(Folder, "*.json") : [];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            FluxLog.Error("approve", $"cannot list the approval keys: {e.Message}");
            files = [];
        }
        var keys = new List<ApproveKeyInfo>();
        foreach (var file in files.Order(StringComparer.Ordinal))
        {
            var id = Path.GetFileNameWithoutExtension(file);
            if (Current(id) is { } r)
            {
                keys.Add(new ApproveKeyInfo(id, r.Host, r.User, Convert.ToBase64String(r.PublicKey), DateTimeOffset.FromUnixTimeSeconds(r.Enrolled)));
            }
        }
        return ValueList.From(keys);
    }

    // Deletes the key of the computer, and the new key of an enrollment that
    // did not end, in this store and in the platform.
    public void Delete(string computerId)
    {
        foreach (var path in new[] { CurrentPath(computerId), StagedPath(computerId) })
        {
            Remove(path);
        }
    }

    // Stores a new key for the computer next to its current key. The current
    // key stays until Commit, so that an enrollment that does not reach the
    // computer keeps the approvals working. The caller deletes the new key in
    // the platform when Stage throws.
    public void Stage(string keyName, byte[] publicKey, string computerId, string host, string user)
    {
        var path = StagedPath(computerId) ?? throw new IOException("The computer ID is not valid");
        // A new key that an earlier enrollment left, for example after a
        // crash, goes first, also in the platform.
        if (Read(path) is { } old && old.Name != keyName)
        {
            Remove(path);
        }
        var o = new JsonObject
        {
            ["key"] = keyName,
            ["publicKey"] = Convert.ToBase64String(publicKey),
            ["host"] = host,
            ["user"] = user,
            ["enrolled"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
        };
        FileStore.WriteAtomic(path, JsonSerializer.SerializeToUtf8Bytes(o), secret: true);
    }

    // Makes the staged key of the computer its current key. It replaces the
    // old key and deletes the old key in the platform. Call it after the
    // computer got the new key. It throws an IOException when no key waits.
    public void Commit(string computerId)
    {
        if (StagedPath(computerId) is not { } staged || CurrentPath(computerId) is not { } current)
        {
            throw new IOException("The computer ID is not valid");
        }
        var next = Read(staged) ?? throw new IOException("No new key waits for the computer");
        var old = Read(current);
        File.Move(staged, current, overwrite: true);
        if (old is not null && old.Name != next.Name)
        {
            DeleteInPlatform(old.Name);
        }
    }

    // Deletes the staged key of an enrollment that did not end, also in the
    // platform. The current key stays.
    public void Discard(string computerId) => Remove(StagedPath(computerId));

    // Deletes the new keys that enrollments left, for example after a crash.
    // An enrollment stages and commits its key in 1 step on the UI thread, so
    // each staged key at the start is a leftover.
    public void DiscardLeftovers()
    {
        string[] files;
        try
        {
            files = Directory.Exists(Folder) ? Directory.GetFiles(Folder, "*.pending") : [];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            FluxLog.Error("approve", $"cannot list the approval keys: {e.Message}");
            return;
        }
        foreach (var file in files)
        {
            Discard(Path.GetFileNameWithoutExtension(file));
        }
    }

    // Deletes the file first, so that Flux does not use the key again, and
    // then the key in the platform.
    void Remove(string? path)
    {
        var r = Read(path);
        if (path is null || !File.Exists(path))
        {
            return;
        }
        try
        {
            File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            FluxLog.Error("approve", $"cannot delete the approval key in {Path.GetFileName(path)}: {e.Message}");
            return;
        }
        if (r is not null)
        {
            DeleteInPlatform(r.Name);
        }
    }

    void DeleteInPlatform(string name)
    {
        try
        {
            deleteKey(name);
        }
        catch (ApproveKeyException e)
        {
            FluxLog.Error("approve", $"cannot delete an approval key in the platform: {e.Message}");
        }
    }
}
