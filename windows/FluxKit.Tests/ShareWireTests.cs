using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// ShareWireTests.swift of the Mac app, with the Windows rules for file names.
public class ShareWireTests
{
    [Fact]
    public void TextThatIsOneUrlGoesAsALink()
    {
        var link = ShareWire.Text("  https://omarchy.org/docs?a=1 \n");
        Assert.Equal("https://omarchy.org/docs?a=1", link.String("url"));
        Assert.False(link.Has("text"));
        Assert.Equal("HTTP://Omarchy.org", ShareWire.Text("HTTP://Omarchy.org").String("url"));
    }

    // Only http and https with a host are links, like in fluxd and Flux for
    // Android. Another scheme can start an app, so it goes as text.
    [Fact]
    public void OnlyWebLinksAreLinks()
    {
        foreach (var link in new[] { "https://omarchy.org", "http://192.168.1.5:8080/a?b=c", "HTTPS://X.ORG/" })
        {
            Assert.True(ShareWire.IsUrl(link), link);
            Assert.NotNull(ShareWire.WebUrl(link));
        }
        foreach (var text in new[]
                 {
                     "file:///etc/passwd", "ftp://omarchy.org", "ssh+git://host/repo", "smb://host/share", "javascript:alert(1)",
                     "https://", "http:///path", "/home/me/a.txt", "~/a.txt", "omarchy.org", "https://a.org b", "https://a.org\n",
                     @"C:\Users\me\a.txt", @"\\server\share",
                 })
        {
            Assert.False(ShareWire.IsUrl(text), text);
        }
        foreach (var text in new[] { "file:///etc/passwd", "ftp://omarchy.org", "https://", "omarchy.org", "https://a.org b" })
        {
            Assert.Equal(text, ShareWire.Text(text).String("text"));
        }
    }

    [Fact]
    public void WebUrlKeepsTheTextAsItCame()
    {
        Assert.Equal("HTTP://Omarchy.org", ShareWire.WebUrl("HTTP://Omarchy.org")!.OriginalString);
    }

    [Fact]
    public void OtherTextGoesAsText()
    {
        foreach (var text in new[] { "see https://omarchy.org", "https://a.org https://b.org", "omarchy.org", "mailto:me@omarchy.org", "1http://x" })
        {
            var p = ShareWire.Text(text);
            Assert.Equal(text, p.String("text"));
            Assert.False(p.Has("url"), text);
        }
    }

    [Fact]
    public void FileFieldsMatchTheAndroidApp()
    {
        var p = Packet.Parse(ShareWire.File("a b.jpg", 2, 300, 100, 12071).Serialize())!;
        Assert.Equal(PacketType.Share, p.Type);
        Assert.Equal(["filename", "numberOfFiles", "open", "totalPayloadSize"], p.Body.Select(kv => kv.Key).Order());
        Assert.Equal("a b.jpg", p.String("filename"));
        Assert.False(p.Bool("open"));
        Assert.Equal(2, p.Int("numberOfFiles"));
        Assert.Equal(300, p.Long("totalPayloadSize"));
        Assert.Equal(100, p.PayloadSize);
        Assert.Equal(12071, p.PayloadPort);

        var update = Packet.Parse(ShareWire.Update(2, 300).Serialize())!;
        Assert.Equal(PacketType.ShareUpdate, update.Type);
        Assert.Equal(2, update.Int("numberOfFiles"));
        Assert.Equal(300, update.Long("totalPayloadSize"));
        Assert.False(update.HasPayload);
    }

    [Fact]
    public void CaptureCarriesTheExtraFields()
    {
        var p = Packet.Parse(ShareWire.Capture("shot.png", new JsonObject { ["photo"] = true, ["screenshot"] = true }, 5, 12070).Serialize())!;
        Assert.Equal("shot.png", p.String("filename"));
        Assert.False(p.Bool("open"));
        Assert.True(p.Bool("photo"));
        Assert.True(p.Bool("screenshot"));
        Assert.Equal(5, p.PayloadSize);
        Assert.Equal(12070, p.PayloadPort);

        var scan = ShareWire.Scan("line 1\nline 2");
        Assert.Equal("line 1\nline 2", scan.String("text"));
        Assert.True(scan.Bool("scan"));
    }

