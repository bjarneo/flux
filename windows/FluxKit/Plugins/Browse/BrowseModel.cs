using System.Collections.Immutable;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;

namespace FluxKit;

// The state of 1 download.
public abstract record BrowseDownloadState
{
    public sealed record Running() : BrowseDownloadState;

    // The file is in the downloads folder at Path.
    public sealed record Done(string Path) : BrowseDownloadState;

    public sealed record Failed(string Reason) : BrowseDownloadState;
}

// One file that the browser saves in the downloads folder. Name is the name
// in the downloads folder, which can differ from the remote name.
public sealed record BrowseDownload(Guid Id, string Name, long Size)
{
    public long Received { get; init; }
    public BrowseDownloadState State { get; init; } = new BrowseDownloadState.Running();

    public bool IsRunning => State is BrowseDownloadState.Running;

    // The part done, or null when the size is unknown.
    public double? Fraction => Size > 0 ? Math.Min(1, (double)Received / Size) : null;

    // Names that Windows keeps for devices. A file cannot have them, also
    // not with an extension.
    static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³",
    };

    // A remote name as a local file name: the last path component without
    // control characters and bidirectional controls, with the characters
    // that Windows refuses changed to "_", and without the dots and the
    // spaces at the end that Windows removes. A device name gets "_" in
    // front. A name without a visible character is "download".
    public static string SafeName(string name)
    {
        var last = name.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        var b = new StringBuilder();
        foreach (var r in last.EnumerateRunes())
        {
            if (HidesText(r))
            {
                continue;
            }
            b.Append(r.Value is '<' or '>' or ':' or '"' or '|' or '?' or '*' ? "_" : r.ToString());
        }
        var visible = b.ToString().TrimEnd('.', ' ');
        if (visible.Trim().Length == 0)
        {
            return "download";
        }
        var stem = visible.Split('.')[0].TrimEnd(' ');
        return Reserved.Contains(stem) ? "_" + visible : visible;
    }

    // True for a scalar that hides or reorders the text of a file name:
    // control characters and bidirectional controls such as U+202E, which
    // can show "exe.txt" for a name that ends in ".exe".
    static bool HidesText(Rune r) =>
        Rune.GetUnicodeCategory(r) == UnicodeCategory.Control ||
        r.Value is 0x061C or 0x200E or 0x200F or (>= 0x202A and <= 0x202E) or (>= 0x2066 and <= 0x2069);

    // The first free path for the name in the folder: "a.txt", then
    // "a (2).txt", "a (3).txt", and so on.
    public static string UniquePath(string name, string folder, Func<string, bool> exists)
    {
        var first = Path.Combine(folder, name);
        if (!exists(first))
        {
            return first;
        }
        var dot = name.LastIndexOf('.');
        var ext = dot > 0 ? name[(dot + 1)..] : "";
        var stem = ext.Length == 0 ? name : name[..dot];
        for (var i = 2; ; i++)
        {
            var candidate = Path.Combine(folder, ext.Length == 0 ? $"{stem} ({i})" : $"{stem} ({i}).{ext}");
            if (!exists(candidate))
            {
                return candidate;
            }
        }
    }
}

// The state of 1 browse window. The window keeps 1 SSH session to the
// computer until it closes or the computer disconnects. The window calls it
// on the UI thread. BrowseModel.swift of the Mac app has the same rules.
public sealed class BrowseModel : Model
{
    readonly FluxCore core;
    BrowseSession? session;
    // Counts starts, so that the answer to an older request is ignored.
    int attempt;
    // Counts listings, so that only the latest one shows.
    int listing;
    bool awaitingOffer;
    // True after the link closed, so that the next link starts again.
    bool lostLink;
    readonly Dictionary<Guid, CancellationTokenSource> transfers = [];
    // The ID of the latest search. Only its answer shows. It starts at the
    // clock, so that an answer to an earlier window does not match.
    long searchId = Packet.Now();
    // The wait after the last key of the search.
    CancellationTokenSource? typing;

