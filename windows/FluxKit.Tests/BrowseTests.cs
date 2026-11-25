using FluxKit;

namespace FluxKit.Tests;

// BrowseTests.swift of the Mac app.
public class BrowseTests
{
    static SftpOffer? Offer(string line) => SftpOffer.Parse(Packet.Parse(line)!);

    [Fact]
    public void TunnelOfferFromFluxd()
    {
        var o = Offer("""{"id":1,"type":"flux.sftp","body":{"tunnel":"s1","user":"flux","password":"pw","path":"/home/u","multiPaths":["/home/u","/home/u/Pictures"],"pathNames":["Home","Pictures"]}}""")!;
        Assert.Equal("s1", o.Tunnel);
        Assert.Equal("flux", o.User);
        Assert.Equal("pw", o.Password);
        Assert.Equal([new BrowseRoot("Home", "/home/u"), new BrowseRoot("Pictures", "/home/u/Pictures")], o.Roots);
    }

    [Fact]
    public void SearchFlagOfTheOffer()
    {
        Assert.True(Offer("""{"id":1,"type":"flux.sftp","body":{"tunnel":"s1","user":"flux","password":"pw","multiPaths":["/home/u"],"pathNames":["Home"],"search":true}}""")!.Search);
        // An older fluxd has no search.
        Assert.False(Offer("""{"id":1,"type":"flux.sftp","body":{"tunnel":"s1","user":"flux","password":"pw","multiPaths":["/home/u"],"pathNames":["Home"]}}""")!.Search);
    }

    [Fact]
    public void SearchAnswer()
    {
        var p = Packet.Parse("""{"id":1,"type":"flux.sftp","body":{"search":{"id":7,"results":[{"path":"/home/u/Documents/plan.md","dir":false,"size":12,"modified":1790000000},{"path":"/home/u/notes","dir":true,"size":4096,"modified":0},{"path":"relative.txt","dir":false,"size":1,"modified":1},{"dir":false}],"more":true,"partial":false}}}""")!;
        // An answer to a search is not an offer.
        Assert.Null(SftpOffer.Parse(p));
        var found = BrowseFound.Parse(p)!;
        Assert.Equal(7, found.Id);
        Assert.True(found.More);
        Assert.False(found.Partial);
        Assert.Null(found.Error);
        // A result without an absolute path is skipped.
        Assert.Equal([
            new BrowseEntry("plan.md", "/home/u/Documents/plan.md", false, 12, DateTimeOffset.FromUnixTimeSeconds(1_790_000_000)),
            new BrowseEntry("notes", "/home/u/notes", true, 4096),
        ], found.Results);
    }

    [Fact]
    public void SearchErrorAndOtherPackets()
    {
        var failed = BrowseFound.Parse(Packet.Parse("""{"id":1,"type":"flux.sftp","body":{"search":{"id":3,"results":[],"more":false,"partial":false,"error":"Get files is not open. Open it again."}}}""")!);
        Assert.Equal(new BrowseFound(3, "Get files is not open. Open it again."), failed);
        // An offer is not an answer.
        Assert.Null(BrowseFound.Parse(Packet.Parse("""{"id":1,"type":"flux.sftp","body":{"tunnel":"s1","user":"flux","password":"pw","multiPaths":["/h"],"pathNames":["Home"],"search":true}}""")!));
        // No ID.
        Assert.Null(BrowseFound.Parse(Packet.Parse("""{"id":1,"type":"flux.sftp","body":{"search":{"results":[]}}}""")!));
        Assert.Null(BrowseFound.Parse(Packet.Parse("""{"id":1,"type":"flux.sftp.request","body":{"search":{"id":3}}}""")!));
    }

    [Fact]
    public void SearchRequest()
    {
        var p = BrowseSearch.Request(9, "plan 2024", "");
        Assert.Equal(PacketType.SftpRequest, p.Type);
        var body = p.Object("search")!;
        Assert.Equal(9, Json.Long(body["id"]));
        Assert.Equal("plan 2024", Json.String(body["query"]));
        Assert.Equal("", Json.String(body["path"]));
        // A search starts no session.
        Assert.Null(p.Bool("startBrowsing"));
    }

