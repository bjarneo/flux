using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace FluxKit;

// What a flux.share.request packet from the computer carries. Text wins over
// a URL, and a URL over a file, like in Flux for Android.
public abstract record ShareRequest
{
    // Reads a share packet. It returns null for a packet without text, URL,
    // or payload. now names a file that comes without a name. A "url" that is
    // not a web link is text, like in fluxd, because another scheme can start
    // an app.
    public static ShareRequest? Parse(Packet p, long? now = null)
    {
        if (p.String("text") is { } text)
        {
            return new SharedText(text);
        }
        if (p.String("url") is { } url)
        {
            return ShareWire.WebUrl(url) is { } web ? new SharedLink(web) : new SharedText(url);
        }
        if (p.HasPayload)
        {
            var name = p.String("filename") ?? $"file-{now ?? Packet.Now()}";
            return new SharedFile(ShareWire.SafeName(name), p.Long("lastModified"));
        }
        return null;
    }
}

public sealed record SharedText(string Text) : ShareRequest;

// A web link: http or https with a host.
public sealed record SharedLink(Uri Url) : ShareRequest;

// A file that comes as the payload of the packet. LastModified is in
// milliseconds. The "open" field of the packet does nothing: this device
// never opens a received file by itself.
public sealed record SharedFile(string Name, long? LastModified) : ShareRequest;

// The share packets that this device sends, with the fields of Flux for
// Android, and the rules for received file names. ShareWire.swift of the Mac
// app has the same rules.
public static partial class ShareWire
{
    // The most characters of a received file name. The name then fits in the
    // 255 characters of a Windows file name also with " (10000).part".
    internal const int MaxName = 180;

    [GeneratedRegex(@"\A[hH][tT][tT][pP][sS]?://\S+\z", RegexOptions.CultureInvariant)]
    private static partial Regex WebPattern();

