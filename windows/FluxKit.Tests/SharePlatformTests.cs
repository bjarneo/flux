using FluxKit;

namespace FluxKit.Tests;

// SharePlatformTests.swift of the Mac app: received files go to the
// Downloads folder of the host.
public class SharePlatformTests
{
    [Fact]
    public void DownloadsIsTheFolderOfTheUser()
    {
        var downloads = new FluxHost().Downloads();
        Assert.Equal("Downloads", Path.GetFileName(downloads));
        Assert.Equal(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Path.GetDirectoryName(downloads));
    }

    [Fact]
    public async Task ShareSavesInDownloads()
    {
        var share = new SharePlugin();
        using var t = new TestCore(new LanConfig { LoopbackOnly = true }, [share]);
        Assert.Equal(t.Core.Host.Downloads(), share.DownloadFolder);
        Assert.Equal(SharePlugin.DownloadsName, share.PlaceName(share.DownloadFolder));
        Assert.Equal(SharePlugin.DownloadsName, share.PlaceName(share.DownloadFolder + Path.DirectorySeparatorChar));
        await Wait.UntilAsync(() => share.Model.DownloadFolder == t.Core.Host.Downloads(), "the folder in the model");
    }

    [Fact]
    public async Task TheUserCanChooseAnotherFolder()
    {
        var share = new SharePlugin();
        using var t = new TestCore(new LanConfig { LoopbackOnly = true }, [share]);
        var folder = Path.Combine(t.Data, "Received");
        share.SetDownloadFolder(folder);
        Assert.Equal(folder, share.DownloadFolder);
        Assert.Equal("Received", share.PlaceName(folder));
        await Wait.UntilAsync(() => share.Model.DownloadFolder == folder, "the folder in the model");
        // The choice stays after a restart.
        Assert.Equal(folder, new FluxSettings(t.Core.Paths.File("settings.json")).String(SharePlugin.FolderKey));
    }

    [Fact]
    public void TheCapabilitiesMatchTheMac()
    {
        var share = new SharePlugin();
        Assert.Equal([PacketType.Share, PacketType.ShareUpdate, PacketType.Transfer], share.Incoming);
        Assert.Equal([PacketType.Share, PacketType.ShareUpdate, PacketType.Tunnel, PacketType.Transfer], share.Outgoing);
        Assert.DoesNotContain(PacketType.Transfer, new SharePlugin { Resumable = false }.Incoming);
    }
}