    [Fact]
    public void SearchQueryScopeAndLocation()
    {
        Assert.Equal("plan", BrowseSearch.Query("  plan  "));
        // The query fits 200 bytes.
        Assert.Equal(200, System.Text.Encoding.UTF8.GetByteCount(BrowseSearch.Query(new string('é', 150))));
        Assert.Equal("", BrowseSearch.Query(" \n "));
        // A character stays whole.
        Assert.Equal(new string('a', 199), BrowseSearch.Query(new string('a', 199) + "👍🏽"));

        BrowseRoot[] roots = [new("Home", "/home/u"), new("Downloads", "/home/u/Downloads")];
        // The top of Home searches each shared folder.
        Assert.Equal("", BrowseSearch.Scope("/home/u", roots));
        Assert.Equal("", BrowseSearch.Scope("/home/u/", roots));
        Assert.Equal("/home/u/Documents", BrowseSearch.Scope("/home/u/Documents", roots));
        Assert.Equal("/home/u/Downloads", BrowseSearch.Scope("/home/u/Downloads", roots));
        Assert.Equal("", BrowseSearch.Scope("", roots));

        Assert.Equal("Home/Documents/Work", BrowseSearch.Location("/home/u/Documents/Work/plan.md", roots));
        Assert.Equal("Downloads", BrowseSearch.Location("/home/u/Downloads/a.zip", roots));
        Assert.Equal("Home", BrowseSearch.Location("/home/u/notes", roots));
        Assert.Equal("/srv/x", BrowseSearch.Location("/srv/x/a", roots));
    }

    [Fact]
    public void BadRootListsAreRejected()
    {
        // The lists differ in length.
        Assert.Null(Offer("""{"id":1,"type":"flux.sftp","body":{"tunnel":"t","user":"k","password":"p","path":"/home/u","multiPaths":["/home/u","/srv"],"pathNames":["Home"]}}"""));
        // No lists.
        Assert.Null(Offer("""{"id":1,"type":"flux.sftp","body":{"tunnel":"t","user":"k","password":"p","path":"/home/u"}}"""));
        // Empty lists.
        Assert.Null(Offer("""{"id":1,"type":"flux.sftp","body":{"tunnel":"t","user":"k","password":"p","multiPaths":[],"pathNames":[]}}"""));
    }

    [Fact]
    public void RejectedOffers()
    {
        Assert.Null(Offer("""{"id":1,"type":"flux.sftp","body":{"errorMessage":"no"}}"""));
        Assert.Null(Offer("""{"id":1,"type":"flux.sftp","body":{"errorMessage":"","tunnel":"t","user":"k","password":"p","multiPaths":["/h"],"pathNames":["Home"]}}"""));
        Assert.Null(Offer("""{"id":1,"type":"flux.sftp","body":{"user":"k","password":"p","multiPaths":["/h"],"pathNames":["Home"]}}"""));
        // An address is not a tunnel.
        Assert.Null(Offer("""{"id":1,"type":"flux.sftp","body":{"ip":"10.0.0.2","port":1740,"user":"k","password":"p","multiPaths":["/h"],"pathNames":["Home"]}}"""));
        Assert.Null(Offer("""{"id":1,"type":"flux.sftp","body":{"tunnel":"","user":"k","password":"p","multiPaths":["/h"],"pathNames":["Home"]}}"""));
        Assert.Null(Offer("""{"id":1,"type":"flux.sftp","body":{"tunnel":"t","password":"p","multiPaths":["/h"],"pathNames":["Home"]}}"""));
        Assert.Null(Offer("""{"id":1,"type":"flux.sftp.request","body":{"tunnel":"t","user":"k","password":"p","multiPaths":["/h"],"pathNames":["Home"]}}"""));
    }

    [Fact]
    public void ListingHidesDotFilesAndSortsFoldersFirst()
    {
        BrowseEntry[] raw =
        [
            new("b.txt", "/h/b.txt", false, 1),
            new(".config", "/h/.config", true, 0),
            new("Zeta", "/h/Zeta", true, 0),
            new("A.txt", "/h/A.txt", false, 2),
            new("alpha", "/h/alpha", true, 0),
        ];
        Assert.Equal(["alpha", "Zeta", "A.txt", "b.txt"], BrowseEntry.Listing(raw).Select(e => e.Name));
    }

    [Fact]
    public void EntryFromTheAttributes()
    {
        var when = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
        Assert.Equal(new BrowseEntry("notes.txt", "/home/u/notes.txt", false, 12, when), BrowseEntry.FromAttributes("/home/u/", "notes.txt", false, 12, when));
        var dir = BrowseEntry.FromAttributes("/home/u", "Code", true, 0, null);
        Assert.Equal(new BrowseEntry("Code", "/home/u/Code", true, 0), dir);
        // A server without times gives no date.
        Assert.Null(BrowseEntry.FromAttributes("/", "a", false, 0, DateTimeOffset.UnixEpoch).Modified);
        Assert.Equal(0, BrowseEntry.FromAttributes("/", "big", false, -5, null).Size);
    }

    [Fact]
    public void ParentPath()
    {
        Assert.Equal("/home/u", BrowsePath.Parent("/home/u/Documents"));
        Assert.Equal("/home/u", BrowsePath.Parent("/home/u/Documents/"));
        Assert.Equal("/", BrowsePath.Parent("/home"));
        Assert.Equal("/", BrowsePath.Parent("/"));
        Assert.Equal("/etc", BrowsePath.Join("/", "etc"));
        Assert.Equal("/home/u/a", BrowsePath.Join("/home/u", "a"));
    }

