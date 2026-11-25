using System.Globalization;
using System.Text.Json.Nodes;

namespace FluxKit;

// The symbology of a scanned code, independent of the decoder.
public enum CodeFormat
{
    QrCode,
    DataMatrix,
    Pdf417,
    Aztec,
    Ean13,
    Ean8,
    UpcA,
    UpcE,
    Code128,
    Code39,
    Code93,
    Codabar,
    Itf,
    Unknown,
}

// What the content of a code is.
public enum CodeKind
{
    Url,
    Wifi,
    Contact,
    Product,
    Text,
}

public static class CodeLabels
{
    public static string Label(this CodeFormat f) => f switch
    {
        CodeFormat.QrCode => "QR code",
        CodeFormat.DataMatrix => "Data Matrix",
        CodeFormat.Pdf417 => "PDF417",
        CodeFormat.Aztec => "Aztec",
        CodeFormat.Ean13 => "EAN-13",
        CodeFormat.Ean8 => "EAN-8",
        CodeFormat.UpcA => "UPC-A",
        CodeFormat.UpcE => "UPC-E",
        CodeFormat.Code128 => "Code 128",
        CodeFormat.Code39 => "Code 39",
        CodeFormat.Code93 => "Code 93",
        CodeFormat.Codabar => "Codabar",
        CodeFormat.Itf => "ITF",
        _ => "Barcode",
    };

    public static string Label(this CodeKind k) => k switch
    {
        CodeKind.Url => "Link",
        CodeKind.Wifi => "Wi-Fi network",
        CodeKind.Contact => "Contact",
        CodeKind.Product => "Product code",
        _ => "Text",
    };
}

// A Wi-Fi network from a code.
public sealed record WifiInfo(string Ssid, string Password, string Security);

// A contact from a code.
public sealed record ContactInfo(string Name, ValueList<string> Phones, ValueList<string> Emails, string Organization)
{
    public ContactInfo(string name, IEnumerable<string> phones, IEnumerable<string> emails, string organization)
        : this(name, ValueList.From(phones), ValueList.From(emails), organization)
    {
    }
}

// A code as the decoder reads it. Url, Wifi, and Contact are set when the
// content type is known.
public sealed record ScannedCode(CodeFormat Format, string Raw, string? Url = null, WifiInfo? Wifi = null, ContactInfo? Contact = null, bool Product = false);

// The packet that a code action sends: the body of flux.share.request.
public abstract record ShareBody
{
    // The computer opens the link.
    public sealed record OpenUrl(string Url) : ShareBody;

    // The computer puts the text on its clipboard.
    public sealed record Copy(string Text) : ShareBody;

    // The computer saves the text in a file in the scan folder.
    public sealed record Save(string Text) : ShareBody;

    // The fields of the flux.share.request body.
    public JsonObject Fields => this switch
    {
        OpenUrl o => new JsonObject { ["url"] = o.Url },
        Copy c => new JsonObject { ["text"] = c.Text },
        Save s => new JsonObject { ["text"] = s.Text, ["scan"] = true },
        _ => [],
    };

    public Packet Packet => new(PacketType.Share, Fields);
}

// A button of the result sheet.
public sealed record CodeAction(string Verb, ShareBody Body);

// The result sheet for 1 code: the type line, the value to show, and the 2 actions.
public sealed record CodeSheet(string Title, string Value, CodeKind Kind, ValueList<CodeAction> Actions);

// Classifies scanned codes and builds what the computer gets, like Flux for
// Android. Codes.swift of the Mac app has the same rules.
public static class Codes
{
    static readonly HashSet<CodeFormat> ProductFormats = [CodeFormat.Ean13, CodeFormat.Ean8, CodeFormat.UpcA, CodeFormat.UpcE];

    // Returns the kind of content in the code. Only an http or https link is
    // a link. A bookmark with another scheme, such as ftp or file, is text.
    public static CodeKind Kind(ScannedCode code)
    {
        if (WebLink(code) is not null)
        {
            return CodeKind.Url;
        }
        var lower = code.Raw.ToLowerInvariant();
        if (code.Wifi is not null || lower.StartsWith("wifi:", StringComparison.Ordinal))
        {
            return CodeKind.Wifi;
        }
        if (code.Contact is not null || lower.StartsWith("begin:vcard", StringComparison.Ordinal) || lower.StartsWith("mecard:", StringComparison.Ordinal))
        {
            return CodeKind.Contact;
        }
        if (code.Product || ProductFormats.Contains(code.Format))
        {
            return CodeKind.Product;
        }
        return CodeKind.Text;
    }

    // The http or https link of the code, from its bookmark or its raw value, or null.
    static string? WebLink(ScannedCode code) =>
        new[] { code.Url, code.Raw }.OfType<string>().Select(s => s.Trim()).FirstOrDefault(ShareWire.IsUrl);

    // Builds the result sheet. A link opens or copies on the computer.
    // Anything else saves or copies on the computer. pc is the computer name.
    public static CodeSheet Sheet(ScannedCode code, string pc)
    {
        var kind = Kind(code);
        var value = Text(code, kind);
        CodeAction[] actions = kind == CodeKind.Url
            ? [new($"Open on {pc}", new ShareBody.OpenUrl(value)), new($"Copy on {pc}", new ShareBody.Copy(value))]
            : [new($"Save on {pc}", new ShareBody.Save(value)), new($"Copy on {pc}", new ShareBody.Copy(value))];
        return new CodeSheet($"{code.Format.Label()} · {kind.Label()}", value, kind, ValueList.From(actions));
    }

    // Returns the text that the computer gets. Wi-Fi and contact codes become
    // readable lines. Other codes keep their raw value.
    public static string Text(ScannedCode code, CodeKind? kind = null)
    {
        switch (kind ?? Kind(code))
        {
            case CodeKind.Url:
                return WebLink(code) ?? code.Raw.Trim();
            case CodeKind.Wifi:
                if (code.Wifi is not { } w)
                {
                    return code.Raw;
                }
                var lines = new List<string> { $"Wi-Fi network: {w.Ssid}" };
                if (w.Password.Length > 0)
                {
                    lines.Add($"Password: {w.Password}");
                }
                if (w.Security.Length > 0)
                {
                    lines.Add($"Security: {w.Security}");
                }
                return string.Join('\n', lines);
            case CodeKind.Contact:
                if (code.Contact is not { } c)
                {
                    return code.Raw;
                }
                var text = string.Join('\n', new[] { c.Name, c.Organization }.Where(s => s.Length > 0).Concat(c.Phones).Concat(c.Emails));
                return text.Length == 0 ? code.Raw : text;
            default:
                return code.Raw;
        }
    }
}

// The names of the files that the camera sends.
public static class CaptureNames
{
    // Returns a photo name such as IMG_20260925_101500.jpg.
    public static string Photo(DateTime? time = null) => Format("'IMG_'yyyyMMdd'_'HHmmss'.jpg'", time);

    // Returns a document name such as scan-20260925-101500.pdf.
    public static string Document(DateTime? time = null) => Format("'scan-'yyyyMMdd'-'HHmmss'.pdf'", time);

    // Returns a signature name such as signature-20260925-101500.png.
    public static string Signature(DateTime? time = null) => Format("'signature-'yyyyMMdd'-'HHmmss'.png'", time);

    // The time is local time. A UTC time becomes local time first.
    static string Format(string pattern, DateTime? time)
    {
        var t = time ?? DateTime.Now;
        if (t.Kind == DateTimeKind.Utc)
        {
            t = t.ToLocalTime();
        }
        return t.ToString(pattern, CultureInfo.InvariantCulture);
    }
}