    string deviceName;
    bool loading = true;
    string? error;
    ValueList<BrowseRoot> roots = ValueList<BrowseRoot>.Empty;
    string path = "";
    IReadOnlyList<BrowseEntry> entries = [];
    ImmutableList<BrowseDownload> downloads = [];
    bool canSearch;
    string searchText = "";
    bool searching;
    BrowseFound? found;
    string? searchError;

    internal BrowseModel(FluxCore core, string deviceId)
    {
        this.core = core;
        DeviceId = deviceId;
        deviceName = core.WithDevice(deviceId, d => d.Name) ?? "The computer";
    }

    // How long the computer has to answer flux.sftp.request.
    internal TimeSpan AnswerTimeout { get; set; } = TimeSpan.FromSeconds(10);

    // How long the computer has to answer a search. It stops a search after
    // 10 seconds.
    internal TimeSpan SearchTimeout { get; set; } = TimeSpan.FromSeconds(20);

    // The time after the last key before a search starts.
    internal TimeSpan SearchDelay { get; set; } = TimeSpan.FromMilliseconds(350);

    public string DeviceId { get; }

    public string DeviceName
    {
        get => deviceName;
        private set => Update(ref deviceName, value);
    }

    public bool Loading
    {
        get => loading;
        private set => Update(ref loading, value);
    }

    public string? Error
    {
        get => error;
        private set => Update(ref error, value);
    }

    public ValueList<BrowseRoot> Roots
    {
        get => roots;
        private set => Update(ref roots, value);
    }

    // The folder on screen. It changes when a listing starts.
    public string Path
    {
        get => path;
        private set => Update(ref path, value);
    }

    public IReadOnlyList<BrowseEntry> Entries
    {
        get => entries;
        private set => Update(ref entries, value);
    }

    public ImmutableList<BrowseDownload> Downloads
    {
        get => downloads;
        private set => Update(ref downloads, value);
    }

    // True when the computer can search the names in its shared folders.
    public bool CanSearch
    {
        get => canSearch;
        private set => Update(ref canSearch, value);
    }

    // The text in the search field. While it holds more than spaces, the
    // window shows the search in place of the folder.
    public string SearchText
    {
        get => searchText;
        private set => Update(ref searchText, value);
    }

    // True from the first key of a search until its answer.
    public bool Searching
    {
        get => searching;
        private set => Update(ref searching, value);
    }

    // The last answer of the computer, or null before it.
    public BrowseFound? Found
    {
        get => found;
        private set => Update(ref found, value);
    }

    // Why the search failed, or null.
    public string? SearchError
    {
        get => searchError;
        private set => Update(ref searchError, value);
    }

    // True when a folder above the current one is inside a root.
    public bool CanGoUp => session is not null && Path.Length > 0 && !BrowsePath.IsRoot(Path, Roots);

    // The folders from the root down to the current one.
    public IReadOnlyList<BrowseRoot> Crumbs => Path.Length == 0 ? [] : BrowsePath.Crumbs(Path, Roots);

    // The root that holds the current folder.
    public BrowseRoot? Root => BrowsePath.Root(Path, Roots);

    public int ActiveDownloads => Downloads.Count(d => d.IsRunning);

    // True while the window shows the search in place of the folder.
    public bool InSearch => BrowseSearch.Query(SearchText).Length > 0;

    // True when Back has a step: it ends the search, or it opens the folder
    // above the current one.
    public bool CanGoBack => InSearch || CanGoUp;

    // The query of the search on screen.
    public string Query => BrowseSearch.Query(SearchText);

    // The folder that a search reads, see BrowseSearch.Scope.
    public string SearchScope => BrowseSearch.Scope(Path, Roots);

    // The placeholder of the search field.
    public string SearchPrompt =>
        SearchScope.Length == 0 ? "Search all shared folders" : $"Search in {(Crumbs.Count > 0 ? Crumbs[^1].Name : "this folder")}";

    // The place of a search result, such as "Home/Documents".
    public string Location(BrowseEntry entry) => BrowseSearch.Location(entry.Path, Roots);