    [Fact]
    public void RequestPrefersTextThenUrlThenFile()
    {
        var both = new Packet(PacketType.Share, new JsonObject { ["text"] = "hi", ["url"] = "https://x.org", ["filename"] = "a" }) { PayloadSize = 3, PayloadPort = 12070 };
        Assert.Equal(new SharedText("hi"), ShareRequest.Parse(both));
        var url = new Packet(PacketType.Share, new JsonObject { ["url"] = "https://x.org", ["filename"] = "a" }) { PayloadSize = 3, PayloadPort = 12070 };
        Assert.Equal(new SharedLink(new Uri("https://x.org")), ShareRequest.Parse(url));
        var file = Packet.Parse("""{"id":1,"type":"flux.share.request","body":{"filename":"r.txt","open":false,"lastModified":1700000000123},"payloadSize":3,"payloadTransferInfo":{"tunnel":"t1"}}""")!;
        Assert.Equal(new SharedFile("r.txt", 1_700_000_000_123), ShareRequest.Parse(file));
        Assert.Null(ShareRequest.Parse(new Packet(PacketType.Share, new JsonObject { ["filename"] = "a" })));
    }

    [Fact]
    public void RequestNamesAFileWithoutName()
    {
        var p = new Packet(PacketType.Share) { PayloadSize = 3, PayloadPort = 12070 };
        Assert.Equal(new SharedFile("file-42", null), ShareRequest.Parse(p, now: 42));
    }

    // A computer cannot make this device open a file or a link by itself.
    [Fact]
    public void RequestIgnoresTheOpenFlagAndOtherSchemes()
    {
        var file = Packet.Parse("""{"id":1,"type":"flux.share.request","body":{"filename":"setup.exe","open":true},"payloadSize":3,"payloadTransferInfo":{"tunnel":"t1"}}""")!;
        Assert.Equal(new SharedFile("setup.exe", null), ShareRequest.Parse(file));
        foreach (var link in new[] { "file:///C:/Windows/System32/calc.exe", "ms-settings:privacy", @"C:\Windows\notepad.exe", "/etc/passwd" })
        {
            Assert.Equal(new SharedText(link), ShareRequest.Parse(new Packet(PacketType.Share, new JsonObject { ["url"] = link })));
        }
    }

    [Fact]
    public void RequestSanitizesTheFileName()
    {
        var file = Packet.Parse("""{"id":1,"type":"flux.share.request","body":{"filename":"..\\..\\CON.txt"},"payloadSize":3,"payloadTransferInfo":{"tunnel":"t1"}}""")!;
        Assert.Equal(new SharedFile("_CON.txt", null), ShareRequest.Parse(file));
    }

    [Fact]
    public void ReceivedFileNeedsFreeSpace()
    {
        const long gib = 1L << 30;
        Assert.True(SharePlugin.Fits(100, gib));
        Assert.False(SharePlugin.Fits(gib, gib));
        Assert.False(SharePlugin.Fits(-1, gib));
        Assert.False(SharePlugin.Fits(long.MaxValue, gib));
        // The reserve is 256 MB.
        Assert.True(SharePlugin.Fits(gib - (256L << 20), gib));
        Assert.False(SharePlugin.Fits(gib - (256L << 20) + 1, gib));
    }

    [Fact]
    public void FreeSpaceOfAFolderReads()
    {
        Assert.True(SharePlugin.DiskFreeSpace(Path.GetTempPath()) > 0);
    }

    [Fact]
    public void SafeNameStaysInTheFolder()
    {
        Assert.Equal("passwd", ShareWire.SafeName("../../etc/passwd"));
        Assert.Equal("report.pdf", ShareWire.SafeName(@"C:\Users\me\report.pdf"));
        Assert.Equal("abc.txt", ShareWire.SafeName("a\0b\nc.txt"));
        Assert.Equal("file", ShareWire.SafeName(".."));
        Assert.Equal("file", ShareWire.SafeName("."));
        Assert.Equal("file", ShareWire.SafeName("dir/"));
        Assert.Equal("file", ShareWire.SafeName("   "));
        Assert.Equal("file", ShareWire.SafeName(""));
        Assert.Equal("Screenshot at 10.00\u202FAM.png", ShareWire.SafeName("Screenshot at 10.00\u202FAM.png"));
    }

