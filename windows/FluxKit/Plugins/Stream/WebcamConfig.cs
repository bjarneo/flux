using System.Globalization;
using System.Text.Json.Nodes;

namespace FluxKit;

// The webcam settings. This computer and the computer that gets the stream
// can both change them. Aspect, Resolution, and Camera set the stream. The
// other fields change the image while it streams. The field names are the
// keys of the flux.webcam "config" object. WebcamConfig.swift of the Mac app
// has the same rules, and docs/camera.md lists the values.
public sealed record WebcamConfig
{
    // The frame shapes that the webcam offers, as width:height.
    public static readonly ValueList<string> Aspects = new(["16:9", "4:3", "1:1", "9:16"]);

    // The short side of the frame, in pixels.
    public static readonly ValueList<int> Resolutions = new([720, 1080]);

    public string Aspect { get; init; } = "16:9";
    public int Resolution { get; init; } = 720;
    public string Camera { get; init; } = "back";
    public bool Mirror { get; init; }
    public double Zoom { get; init; } = 1;
    public double Exposure { get; init; }
    public string WhiteBalance { get; init; } = "auto";
    public double Brightness { get; init; }
    public double Contrast { get; init; } = 1;
    public double Saturation { get; init; } = 1;
    public double Warmth { get; init; }

    public int Width => FrameSize(Aspect, Resolution).Width;
    public int Height => FrameSize(Aspect, Resolution).Height;
    public int Bitrate => BitrateFor(Width, Height);

    // Returns the config with the fields of partial applied. A field with the
    // wrong type or a value that is not a finite number is ignored.
    public WebcamConfig Merged(JsonObject? partial)
    {
        if (partial is null)
        {
            return this;
        }
        // A resolution outside 1 to 10000 pixels is not a value that a camera
        // has. The clamp to the caps picks the next valid value.
        var resolution = Number(partial, "resolution") is { } r && r >= 1 && r <= 10_000 ? (int)Rounding.HalfUp(r) : Resolution;
        return this with
        {
            Aspect = Text(partial, "aspect") ?? Aspect,
            Resolution = resolution,
            Camera = Text(partial, "camera")?.ToLowerInvariant() ?? Camera,
            Mirror = Flag(partial, "mirror") ?? Mirror,
            Zoom = Number(partial, "zoom") ?? Zoom,
            Exposure = Number(partial, "exposure") ?? Exposure,
            WhiteBalance = Text(partial, "whiteBalance")?.ToLowerInvariant() ?? WhiteBalance,
            Brightness = Number(partial, "brightness") ?? Brightness,
            Contrast = Number(partial, "contrast") ?? Contrast,
            Saturation = Number(partial, "saturation") ?? Saturation,
            Warmth = Number(partial, "warmth") ?? Warmth,
        };
    }

    // Returns the config with each field inside the limits of caps.
    public WebcamConfig Clamped(WebcamCaps caps)
    {
        var evMin = Math.Min(caps.ExposureMin, caps.ExposureMax);
        var evMax = Math.Max(caps.ExposureMin, caps.ExposureMax);
        var ev = Limited(Exposure, evMin, evMax);
        if (caps.ExposureStep > 0)
        {
            ev = Limited(Rounding.HalfUp(ev / caps.ExposureStep) * caps.ExposureStep, evMin, evMax);
        }
        // The distance in double cannot overflow, also for a resolution that
        // Update gets from a caller. The small range keeps the double exact,
        // so a huge resolution gives the largest one in caps.
        var r = (double)Math.Min(Math.Max(Resolution, 0), 1 << 20);
        int? nearest = null;
        foreach (var candidate in caps.Resolutions)
        {
            if (nearest is not { } best || Math.Abs(candidate - r) < Math.Abs(best - r))
            {
                nearest = candidate;
            }
        }
        return this with
        {
            Aspect = caps.Aspects.Contains(Aspect) ? Aspect : caps.Aspects.FirstOrDefault() ?? "16:9",
            Resolution = nearest ?? 720,
            Camera = caps.Cameras.Contains(Camera) ? Camera : caps.Cameras.FirstOrDefault() ?? "back",
            Zoom = Round(Limited(Zoom, 1, Math.Max(1, caps.ZoomMax)), 100),
            Exposure = Round(ev, 1000),
            WhiteBalance = caps.WhiteBalance.Contains(WhiteBalance) ? WhiteBalance : "auto",
            Brightness = Round(Limited(Brightness, -1, 1), 100),
            Contrast = Round(Limited(Contrast, 0, 2), 100),
            Saturation = Round(Limited(Saturation, 0, 2), 100),
            Warmth = Round(Limited(Warmth, -1, 1), 100),
        };
    }

    // Returns the neutral image values. The shape, the quality, and the
    // camera stay.
    public WebcamConfig Reset() => new() { Aspect = Aspect, Resolution = Resolution, Camera = Camera };

    // Reports whether a change to next needs a new stream with a new frame size.
    public bool RestartsStream(WebcamConfig next) => Width != next.Width || Height != next.Height;