    // Asks the computer for a new SFTP session.
    public void Start()
    {
        CloseSession();
        attempt++;
        var current = attempt;
        DeviceName = core.WithDevice(DeviceId, d => d.Name) ?? DeviceName;
        Loading = true;
        Error = null;
        Roots = ValueList<BrowseRoot>.Empty;
        Path = "";
        Entries = [];
        lostLink = false;
        CanSearch = false;
        EndSearch();
        if (!core.Send(new Packet(PacketType.SftpRequest, new System.Text.Json.Nodes.JsonObject { ["startBrowsing"] = true }), DeviceId))
        {
            awaitingOffer = false;
            Loading = false;
            Error = $"{DeviceName} is not connected. Try again when it connects.";
            return;
        }
        awaitingOffer = true;
        After(AnswerTimeout, () =>
        {
            if (attempt != current || !awaitingOffer)
            {
                return;
            }
            awaitingOffer = false;
            Loading = false;
            Error = $"{DeviceName} did not answer. Browsing files needs fluxd.";
        });
    }

    // Opens a folder of the session. It ends the search.
    public void Open(string folder)
    {
        if (session is not { } s)
        {
            return;
        }
        if (InSearch || Found is not null || SearchError is not null)
        {
            EndSearch();
        }
        listing++;
        var current = listing;
        Loading = true;
        Path = folder;
        _ = Task.Run(async () =>
        {
            try
            {
                var list = await s.ListAsync(folder).ConfigureAwait(false);
                core.Host.Post(() =>
                {
                    if (listing != current)
                    {
                        return;
                    }
                    Entries = list;
                    Error = null;
                    Loading = false;
                });
            }
            catch (Exception e) when (BrowseSession.IsFailure(e))
            {
                core.Host.Post(() =>
                {
                    if (listing != current)
                    {
                        return;
                    }
                    Entries = [];
                    Loading = false;
                    Error = $"Cannot open {folder}: {BrowseSession.Describe(e)}";
                });
            }
        });
    }

    // Ends the search, or else opens the folder that contains the current
    // one.
    public void GoUp()
    {
        if (InSearch)
        {
            EndSearch();
        }
        else if (CanGoUp)
        {
            Open(BrowsePath.Parent(Path));
        }
    }

    // Searches again, lists the current folder again, or starts a new
    // session when the session ended.
    public void Retry()
    {
        if (session is not null && InSearch)
        {
            Search(SearchText);
        }
        else if (session is not null && Path.Length > 0)
        {
            Open(Path);
        }
        else
        {
            Start();
        }
    }

    // Sets the text of the search field. The search starts when no key
    // comes for SearchDelay. Text with only spaces ends the search.
    public void SetSearchText(string text)
    {
        SearchText = text;
        typing?.Cancel();
        typing = null;
        searchId++;
        if (BrowseSearch.Query(text).Length == 0)
        {
            Searching = false;
            Found = null;
            SearchError = null;
            return;
        }
        Searching = true;
        var cts = new CancellationTokenSource();
        typing = cts;
        After(SearchDelay, () =>
        {
            if (typing == cts)
            {
                Search(text);
            }
        }, cts.Token);
    }

    // Asks the computer for the files and the folders whose names hold each
    // word of the text. The search reads SearchScope.
    public void Search(string text)
    {
        typing?.Cancel();
        typing = null;
        SearchText = text;
        searchId++;
        var current = searchId;
        var q = BrowseSearch.Query(text);
        if (!CanSearch || session is null || q.Length == 0)
        {
            Searching = false;
            return;
        }
        Searching = true;
        SearchError = null;
        if (!core.Send(BrowseSearch.Request(current, q, SearchScope), DeviceId))
        {
            Searching = false;
            SearchError = $"{DeviceName} is not connected. Try again when it connects.";
            return;
        }
        After(SearchTimeout, () =>
        {
            if (searchId != current || !Searching)
            {
                return;
            }
            Searching = false;
            SearchError = $"{DeviceName} did not answer the search";
        });
    }

    // Clears the search field and shows the folder again.
    public void EndSearch()
    {
        typing?.Cancel();
        typing = null;
        searchId++;
        SearchText = "";
        Searching = false;
        Found = null;
        SearchError = null;
    }