    // A bidirectional control can show "invoice.pdf" for a name that ends in ".exe".
    [Fact]
    public void SafeNameDropsBidirectionalControls()
    {
        Assert.Equal("invoicefdp.exe", ShareWire.SafeName("invoice\u202Efdp.exe"));
        Assert.Equal("a.txt", ShareWire.SafeName("\u2066a\u2069.txt"));
        Assert.Equal("b.txt", ShareWire.SafeName("\u200E\u200F\u061C\u202A\u202B\u202C\u202Db.txt"));
        Assert.Equal("c.txt", ShareWire.SafeName("c\u0085\u009B.txt"));
        Assert.Equal("file", ShareWire.SafeName("\u202E"));
        Assert.Equal("Ünïcødé 名前.txt", ShareWire.SafeName("Ünïcødé 名前.txt"));
        Assert.Equal("ab", ShareWire.VisibleName("a\u202Eb"));
    }

    // The rules of FilePayload.SafeName in Flux.Protocol.
    [Fact]
    public void SafeNameFollowsTheWindowsRules()
    {
        Assert.Equal("_CON.txt", ShareWire.SafeName("../../CON.txt"));
        Assert.Equal("a.txt_stream", ShareWire.SafeName(@"C:\folder\a.txt:stream"));
        Assert.Equal("a_b_c_d_e_f_g.txt", ShareWire.SafeName("a<b>c\"d|e?f*g.txt"));
        Assert.Equal("_nul", ShareWire.SafeName("nul"));
        Assert.Equal("_COM1.tar.gz", ShareWire.SafeName("COM1.tar.gz"));
        Assert.Equal("_LPT¹.log", ShareWire.SafeName("LPT¹.log"));
        Assert.Equal("_CON .txt", ShareWire.SafeName("CON .txt"));
        Assert.Equal("CONSOLE.txt", ShareWire.SafeName("CONSOLE.txt"));
        Assert.Equal("report", ShareWire.SafeName("report. . "));
        Assert.Equal("é.txt", ShareWire.SafeName("e\u0301.txt"));
        Assert.Equal("_a.txt", ShareWire.SafeName("\uD800a.txt"));
        Assert.Equal("😀.txt", ShareWire.SafeName("😀.txt"));
    }

    [Fact]
    public void SafeNameCutsALongNameAndKeepsTheExtension()
    {
        var name = ShareWire.SafeName(new string('a', 300) + ".pdf");
        Assert.Equal(ShareWire.MaxName, name.Length);
        Assert.EndsWith("a.pdf", name);
        // The cut does not split a surrogate pair.
        var emoji = ShareWire.SafeName("x" + string.Concat(Enumerable.Repeat("😀", 100)) + ".png");
        Assert.Equal(ShareWire.MaxName - 1, emoji.Length);
        Assert.EndsWith("😀.png", emoji);
        Assert.Equal(emoji, System.Text.Encoding.UTF8.GetString(System.Text.Encoding.UTF8.GetBytes(emoji)));
        // A long extension is not an extension.
        Assert.Equal(ShareWire.MaxName, ShareWire.SafeName("a." + new string('b', 300)).Length);
    }

    [Fact]
    public void UniquePathNeverReusesAName()
    {
        var dir = Path.Combine(Path.GetTempPath(), "d");
        var taken = new HashSet<string> { "a.txt", "a (2).txt", "notes", ".env", "x.tar.gz" }.Select(n => Path.Combine(dir, n)).ToHashSet();
        bool Exists(string p) => taken.Contains(p);
        Assert.Equal(Path.Combine(dir, "b.txt"), ShareWire.UniquePath(dir, "b.txt", Exists));
        Assert.Equal(Path.Combine(dir, "a (3).txt"), ShareWire.UniquePath(dir, "a.txt", Exists));
        Assert.Equal(Path.Combine(dir, "notes (2)"), ShareWire.UniquePath(dir, "notes", Exists));
        Assert.Equal(Path.Combine(dir, ".env (2)"), ShareWire.UniquePath(dir, ".env", Exists));
        Assert.Equal(Path.Combine(dir, "x.tar (2).gz"), ShareWire.UniquePath(dir, "x.tar.gz", Exists));
    }

    [Fact]
    public async Task ProgressThrottleLetsOneReportPerInterval()
    {
        var throttle = new ProgressThrottle();
        // The first report goes at once.
        Assert.True(throttle.Due());
        Assert.False(throttle.Due());
        await Task.Delay(150);
        Assert.True(throttle.Due());
        // The interval starts again at the last report.
        Assert.False(throttle.Due());
    }
}
