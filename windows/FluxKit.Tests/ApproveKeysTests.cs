using FluxKit;

namespace FluxKit.Tests;

// ApproveKeysBackupTests.swift of the Mac app. The backup rules of the iPhone
// do not apply to Windows. Windows adds the rule that each key that the store
// drops goes in the platform too, because a Windows Hello key stays until
// something deletes it.
public sealed class ApproveKeysTests : IDisposable
{
    const string Computer = "computer_0123456789abcdef0123456789ab";

    readonly string root = CoreTests.TempDir();
    readonly List<string> deleted = [];
    readonly ApproveKeys keys;

    public ApproveKeysTests() => keys = new ApproveKeys(Path.Combine(root, "approve"), deleted.Add);

    public void Dispose()
    {
        try
        {
            Directory.Delete(root, true);
        }
        catch (IOException)
        {
        }
    }

    // An enrollment keeps the old key until the new key reached the
    // computer, as in the Android and Mac apps.
    [Fact]
    public void TheOldKeyStaysUntilTheCommit()
    {
        keys.Stage("k1", [10], Computer, "omarchy", "me");
        Assert.False(keys.Has(Computer)); // a staged key is not a key yet
        keys.Commit(Computer);
        Assert.Equal([10], keys.Current(Computer)?.PublicKey);
        Assert.Empty(deleted);

        keys.Stage("k2", [20], Computer, "omarchy", "me");
        Assert.Equal([10], keys.Current(Computer)?.PublicKey); // the old key works until the computer got the new key
        keys.Discard(Computer);
        Assert.Equal([10], keys.Current(Computer)?.PublicKey); // a failed enrollment keeps the old key
        Assert.Equal(["k2"], deleted); // the new key goes in the platform too
        Assert.Throws<IOException>(() => keys.Commit(Computer)); // nothing waits after a discard

        keys.Stage("k3", [30], Computer, "omarchy", "me");
        keys.Commit(Computer);
        Assert.Equal("k3", keys.Current(Computer)?.Name);
        Assert.Equal(["k2", "k1"], deleted); // the commit deletes the old key in the platform
        Assert.Single(keys.All());

        keys.Stage("k4", [40], Computer, "omarchy", "me");
        keys.Delete(Computer);
        Assert.False(keys.Has(Computer));
        Assert.Equal(["k2", "k1", "k3", "k4"], deleted); // a delete removes both keys in the platform
        Assert.Throws<IOException>(() => keys.Commit(Computer)); // a delete also removes the staged key
    }

    [Fact]
    public void AllListsTheKeysWithTheirCodes()
    {
        var other = "computer_ffffffffffffffffffffffffffff";
        keys.Stage("k1", "test-key"u8.ToArray(), Computer, "omarchy", "alice");
        keys.Commit(Computer);
        keys.Stage("k2", [2], other, "laptop", "bob");
        keys.Commit(other);
        keys.Stage("k3", [3], other, "laptop", "bob"); // a staged key is not listed
        var all = keys.All();
        Assert.Equal([Computer, other], all.Select(k => k.ComputerId));
        Assert.Equal("62AF 8704 764F AF8E", all[0].Code);
        Assert.Equal(("omarchy", "alice"), (all[0].Host, all[0].User));
        Assert.True(Math.Abs((DateTimeOffset.UtcNow - all[0].Enrolled).TotalMinutes) < 1);
    }

    // A new key that an earlier enrollment left goes before the next one,
    // and at the start of the plugin.
    [Fact]
    public void LeftoverKeysGo()
    {
        keys.Stage("old", [1], Computer, "omarchy", "me");
        keys.Stage("new", [2], Computer, "omarchy", "me");
        Assert.Equal(["old"], deleted);
        keys.DiscardLeftovers();
        Assert.Equal(["old", "new"], deleted);
        Assert.Empty(Directory.GetFiles(keys.Folder, "*.pending"));
    }

    [Fact]
    public void OnlyTheUserReadsTheKeys()
    {
        keys.Stage("k1", [1], Computer, "omarchy", "me");
        keys.Commit(Computer);
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(Path.Combine(keys.Folder, Computer + ".json")));
        }
    }

    // A computer ID that is not valid cannot name a path.
    [Fact]
    public void BadComputerIdsHaveNoKey()
    {
        Assert.Throws<IOException>(() => keys.Stage("k1", [1], "../../evil_0123456789abcdef0123456789", "omarchy", "me"));
        Assert.False(keys.Has("../x"));
        keys.Delete("../x");
        Assert.Empty(deleted);
    }

    // A file that does not read is no key, and the store goes on.
    [Fact]
    public void ADamagedFileIsNoKey()
    {
        Directory.CreateDirectory(keys.Folder);
        File.WriteAllText(Path.Combine(keys.Folder, Computer + ".json"), "{not json");
        Assert.False(keys.Has(Computer));
        Assert.Empty(keys.All());
        Assert.Empty(new ApproveKeys(Path.Combine(root, "missing"), deleted.Add).All()); // a missing folder has no keys
    }
}
