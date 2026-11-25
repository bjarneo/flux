namespace FluxKit;

// A top folder that the computer shares, like Home or Downloads.
public sealed record BrowseRoot(string Name, string Path);

// One entry of a folder on the computer. Modified is the last change of the
// entry, when the computer reports it.
public sealed record BrowseEntry(string Name, string Path, bool Dir, long Size, DateTimeOffset? Modified = null)
{
    public string Id => Path;

    // The entry name in folder from its SFTP attributes. A time at or
    // before 1970 means that the server sent no time.
    internal static BrowseEntry FromAttributes(string folder, string name, bool dir, long size, DateTimeOffset? modified) =>
        new(name, BrowsePath.Join(folder, name), dir, Math.Max(0, size),
            modified is { } m && m > DateTimeOffset.UnixEpoch ? m : null);

    // The entries of a folder as the browser shows them: no hidden files,
    // folders first, then by name without regard to case.
    public static IReadOnlyList<BrowseEntry> Listing(IEnumerable<BrowseEntry> entries) =>
        entries
            .Where(e => !e.Name.StartsWith('.'))
            .OrderBy(e => e.Dir ? 0 : 1)
            .ThenBy(e => e.Name.ToLowerInvariant(), StringComparer.Ordinal)
            .ToArray();
}

// Remote paths of a browse session. Paths use "/" and are absolute.
public static class BrowsePath
{
    // The path of name inside dir.
    public static string Join(string dir, string name) => dir.EndsWith('/') ? dir + name : dir + "/" + name;

    // The folder that contains path. The parent of "/" is "/".
    public static string Parent(string path)
    {
        var trimmed = Trim(path);
        var slash = trimmed.LastIndexOf('/');
        if (slash < 0)
        {
            return "/";
        }
        var parent = trimmed[..slash];
        return parent.Length == 0 ? "/" : parent;
    }

    // The root that contains path. When roots nest, like Home and
    // Home/Downloads, the deepest root wins.
    public static BrowseRoot? Root(string path, IReadOnlyList<BrowseRoot> roots)
    {
        var p = Trim(path);
        return roots.Where(r => Contains(Trim(r.Path), p)).MaxBy(r => Trim(r.Path).Length);
    }

    // True when path is 1 of the roots, so there is nothing above it to
    // open.
    public static bool IsRoot(string path, IReadOnlyList<BrowseRoot> roots) => roots.Any(r => Trim(r.Path) == Trim(path));

    // The folders from the root down to path, for a path bar. The first
    // crumb has the name of the root. A path outside every root starts at
    // "/".
    public static IReadOnlyList<BrowseRoot> Crumbs(string path, IReadOnlyList<BrowseRoot> roots)
    {
        var p = Trim(path);
        var root = Root(p, roots) is { } r ? new BrowseRoot(r.Name, Trim(r.Path)) : new BrowseRoot("/", "/");
        var crumbs = new List<BrowseRoot> { root };
        var current = root.Path;
        var rest = p.Length >= root.Path.Length ? p[root.Path.Length..] : "";
        foreach (var part in rest.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            current = Join(current, part);
            crumbs.Add(new BrowseRoot(part, current));
        }
        return crumbs;
    }

    // True when path is base or lies inside it.
    static bool Contains(string @base, string path) => path == @base || @base == "/" || path.StartsWith(@base + "/", StringComparison.Ordinal);

    // Removes trailing slashes, but keeps "/".
    static string Trim(string path)
    {
        var p = path;
        while (p.Length > 1 && p.EndsWith('/'))
        {
            p = p[..^1];
        }
        return p;
    }
}