    // The device names of Windows. A file with such a name before its first
    // dot opens the device, not a file.
    [GeneratedRegex(@"\A(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[0-9¹²³]|LPT[0-9¹²³])\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DeviceName();

    // Reports whether shared text is a web link: http or https, "://", a
    // host, and no space. Other schemes and file paths are text, like in
    // fluxd and Flux for Android.
    public static bool IsUrl(string text) => WebUrl(text) is not null;

    // The web link in the text, or null when the text is not 1 http or https
    // URL with a host. Uri.OriginalString keeps the text as it came.
    public static Uri? WebUrl(string text)
    {
        if (!WebPattern().IsMatch(text) || !Uri.TryCreate(text, UriKind.Absolute, out var url))
        {
            return null;
        }
        if (url.Scheme != Uri.UriSchemeHttp && url.Scheme != Uri.UriSchemeHttps)
        {
            return null;
        }
        return string.IsNullOrEmpty(url.Host) ? null : url;
    }

    // Text or a link from the user. A link goes as "url", so that the
    // computer opens it.
    public static Packet Text(string text)
    {
        var trimmed = text.Trim();
        return new Packet(PacketType.Share, IsUrl(trimmed) ? new JsonObject { ["url"] = trimmed } : new JsonObject { ["text"] = text });
    }

    // Text that the camera read. The "scan" flag makes the computer save it
    // in a file.
    public static Packet Scan(string text) =>
        new(PacketType.Share, new JsonObject { ["text"] = text, ["scan"] = true });

    // Announces a batch of files before the first file.
    public static Packet Update(int count, long total) =>
        new(PacketType.ShareUpdate, new JsonObject { ["numberOfFiles"] = count, ["totalPayloadSize"] = total });

    // 1 file of a batch, offered on a payload port.
    public static Packet File(string name, int count, long total, long size, int port) =>
        new(PacketType.Share, new JsonObject
        {
            ["filename"] = name,
            ["open"] = false,
            ["numberOfFiles"] = count,
            ["totalPayloadSize"] = total,
        })
        {
            PayloadSize = size,
            PayloadPort = port,
        };

    // 1 captured file with extra fields, for example "photo" or "scan",
    // offered on a payload port. An extra field replaces a field of the same
    // name.
    public static Packet Capture(string name, JsonObject extra, long size, int port)
    {
        var body = new JsonObject { ["filename"] = name, ["open"] = false };
        foreach (var (key, value) in extra)
        {
            body[key] = value?.DeepClone();
        }
        return new Packet(PacketType.Share, body) { PayloadSize = size, PayloadPort = port };
    }

    // Makes a received file name safe for a Windows folder. It keeps only the
    // last element of the name, so that the file stays in the download
    // folder. It removes control characters and bidirectional controls, so
    // that the name shows its real extension. It replaces the characters that
    // Windows does not allow, and it puts "_" before a device name such as
    // CON. These Windows rules come from FilePayload.SafeName of Flux.Protocol.
    public static string SafeName(string name)
    {
        var last = name[(name.LastIndexOfAny(['/', '\\']) + 1)..];
        var b = new StringBuilder(last.Length);
        for (var i = 0; i < last.Length; i++)
        {
            var c = last[i];
            if (char.IsHighSurrogate(c) && i + 1 < last.Length && char.IsLowSurrogate(last[i + 1]))
            {
                b.Append(c).Append(last[i + 1]);
                i++;
            }
            else if (char.IsSurrogate(c))
            {
                // A lone surrogate is not text. Normalize throws on it.
                b.Append('_');
            }
            else if (!HidesText(c))
            {
                b.Append(c is '<' or '>' or ':' or '"' or '|' or '?' or '*' ? '_' : c);
            }
        }
        // Windows removes a dot or a space at the end of a name, so the name
        // on the disk would differ from the name in the messages.
        var clean = b.ToString().Normalize(NormalizationForm.FormC).Trim().TrimEnd('.', ' ');
        if (clean.Length == 0)
        {
            return "file";
        }
        if (DeviceName().IsMatch(clean.Split('.')[0].TrimEnd(' ')))
        {
            clean = "_" + clean;
        }
        return Cut(clean, MaxName);
    }

    // Removes the characters that hide or reorder the text of a file name:
    // control characters and bidirectional controls such as U+202E, which
    // can show "exe.txt" for a name that ends in ".exe".
    public static string VisibleName(string name) => string.Concat(name.Where(c => !HidesText(c)));

    internal static bool HidesText(char c) =>
        char.IsControl(c) || c is '؜' or '‎' or '‏' or (>= '‪' and <= '‮') or (>= '⁦' and <= '⁩');

    // Cuts a name to at most max characters, and keeps an extension of up to
    // a quarter of max. The cut does not split a surrogate pair.
    static string Cut(string name, int max)
    {
        if (name.Length <= max)
        {
            return name;
        }
        var dot = name.LastIndexOf('.');
        var ext = dot > 0 && name.Length - dot <= max / 4 ? name[dot..] : "";
        var length = max - ext.Length;
        if (char.IsHighSurrogate(name[length - 1]))
        {
            length--;
        }
        var cut = (name[..length].TrimEnd('.', ' ') + ext).TrimEnd('.', ' ');
        return cut.Length == 0 ? "file" : cut;
    }

    // Returns folder\name, or folder\"name (2).ext", "name (3).ext", and so
    // on: the first that does not exist.
    public static string UniquePath(string folder, string name, Func<string, bool> exists)
    {
        var first = Path.Combine(folder, name);
        if (!exists(first))
        {
            return first;
        }
        var dot = name.LastIndexOf('.');
        var ext = dot >= 0 ? name[(dot + 1)..] : "";
        if (ext.Length + 1 >= name.Length)
        {
            ext = "";
        }
        var stem = ext.Length == 0 ? name : name[..^(ext.Length + 1)];
        for (var i = 2; ; i++)
        {
            var number = i.ToString(CultureInfo.InvariantCulture);
            var candidate = Path.Combine(folder, ext.Length == 0 ? $"{stem} ({number})" : $"{stem} ({number}).{ext}");
            if (!exists(candidate))
            {
                return candidate;
            }
        }
    }
}