    [Fact]
    public void DeepestRootAndComponentBoundary()
    {
        BrowseRoot[] roots = [new("Home", "/home/u"), new("Downloads", "/home/u/Downloads/")];
        Assert.Equal("Downloads", BrowsePath.Root("/home/u/Downloads/x", roots)?.Name);
        Assert.Equal("Home", BrowsePath.Root("/home/u/Documents", roots)?.Name);
        Assert.Null(BrowsePath.Root("/home/user2", roots));
        Assert.True(BrowsePath.IsRoot("/home/u/Downloads", roots));
        Assert.False(BrowsePath.IsRoot("/home/u/Documents", roots));
    }

    [Fact]
    public void CrumbsStartAtTheRootName()
    {
        BrowseRoot[] roots = [new("Home", "/home/u"), new("Downloads", "/home/u/Downloads")];
        Assert.Equal([
            new BrowseRoot("Home", "/home/u"),
            new BrowseRoot("Documents", "/home/u/Documents"),
            new BrowseRoot("Work", "/home/u/Documents/Work"),
        ], BrowsePath.Crumbs("/home/u/Documents/Work", roots));
        Assert.Equal([new BrowseRoot("Downloads", "/home/u/Downloads")], BrowsePath.Crumbs("/home/u/Downloads", roots));
        Assert.Equal([new BrowseRoot("/", "/"), new BrowseRoot("srv", "/srv"), new BrowseRoot("x", "/srv/x")], BrowsePath.Crumbs("/srv/x", roots));
    }

    [Fact]
    public void DownloadNames()
    {
        Assert.Equal("report.pdf", BrowseDownload.SafeName("report.pdf"));
        Assert.Equal("passwd", BrowseDownload.SafeName("../../etc/passwd"));
        Assert.Equal("b.txt", BrowseDownload.SafeName("a\\b.txt"));
        Assert.Equal("download", BrowseDownload.SafeName(".."));
        Assert.Equal("download", BrowseDownload.SafeName(""));
        // No bidirectional control.
        Assert.Equal("photogpj.exe", BrowseDownload.SafeName("photo‮gpj.exe"));
        // No control character.
        Assert.Equal("ab.txt", BrowseDownload.SafeName("a\nb\0.txt"));
        Assert.Equal("download", BrowseDownload.SafeName("‮⁦"));
        // Windows refuses these characters, the dots and the spaces at the end, and the device names.
        Assert.Equal("a_b_c_.txt", BrowseDownload.SafeName("a:b?c*.txt"));
        Assert.Equal("_ _ _ _", BrowseDownload.SafeName("< > \" |"));
        Assert.Equal("report", BrowseDownload.SafeName("report. . "));
        Assert.Equal("download", BrowseDownload.SafeName("..."));
        Assert.Equal("_CON", BrowseDownload.SafeName("CON"));
        Assert.Equal("_com1.txt", BrowseDownload.SafeName("com1.txt"));
        Assert.Equal("console.txt", BrowseDownload.SafeName("console.txt"));

        var folder = Path.Combine("dl");
        var taken = new HashSet<string> { Path.Combine(folder, "a.txt"), Path.Combine(folder, "a (2).txt"), Path.Combine(folder, "notes") };
        bool Exists(string p) => taken.Contains(p);
        Assert.Equal(Path.Combine(folder, "b.txt"), BrowseDownload.UniquePath("b.txt", folder, Exists));
        Assert.Equal(Path.Combine(folder, "a (3).txt"), BrowseDownload.UniquePath("a.txt", folder, Exists));
        Assert.Equal(Path.Combine(folder, "notes (2)"), BrowseDownload.UniquePath("notes", folder, Exists));
        Assert.Equal("a.tar (2).gz", Path.GetFileName(BrowseDownload.UniquePath("a.tar.gz", folder, p => Path.GetFileName(p) == "a.tar.gz")));
    }

    [Fact]
    public void DownloadFraction()
    {
        var d = new BrowseDownload(Guid.NewGuid(), "a", 200) { Received = 50 };
        Assert.Equal(0.25, d.Fraction);
        Assert.True(d.IsRunning);
        Assert.Null(new BrowseDownload(Guid.NewGuid(), "a", 0).Fraction);
        Assert.Equal(1, (d with { Received = 400 }).Fraction);
    }

    [Fact]
    public void CapabilitiesListTheTunnel()
    {
        var plugin = new BrowsePlugin();
        Assert.Equal([PacketType.Sftp], plugin.Incoming);
        Assert.Equal([PacketType.SftpRequest, PacketType.Tunnel], plugin.Outgoing);
    }
}
