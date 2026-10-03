using System.Text.Json;

namespace Flux.Protocol;

// The small set of desktop roles used by the WPF shell. Colors are opaque RGB.
public sealed record OmarchyTheme(string Name, int Background, int Tile, int TileHi, int Line,
    int Text, int Sub, int Accent, int Green, int Red)
{
    public static bool TryParse(JsonElement body, out OmarchyTheme? theme)
    {
        theme = null;
        if (body.ValueKind != JsonValueKind.Object || !body.TryGetProperty("colors", out var colors) ||
            colors.ValueKind != JsonValueKind.Object || colors.EnumerateObject().Count() > 64) return false;
        var parsed = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var item in colors.EnumerateObject()) {
            if (item.Name.Length is < 1 or > 32 || item.Name.Any(c => c is not (>= 'a' and <= 'z') and not (>= '0' and <= '9') and not '_') ||
                item.Value.ValueKind != JsonValueKind.String || !TryColor(item.Value.GetString(), out var color)) continue;
            parsed[item.Name] = color;
        }
        if (!parsed.TryGetValue("background", out var bg) || !parsed.TryGetValue("foreground", out var fg)) return false;
        var dark = Contrast(bg, 0xFFFFFF) >= Contrast(bg, 0);
        var name = body.TryGetProperty("name", out var label) && label.ValueKind == JsonValueKind.String
            ? (label.GetString() ?? "")[..Math.Min(label.GetString()!.Length, 64)] : "";
        int Get(string key, int fallback) => parsed.GetValueOrDefault(key, fallback);
        var tile = SafeSurface(Get("dark_background", Mix(bg, 0, .2)), bg, dark);
        var hi = SafeSurface(Get("selection", Mix(bg, fg, .12)), bg, dark);
        var line = SafeSurface(Mix(hi, fg, .15), bg, dark);
        var surfaces = new[] { bg, tile, hi, line };
        int Ink(int raw, double ratio) => Guard(raw, surfaces, ratio, dark);
        var text = Ink(fg, 4.5);
        var sub = Ink(Get("muted", Mix(bg, fg, .6)), 4.5);
        var accent = Ink(Get("accent", Get("blue", 0x7AA2F7)), 4.5);
        var green = Ink(Get("green", accent), 4.5);
        var red = Ink(Get("red", accent), 4.5);
        theme = new(name, bg, tile, hi, line, text, sub, accent, green, red);
        return true;
    }

    private static bool TryColor(string? value, out int color)
    {
        color = 0;
        return value is { Length: 7 } && value[0] == '#' &&
            int.TryParse(value.AsSpan(1), System.Globalization.NumberStyles.HexNumber,
                System.Globalization.CultureInfo.InvariantCulture, out color);
    }

    private static int Mix(int a, int b, double t)
    {
        int Channel(int shift) => (int)Math.Round(((a >> shift) & 255) * (1 - t) + ((b >> shift) & 255) * t);
        return Channel(16) << 16 | Channel(8) << 8 | Channel(0);
    }

    private static double Luminance(int color)
    {
        static double Linear(int channel) {
            var v = channel / 255d;
            return v <= .04045 ? v / 12.92 : Math.Pow((v + .055) / 1.055, 2.4);
        }
        return .2126 * Linear((color >> 16) & 255) + .7152 * Linear((color >> 8) & 255) +
            .0722 * Linear(color & 255);
    }

    public static double Contrast(int a, int b)
    {
        var x = Luminance(a); var y = Luminance(b);
        return (Math.Max(x, y) + .05) / (Math.Min(x, y) + .05);
    }

    private static int Guard(int color, int[] surfaces, double ratio, bool lighten)
    {
        if (surfaces.All(surface => Contrast(color, surface) >= ratio)) return color;
        var extreme = lighten ? 0xFFFFFF : 0;
        for (var step = 1; step <= 100; step++) {
            var candidate = Mix(color, extreme, step / 100d);
            if (surfaces.All(surface => Contrast(candidate, surface) >= ratio)) return candidate;
        }
        // An impossible set of surfaces is safer with a readable neutral ink.
        return extreme;
    }

    private static int SafeSurface(int color, int background, bool lightInk)
    {
        var ink = lightInk ? 0xFFFFFF : 0;
        if (Contrast(color, ink) >= 4.5) return color;
        for (var step = 1; step <= 100; step++) {
            var candidate = Mix(color, background, step / 100d);
            if (Contrast(candidate, ink) >= 4.5) return candidate;
        }
        return background;
    }
}