    // Returns the frame size for aspect with @short pixels on the short side.
    // Both sides are even, as H.264 needs. An unknown aspect is 16:9.
    public static (int Width, int Height) FrameSize(string aspect, int @short)
    {
        // Like the Swift code, the parts that are not numbers drop out, and
        // 2 numbers that remain make the aspect.
        var parts = aspect.Split(':')
            .Select(p => long.TryParse(p.Trim(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var v) ? v : (long?)null)
            .OfType<long>()
            .ToArray();
        var (a, b) = parts.Length == 2 && parts[0] > 0 && parts[1] > 0 ? (parts[0], parts[1]) : (16L, 9L);
        // The half stays inside half the int range, so the product cannot
        // overflow.
        static int Even(double v) => (int)Math.Clamp(Rounding.HalfUp(v / 2), int.MinValue / 2, int.MaxValue / 2) * 2;
        return a >= b
            ? (Even((double)@short * a / b), @short)
            : (@short, Even((double)@short * b / a));
    }

    // Returns the encoder bitrate for a frame size: 4 Mbit/s for 1280x720 and
    // 8 Mbit/s for 1920x1080, scaled by the number of pixels for other
    // shapes. A huge frame gives int.MaxValue.
    public static int BitrateFor(int width, int height)
    {
        var perPixel = Math.Min(width, height) >= 1080 ? 8_000_000.0 / (1920 * 1080) : 4_000_000.0 / (1280 * 720);
        return (int)Math.Clamp(Math.Max(1_000_000, Rounding.HalfUp((double)width * height * perPixel)), 0, int.MaxValue);
    }

    public JsonObject Json() => new()
    {
        ["aspect"] = Aspect,
        ["resolution"] = Resolution,
        ["camera"] = Camera,
        ["mirror"] = Mirror,
        ["zoom"] = Zoom,
        ["exposure"] = Exposure,
        ["whiteBalance"] = WhiteBalance,
        ["brightness"] = Brightness,
        ["contrast"] = Contrast,
        ["saturation"] = Saturation,
        ["warmth"] = Warmth,
    };

    static double Limited(double v, double low, double high) => Math.Min(Math.Max(v, low), high);

    static double Round(double v, double scale) => Rounding.HalfUp(v * scale) / scale;

    // A text value without the spaces around it, or null when it is empty or
    // not a string.
    static string? Text(JsonObject o, string key) => FluxKit.Json.String(o[key])?.Trim() is { Length: > 0 } t ? t : null;

    // A finite number, also as text, or null.
    static double? Number(JsonObject o, string key)
    {
        var node = o[key];
        var v = FluxKit.Json.Double(node);
        if (v is null && FluxKit.Json.String(node) is { } s &&
            double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed))
        {
            v = parsed;
        }
        return v is { } d && double.IsFinite(d) ? d : null;
    }

    // A bool, also as the text "true" or "false", or null.
    static bool? Flag(JsonObject o, string key)
    {
        var node = o[key];
        if (FluxKit.Json.Bool(node) is { } b)
        {
            return b;
        }
        return FluxKit.Json.String(node)?.Trim().ToLowerInvariant() switch
        {
            "true" => true,
            "false" => false,
            _ => null,
        };
    }
}

// What the current camera and the encoder support.
public sealed record WebcamCaps
{
    public double ZoomMax { get; init; } = 1;
    public double ExposureMin { get; init; }
    public double ExposureMax { get; init; }
    public double ExposureStep { get; init; }
    public ValueList<string> WhiteBalance { get; init; } = new(["auto"]);
    public ValueList<string> Cameras { get; init; } = new(["back"]);
    public ValueList<string> Aspects { get; init; } = WebcamConfig.Aspects;
    public ValueList<int> Resolutions { get; init; } = WebcamConfig.Resolutions;

    public JsonObject Json() => new()
    {
        ["zoomMax"] = ZoomMax,
        ["exposureMin"] = ExposureMin,
        ["exposureMax"] = ExposureMax,
        ["exposureStep"] = ExposureStep,
        ["whiteBalance"] = new JsonArray(WhiteBalance.Select(s => (JsonNode?)JsonValue.Create(s)).ToArray()),
        ["cameras"] = new JsonArray(Cameras.Select(s => (JsonNode?)JsonValue.Create(s)).ToArray()),
        ["aspects"] = new JsonArray(Aspects.Select(s => (JsonNode?)JsonValue.Create(s)).ToArray()),
        ["resolutions"] = new JsonArray(Resolutions.Select(r => (JsonNode?)JsonValue.Create(r)).ToArray()),
    };
}

// Rounding like Kotlin roundToInt, so that all Flux apps agree on the values.
public static class Rounding
{
    // Rounds halves up. Like roundToInt it saturates at the long range, and
    // NaN is 0, so that no value throws.
    public static long HalfUp(double v)
    {
        var r = Math.Floor(v + 0.5);
        if (double.IsNaN(r))
        {
            return 0;
        }
        // 2^63 does not fit a long, and -2^63 does.
        if (r >= 9223372036854775808.0)
        {
            return long.MaxValue;
        }
        if (r < -9223372036854775808.0)
        {
            return long.MinValue;
        }
        return (long)r;
    }
}
