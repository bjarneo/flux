using System.Text.Json.Nodes;

namespace FluxKit;

// The flux.webcam packets. This computer opens a TLS listener, sends "start"
// with its port, and writes a raw H.264 Annex-B stream to the computer that
// connects. The computer answers "live", "error", or "stop". Both sides send
// "config" to change the settings. StreamProtocol.swift of the Mac app and
// internal/core/webcam.go are the reference.
public static class WebcamPackets
{
    public const int Fps = 30;
    public const string Codec = "h264";

    public static Packet Start(int port, int width, int height) => new(PacketType.Webcam, new JsonObject
    {
        ["state"] = "start",
        ["port"] = port,
        ["width"] = width,
        ["height"] = height,
        ["fps"] = Fps,
        ["codec"] = Codec,
    });

    public static Packet Stop() => new(PacketType.Webcam, new JsonObject { ["state"] = "stop" });

    // The full settings and what the camera supports. This computer sends it
    // after "start" and after each change.
    public static Packet Config(WebcamConfig config, WebcamCaps caps) => new(PacketType.Webcam, new JsonObject
    {
        ["state"] = "config",
        ["config"] = config.Json(),
        ["caps"] = caps.Json(),
    });
}

// An answer from the computer to the webcam.
public abstract record WebcamReply
{
    // Frames reach the virtual camera device. Apps see it with the name Label.
    public sealed record Live(string Device, string Label) : WebcamReply;

    public sealed record Failed(string Message) : WebcamReply;

    // The user stopped the camera on the computer.
    public sealed record Stop : WebcamReply;

    // The computer changes settings. With Reset, the neutral image values
    // apply first, and then the fields of Partial.
    public sealed record Config(JsonObject? Partial, bool Reset) : WebcamReply;

    // Parses a flux.webcam packet. It returns null for other packets and
    // unknown states.
    public static WebcamReply? Parse(Packet p)
    {
        if (p.Type != PacketType.Webcam)
        {
            return null;
        }
        switch (p.String("state"))
        {
            case "live":
                return new Live(p.String("device") ?? "", NonEmpty(p.String("label")) ?? "Flux Camera");
            case "error":
                return new Failed(NonEmpty(p.String("message")) ?? "The computer could not start the camera");
            case "stop":
                return new Stop();
            case "config":
                var partial = p.Object("config");
                var reset = p.Bool("reset") == true;
                return partial is not null || reset ? new Config(partial, reset) : null;
            default:
                return null;
        }
    }

    internal static string? NonEmpty(string? s) => string.IsNullOrEmpty(s) ? null : s;
}

// The flux.screen packets. This computer opens a TLS listener, sends "start"
// with its port and the frame size, and writes a raw H.264 Annex-B stream of
// a display to the computer that connects. The computer answers "live",
// "error", or "stop". The computer only shows the screen.
public static class ScreenPackets
{
    public static Packet Start(int port, int width, int height) => new(PacketType.Screen, new JsonObject
    {
        ["state"] = "start",
        ["port"] = port,
        ["width"] = width,
        ["height"] = height,
        ["codec"] = WebcamPackets.Codec,
    });

    public static Packet Stop() => new(PacketType.Screen, new JsonObject { ["state"] = "stop" });
}

// An answer from the computer to the screen mirror.
public abstract record ScreenReply
{
    // The computer shows the stream in the player, such as mpv.
    public sealed record Live(string Player) : ScreenReply;

    public sealed record Failed(string Message) : ScreenReply;

    // The user closed the window or stopped the mirror on the computer.
    public sealed record Stop : ScreenReply;

    // Parses a flux.screen packet. It returns null for other packets and
    // unknown states.
    public static ScreenReply? Parse(Packet p)
    {
        if (p.Type != PacketType.Screen)
        {
            return null;
        }
        return p.String("state") switch
        {
            "live" => new Live(p.String("player") ?? ""),
            "error" => new Failed(WebcamReply.NonEmpty(p.String("message")) ?? "The computer could not show the screen"),
            "stop" => new Stop(),
            _ => null,
        };
    }
}

// The frame size and the bitrate of the screen mirror.
public static class MirrorSize
{
    // The longest side of the stream, in pixels.
    public const int MaxLong = 1080;

    // Returns the encoder size for a screen of width x height pixels: the
    // same shape, at most maxLong pixels on the long side, and both sides a
    // multiple of align, as hardware encoders want. It returns null for a
    // size that is not positive.
    public static (int Width, int Height)? Fit(int width, int height, int maxLong = MaxLong, int align = 16)
    {
        if (width <= 0 || height <= 0)
        {
            return null;
        }
        var scale = Math.Min(1.0, (double)maxLong / Math.Max(width, height));
        int Down(int v) => Math.Max(align, (int)(v * scale) / align * align);
        return (Down(width), Down(height));
    }

    // Returns the bitrate for a frame size. Screen text needs more bits than
    // a camera image.
    public static int Bitrate(int width, int height) =>
        (int)Math.Min(int.MaxValue, Math.Max(2_000_000L, (long)width * height * 8));
}
