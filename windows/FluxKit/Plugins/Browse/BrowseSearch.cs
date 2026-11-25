using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace FluxKit;

// The answer of the computer to 1 search: the search body of flux.sftp. The
// computer ranks the results, the best match first. More is true when more
// names match than the answer holds. Partial is true when the search
// stopped at its time limit before it read each folder.
public sealed record BrowseFound(long Id, ValueList<BrowseEntry> Results, bool More = false, bool Partial = false, string? Error = null)
{
    public BrowseFound(long id, string? error = null) : this(id, ValueList<BrowseEntry>.Empty, false, false, error)
    {
    }

    // Parses the search body of flux.sftp. It returns null for a packet
    // without a search body or without an ID. It skips a result without an
    // absolute path.
    public static BrowseFound? Parse(Packet p)
    {
        if (p.Type != PacketType.Sftp || p.Object("search") is not { } body || Json.Long(body["id"]) is not { } id)
        {
            return null;
        }
        var results = new List<BrowseEntry>();
        foreach (var o in (body["results"] as JsonArray ?? []).OfType<JsonObject>())
        {
            if (Json.String(o["path"]) is not { } path || !path.StartsWith('/') ||
                path.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() is not { } name)
            {
                continue;
            }
            var seconds = Json.Long(o["modified"]) ?? 0;
            results.Add(new BrowseEntry(name, path, Json.Bool(o["dir"]) ?? false, Math.Max(0, Json.Long(o["size"]) ?? 0),
                seconds > 0 ? DateTimeOffset.FromUnixTimeSeconds(seconds) : null));
        }
        var error = Json.String(body["error"]) is { Length: > 0 } e ? e : null;
        return new BrowseFound(id, ValueList.From(results), Json.Bool(body["more"]) ?? false, Json.Bool(body["partial"]) ?? false, error);
    }
}

// The search of Get files. The computer searches the names in its shared
// folders and answers with BrowseFound.
public static class BrowseSearch
{
    // The longest query in bytes that the computer accepts.
    public const int MaxQuery = 200;

    // The flux.sftp.request of a search. An empty path searches each shared
    // folder.
    public static Packet Request(long id, string query, string path) =>
        new(PacketType.SftpRequest, new JsonObject
        {
            ["search"] = new JsonObject { ["id"] = id, ["query"] = query, ["path"] = path },
        });

    // The text of a search without the spaces around it, cut to MaxQuery
    // bytes. A character stays whole.
    public static string Query(string text)
    {
        var q = text.Trim();
        if (Encoding.UTF8.GetByteCount(q) <= MaxQuery)
        {
            return q;
        }
        var b = new StringBuilder();
        var bytes = 0;
        var e = StringInfo.GetTextElementEnumerator(q);
        while (e.MoveNext())
        {
            var c = e.GetTextElement();
            var n = Encoding.UTF8.GetByteCount(c);
            if (bytes + n > MaxQuery)
            {
                break;
            }
            b.Append(c);
            bytes += n;
        }
        return b.ToString();
    }

    // The folder that a search reads. At the top of the first root, which
    // is Home, it is empty, so that the search reads each shared folder.
    // Else it is the folder on screen.
    public static string Scope(string path, IReadOnlyList<BrowseRoot> roots)
    {
        if (roots.Count == 0 || path.Length == 0)
        {
            return "";
        }
        return BrowsePath.IsRoot(path, [roots[0]]) ? "" : path;
    }

    // The place of a result for a list: the root name, then the folders
    // down to the folder that holds the result, such as "Home/Documents".
    public static string Location(string path, IReadOnlyList<BrowseRoot> roots)
    {
        var parent = BrowsePath.Parent(path);
        if (BrowsePath.Root(parent, roots) is null)
        {
            return parent;
        }
        return string.Join("/", BrowsePath.Crumbs(parent, roots).Select(c => c.Name));
    }
}
