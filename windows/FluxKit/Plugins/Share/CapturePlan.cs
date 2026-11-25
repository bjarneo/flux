using System.Text.Json.Nodes;

namespace FluxKit;

// The kinds of new images that Flux sends by itself. Windows sends only
// screenshots. The plan keeps the photo kind of the Mac, so that its rules
// stay the same.
public enum CaptureKind
{
    Screenshot,
    Photo,
}

// 1 new image that the capture watch found. The ID orders the images by the
// time that they arrived on this computer, in microseconds: the time that
// the file was made in the screenshot folder. Kind is null for an item that
// Flux does not send. Pending is true while the item is still being
// written. DateAdded is the time that the item arrived, in seconds.
public sealed record CaptureItem(long Id, CaptureKind? Kind, string Name, bool Pending, long DateAdded);

// The rules of the capture watch.
public static class CaptureRules
{
    // A pending item that is older than this, in seconds, is lost. The watch
    // does not wait for it.
    public const long PendingLimit = 24 * 60 * 60;

    // The image formats that the screenshot tools of Windows write: Windows
    // and Print Screen write PNG, and the Snipping Tool can write JPEG or GIF.
    static readonly HashSet<string> ImageExtensions = [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".heic", ".tif", ".tiff"];

    // Reports whether a file in the screenshot folder is a screenshot. The
    // folder of Windows holds only screenshots, so each image counts. Screen
    // recordings are not images, so they stay home. The Mac also checks the
    // screen capture mark of macOS, which Windows does not have.
    public static bool IsScreenshot(string name) => ImageExtensions.Contains(Path.GetExtension(name).ToLowerInvariant());
}

// What the capture watch has done, so that no image goes out twice. Every
// item up to Baseline is done. Sent holds the items after the baseline that
// went out. From holds, for each switch that is on, the newest item ID at
// the time that the switch turned on. Only a newer item of that kind goes
// out. CapturePlan.swift of the Mac app has the same rules.
public sealed record CaptureState
{
    public long Baseline { get; init; }
    public ValueList<long> Sent { get; init; } = ValueList<long>.Empty;
    public IReadOnlyDictionary<CaptureKind, long> From { get; init; } = new Dictionary<CaptureKind, long>();

    // Turns a kind on. newest is the newest item ID now.
    public CaptureState Enable(CaptureKind kind, long newest)
    {
        if (From.ContainsKey(kind))
        {
            return this;
        }
        // With no switch on, nothing older than now needs a look.
        if (From.Count == 0)
        {
            return new CaptureState { Baseline = newest, From = new Dictionary<CaptureKind, long> { [kind] = newest } };
        }
        return this with { From = new Dictionary<CaptureKind, long>(From) { [kind] = newest } };
    }

    public CaptureState Disable(CaptureKind kind)
    {
        var from = new Dictionary<CaptureKind, long>(From);
        from.Remove(kind);
        return this with { From = from };
    }

    public CaptureState MarkSent(long id) => Sent.Contains(id) ? this : this with { Sent = ValueList.From(Sent.Append(id).Order()) };

    public bool Equals(CaptureState? other) =>
        other is not null && Baseline == other.Baseline && Sent.Equals(other.Sent) &&
        From.Count == other.From.Count && From.All(f => other.From.TryGetValue(f.Key, out var v) && v == f.Value);

    public override int GetHashCode() => HashCode.Combine(Baseline, Sent, From.Count);

    // The state as JSON for the settings.
    public JsonObject ToJson()
    {
        var from = new JsonObject();
        foreach (var (kind, id) in From.OrderBy(f => f.Key))
        {
            from[Name(kind)] = id;
        }
        return new JsonObject
        {
            ["baseline"] = Baseline,
            ["sent"] = new JsonArray(Sent.Select(id => (JsonNode?)id).ToArray()),
            ["from"] = from,
        };
    }

    // Reads the state from the settings. A node that does not read gives the empty state.
    public static CaptureState FromJson(JsonNode? node)
    {
        if (node is not JsonObject o)
        {
            return new CaptureState();
        }
        var from = new Dictionary<CaptureKind, long>();
        if (o["from"] is JsonObject f)
        {
            foreach (var (key, value) in f)
            {
                if (Kind(key) is { } kind && Json.Long(value) is { } id)
                {
                    from[kind] = id;
                }
            }
        }
        var sent = o["sent"] is JsonArray a ? a.Select(Json.Long).OfType<long>().Order().ToArray() : [];
        return new CaptureState { Baseline = Json.Long(o["baseline"]) ?? 0, Sent = ValueList.From(sent), From = from };
    }

    static string Name(CaptureKind kind) => kind == CaptureKind.Screenshot ? "screenshot" : "photo";

    static CaptureKind? Kind(string name) => name switch
    {
        "screenshot" => CaptureKind.Screenshot,
        "photo" => CaptureKind.Photo,
        _ => null,
    };
}

// The result of 1 scan: the items to send now, the new state, and the number
// of items that are due but wait for the next scan, because 1 scan sends at
// most MaxSend items.
public sealed record CapturePlan(IReadOnlyList<(CaptureItem Item, CaptureKind Kind)> Send, CaptureState State, int Waiting);

public static class CapturePlanner
{
    // The most IDs that CaptureState.Sent keeps.
    public const int MaxSent = 500;

    // The most items that 1 scan sends, so that no scan sends a large batch
    // at once. The next scan sends the rest.
    public const int MaxSend = 50;

    // Plans a scan of the items after the baseline. An item goes out when it
    // is complete, its kind is known, its switch is on, it is newer than the
    // time that the switch turned on, and it did not go out before. The
    // baseline moves up through the items that need no more work. A pending
    // item or an item that did not go out yet stops it, so that the next scan
    // looks at that item again. The oldest MaxSend items go out, and the rest
    // wait for the next scan. now is the time in seconds.
    public static CapturePlan Plan(CaptureState state, IEnumerable<CaptureItem> items, long now)
    {
        var send = new List<(CaptureItem, CaptureKind)>();
        var waiting = 0;
        var baseline = state.Baseline;
        var blocked = false;
        var sent = state.Sent.ToHashSet();
        foreach (var item in items.Where(i => i.Id > state.Baseline).OrderBy(i => i.Id))
        {
            bool done;
            if (sent.Contains(item.Id))
            {
                done = true;
            }
            else if (item.Pending)
            {
                done = now - item.DateAdded > CaptureRules.PendingLimit;
            }
            else if (item.Kind is { } kind && state.From.TryGetValue(kind, out var start) && item.Id > start)
            {
                if (send.Count < MaxSend)
                {
                    send.Add((item, kind));
                }
                else
                {
                    waiting++;
                }
                done = false;
            }
            else
            {
                done = true;
            }
            if (!done)
            {
                blocked = true;
            }
            if (done && !blocked)
            {
                baseline = item.Id;
            }
        }
        var next = state with
        {
            Baseline = baseline,
            Sent = ValueList.From(state.Sent.Where(id => id > baseline).Order().TakeLast(MaxSent)),
        };
        return new CapturePlan(send, next, waiting);
    }
}
