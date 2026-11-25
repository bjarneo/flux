using System.Text;

namespace FluxKit;

// Reads the structured content of a code. The decoder gives only the raw
// value, so this does what ML Kit does for Flux for Android: it finds Wi-Fi
// networks with WIFI:, contacts with vCard and MECARD:, and bookmarks with
// MEBKM:.
// CodeContent.swift of the Mac app has the same rules.
public static class CodeContent
{
    // Returns the code with its content fields set.
    public static ScannedCode Parse(CodeFormat format, string raw)
    {
        var lower = raw.ToLowerInvariant();
        if (lower.StartsWith("wifi:", StringComparison.Ordinal))
        {
            return new ScannedCode(format, raw, Wifi: Wifi(raw));
        }
        if (lower.StartsWith("begin:vcard", StringComparison.Ordinal))
        {
            return new ScannedCode(format, raw, Contact: VCard(raw));
        }
        if (lower.StartsWith("mecard:", StringComparison.Ordinal))
        {
            return new ScannedCode(format, raw, Contact: MeCard(raw));
        }
        if (lower.StartsWith("mebkm:", StringComparison.Ordinal) && Fields(raw[6..]).TryGetValue("URL", out var urls) && urls[0].Length > 0)
        {
            return new ScannedCode(format, raw, Url: urls[0]);
        }
        return new ScannedCode(format, raw);
    }

    // Reads WIFI:S:<ssid>;T:<WPA|WEP|nopass>;P:<password>;;.
    internal static WifiInfo Wifi(string raw)
    {
        var f = Fields(raw[5..]);
        var type = First(f, "T").ToUpperInvariant();
        var security = type switch
        {
            "WEP" => "WEP",
            "" or "NOPASS" => "open",
            _ => "WPA",
        };
        return new WifiInfo(First(f, "S"), First(f, "P"), security);
    }

    // Reads MECARD:N:Kim,Dan;TEL:…;EMAIL:…;ORG:…;;. The name is "Last,First".
    internal static ContactInfo MeCard(string raw)
    {
        var f = Fields(raw[7..]);
        var parts = First(f, "N").Split(',').Select(p => p.Trim(' ', '\t'));
        var name = string.Join(' ', parts.Reverse().Where(p => p.Length > 0));
        return new ContactInfo(name, f.GetValueOrDefault("TEL") ?? [], f.GetValueOrDefault("EMAIL") ?? [], First(f, "ORG"));
    }

    // Reads the FN, N, TEL, EMAIL, and ORG lines of a vCard.
    internal static ContactInfo VCard(string raw)
    {
        // Folded lines continue with a space or a tab.
        var unfolded = raw.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace("\n ", "", StringComparison.Ordinal)
            .Replace("\n\t", "", StringComparison.Ordinal);
        string fn = "", n = "", org = "";
        var phones = new List<string>();
        var emails = new List<string>();
        foreach (var line in unfolded.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var colon = line.IndexOf(':', StringComparison.Ordinal);
            if (colon < 0)
            {
                continue;
            }
            // The property name comes before any parameter, as in "TEL;TYPE=CELL".
            var key = line[..colon].Split(';', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToUpperInvariant() ?? "";
            var name = key.Split('.', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? key;
            var value = Unescape(line[(colon + 1)..]).Trim(' ', '\t');
            switch (name)
            {
                case "FN":
                    fn = value;
                    break;
                case "N":
                    n = value;
                    break;
                case "ORG":
                    org = value.Split(';', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? value;
                    break;
                case "TEL" when value.Length > 0:
                    phones.Add(value);
                    break;
                case "EMAIL" when value.Length > 0:
                    emails.Add(value);
                    break;
            }
        }
        if (fn.Length == 0)
        {
            // N is Last;First;Middle;Prefix;Suffix.
            var p = n.Split(';');
            string At(int i) => p.Length > i ? p[i] : "";
            fn = string.Join(' ', new[] { At(3), At(1), At(2), At(0), At(4) }.Where(s => s.Length > 0));
        }
        return new ContactInfo(fn, phones, emails, org);
    }

    // Splits KEY:value;KEY:value;; into values by key. A backslash escapes
    // the next character, so \; stays in the value.
    internal static Dictionary<string, List<string>> Fields(string text)
    {
        var output = new Dictionary<string, List<string>>();
        var part = new StringBuilder();
        var escaped = false;
        void Flush()
        {
            var s = part.ToString();
            var colon = s.IndexOf(':', StringComparison.Ordinal);
            if (colon >= 0)
            {
                var key = s[..colon].ToUpperInvariant();
                if (!output.TryGetValue(key, out var list))
                {
                    list = [];
                    output[key] = list;
                }
                list.Add(s[(colon + 1)..]);
            }
            part.Clear();
        }
        foreach (var c in text)
        {
            if (escaped)
            {
                part.Append(c);
                escaped = false;
            }
            else if (c == '\\')
            {
                escaped = true;
            }
            else if (c == ';')
            {
                Flush();
            }
            else
            {
                part.Append(c);
            }
        }
        Flush();
        return output;
    }

    static string First(Dictionary<string, List<string>> fields, string key) =>
        fields.TryGetValue(key, out var list) && list.Count > 0 ? list[0] : "";

    static string Unescape(string value) => value
        .Replace("\\n", " ", StringComparison.Ordinal)
        .Replace("\\N", " ", StringComparison.Ordinal)
        .Replace("\\,", ",", StringComparison.Ordinal)
        .Replace("\\;", ";", StringComparison.Ordinal);
}