    // Enters a folder or downloads a file. A folder of the search results
    // opens in place of the search.
    public void Activate(BrowseEntry entry)
    {
        if (entry.Dir)
        {
            Open(entry.Path);
        }
        else
        {
            Download(entry);
        }
    }

    // Saves a file in the downloads folder under a free name. The file
    // grows as name.part and gets its name at the end.
    public void Download(BrowseEntry entry)
    {
        if (session is not { } s || entry.Dir)
        {
            return;
        }
        var folder = core.Host.Downloads();
        string dest;
        string part;
        FileStream file;
        try
        {
            Directory.CreateDirectory(folder);
            dest = BrowseDownload.UniquePath(BrowseDownload.SafeName(entry.Name), folder,
                p => File.Exists(p) || Directory.Exists(p) || File.Exists(p + ".part"));
            part = dest + ".part";
            file = new FileStream(part, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            core.Toast($"Cannot save {entry.Name}: {e.Message}");
            return;
        }
        var item = new BrowseDownload(Guid.NewGuid(), System.IO.Path.GetFileName(dest), entry.Size);
        Downloads = Downloads.Add(item);
        var cts = new CancellationTokenSource();
        transfers[item.Id] = cts;
        _ = Task.Run(() => DownloadAsync(s, entry, file, part, dest, item.Id, cts.Token));
    }

    // Stops a running download and deletes its partial file.
    public void Cancel(Guid id)
    {
        if (transfers.TryGetValue(id, out var cts))
        {
            cts.Cancel();
        }
    }

    // Removes finished and failed downloads from the list.
    public void ClearDownloads() => Downloads = Downloads.RemoveAll(d => !d.IsRunning);

    // Plugin events

    // Handles flux.sftp from the computer: the offer of a session, or the
    // answer to a search.
    internal void Receive(Packet p, FluxTls tls, byte[]? certificate)
    {
        // An answer to a search is never an offer.
        if (p.Object("search") is not null)
        {
            if (BrowseFound.Parse(p) is { } answer)
            {
                SearchAnswered(answer);
            }
            return;
        }
        if (!awaitingOffer)
        {
            return;
        }
        awaitingOffer = false;
        if (p.String("errorMessage") is { } message)
        {
            Loading = false;
            Error = message;
            return;
        }
        if (SftpOffer.Parse(p) is not { } offer)
        {
            Loading = false;
            Error = $"{DeviceName} sent no way to connect";
            return;
        }
        var current = attempt;
        var deviceId = DeviceId;
        _ = Task.Run(async () =>
        {
            try
            {
                var opened = await BrowseSession.OpenAsync(offer, tls, certificate, packet => core.Send(packet, deviceId),
                    () => core.Host.Post(() => SessionEnded(current))).ConfigureAwait(false);
                core.Host.Post(() =>
                {
                    if (attempt != current)
                    {
                        _ = opened.CloseAsync();
                        return;
                    }
                    session = opened;
                    Roots = offer.Roots;
                    CanSearch = offer.Search;
                    Open(offer.Roots[0].Path);
                });
            }
            catch (Exception e) when (BrowseSession.IsFailure(e))
            {
                core.Host.Post(() =>
                {
                    if (attempt != current)
                    {
                        return;
                    }
                    FluxLog.Info("browse", $"browse connect failed: {e.GetType().Name}: {e.Message}");
                    Loading = false;
                    Error = $"Cannot open files on {DeviceName}: {BrowseSession.Describe(e)}";
                });
            }
        });
    }

    // The link to the computer closed. The session ends with it.
    internal void Disconnected()
    {
        CloseSession();
        attempt++;
        awaitingOffer = false;
        lostLink = true;
        Loading = false;
        Searching = false;
        Error = $"{DeviceName} disconnected. Browsing starts again when it connects.";
    }

    // The link to the computer is back after it closed.
    internal void Connected()
    {
        if (lostLink)
        {
            Start();
        }
    }

    // Ends the session for good. The window closed.
    internal void Close()
    {
        attempt++;
        awaitingOffer = false;
        CloseSession();
    }

    // Private

    async Task DownloadAsync(BrowseSession s, BrowseEntry entry, FileStream file, string part, string dest, Guid id, CancellationToken ct)
    {
        BrowseDownloadState result;
        try
        {
            await using (file.ConfigureAwait(false))
            {
                await s.DownloadAsync(entry.Path, file, received =>
                    core.Host.Post(() => Change(id, d => d with { Received = Math.Max(d.Received, received) })), ct).ConfigureAwait(false);
            }
            File.Move(part, dest);
            result = new BrowseDownloadState.Done(dest);
        }
        catch (Exception e) when (BrowseSession.IsFailure(e))
        {
            try
            {
                File.Delete(part);
            }
            catch (Exception d) when (d is IOException or UnauthorizedAccessException)
            {
            }
            result = new BrowseDownloadState.Failed(ct.IsCancellationRequested ? "Canceled" : BrowseSession.Describe(e));
        }
        var canceled = ct.IsCancellationRequested;
        core.Host.Post(() =>
        {
            transfers.Remove(id);
            Change(id, d => d with { State = result });
            var folderName = DownloadsName(core.Host.Downloads());
            switch (result)
            {
                case BrowseDownloadState.Done done:
                    var name = System.IO.Path.GetFileName(done.Path);
                    core.Host.Notifier.Post(new SystemNotification($"browse-{id:N}", BrowsePlugin.DownloadCategory,
                        $"Downloaded {name}", $"From {DeviceName}. Saved in {folderName}")
                    {
                        UserInfo = new Dictionary<string, string> { [BrowsePlugin.PathKey] = done.Path },
                    });
                    core.Toast($"Saved {name} in {folderName}");
                    break;
                case BrowseDownloadState.Failed failed when !canceled:
                    core.Toast($"Downloading {entry.Name} failed: {failed.Reason}");
                    break;
            }
        });
    }

    // The name of the downloads folder for a message.
    static string DownloadsName(string folder) =>
        System.IO.Path.GetFileName(folder.TrimEnd(System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar)) is { Length: > 0 } n ? n : folder;

    // Shows the answer of the latest search. An answer to an older search
    // does not show.
    void SearchAnswered(BrowseFound answer)
    {
        if (answer.Id != searchId || !Searching)
        {
            return;
        }
        Searching = false;
        if (answer.Error is { } e)
        {
            Found = null;
            SearchError = e;
        }
        else
        {
            Found = answer;
            SearchError = null;
        }
    }

    // The SSH connection of start number ended closed.
    void SessionEnded(int ended)
    {
        if (ended != attempt || session is null)
        {
            return;
        }
        session = null;
        Loading = false;
        Error ??= $"The session with {DeviceName} ended.";
        Derived();
    }

    void CloseSession()
    {
        foreach (var cts in transfers.Values)
        {
            cts.Cancel();
        }
        if (session is not { } s)
        {
            return;
        }
        session = null;
        _ = s.CloseAsync();
        Derived();
    }

    void Change(Guid id, Func<BrowseDownload, BrowseDownload> change)
    {
        var i = Downloads.FindIndex(d => d.Id == id);
        if (i >= 0)
        {
            Downloads = Downloads.SetItem(i, change(Downloads[i]));
        }
    }

    // Runs the action on the UI thread after the delay, unless the token
    // ends first.
    void After(TimeSpan delay, Action action, CancellationToken ct = default) =>
        _ = Task.Delay(delay, ct).ContinueWith(t =>
        {
            if (!t.IsCanceled)
            {
                core.Host.Post(action);
            }
        }, TaskScheduler.Default);

    // Sets a field and reports the properties that derive from it.
    void Update<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (Set(ref field, value, name))
        {
            Derived();
        }
    }

    void Derived()
    {
        Changed(nameof(CanGoUp));
        Changed(nameof(Crumbs));
        Changed(nameof(Root));
        Changed(nameof(ActiveDownloads));
        Changed(nameof(InSearch));
        Changed(nameof(CanGoBack));
        Changed(nameof(Query));
        Changed(nameof(SearchScope));
        Changed(nameof(SearchPrompt));
    }
}
