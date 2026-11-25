using System.Buffers.Binary;
using System.Text.Json.Nodes;

namespace FluxKit;

// The flux.mic packets. This computer opens a TLS listener, sends "start"
// with its port and the audio format, and writes raw PCM to the computer
// that connects. The computer answers "live", "error", or "stop".
// MicProtocol.swift of the Mac app and internal/core/mic.go are the
// reference.
public static class MicPackets
{
    public const int Rate = 48_000;
    public const int Channels = 1;
    public const string Format = "s16le";

    public static Packet Start(int port) => new(PacketType.Mic, new JsonObject
    {
        ["state"] = "start",
        ["port"] = port,
        ["rate"] = Rate,
        ["channels"] = Channels,
        ["format"] = Format,
    });

    public static Packet Stop() => new(PacketType.Mic, new JsonObject { ["state"] = "stop" });
}

// An answer from the computer to the microphone.
public abstract record MicReply
{
    // The audio reaches the virtual source with this name.
    public sealed record Live(string Source) : MicReply;

    public sealed record Failed(string Message) : MicReply;

    // The user stopped the microphone on the computer.
    public sealed record Stop : MicReply;

    // Parses a flux.mic packet. It returns null for other packets and unknown
    // states.
    public static MicReply? Parse(Packet p)
    {
        if (p.Type != PacketType.Mic)
        {
            return null;
        }
        return p.String("state") switch
        {
            "live" => new Live(NonEmpty(p.String("source")) ?? "Flux Microphone"),
            "error" => new Failed(NonEmpty(p.String("message")) ?? "The computer could not start the microphone"),
            "stop" => new Stop(),
            _ => null,
        };
    }

    static string? NonEmpty(string? s) => string.IsNullOrEmpty(s) ? null : s;
}

// Helpers for 16-bit PCM.
public static class Pcm
{
    // Writes the samples to output in little-endian order, 2 bytes each.
    // output holds at least 2 bytes per sample.
    public static void ToLittleEndian(ReadOnlySpan<short> samples, Span<byte> output)
    {
        if (output.Length < samples.Length * 2)
        {
            throw new ArgumentException("the output is too small", nameof(output));
        }
        for (var i = 0; i < samples.Length; i++)
        {
            BinaryPrimitives.WriteInt16LittleEndian(output[(2 * i)..], samples[i]);
        }
    }

    // Returns the samples in little-endian order, 2 bytes each.
    public static byte[] ToLittleEndian(ReadOnlySpan<short> samples)
    {
        var bytes = new byte[samples.Length * 2];
        ToLittleEndian(samples, bytes);
        return bytes;
    }

    // Returns the peak of the samples, from 0 for silence to 1 for full scale.
    public static float Peak(ReadOnlySpan<short> samples)
    {
        var m = 0;
        foreach (var s in samples)
        {
            m = Math.Max(m, Math.Abs((int)s));
        }
        return Math.Clamp(m / 32768f, 0, 1);
    }
}
