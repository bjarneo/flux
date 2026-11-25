using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Authentication;

namespace FluxKit;

// The phase of a stream to a computer: the webcam, the microphone, or the
// screen mirror.
public enum StreamPhase
{
    Idle,

    // This computer waits for the computer to connect.
    Connecting,

    // The computer connected. This computer waits for the report that the
    // computer plays the stream.
    Starting,

    Live,
    Error,
}

// The state of a stream for the UI. StreamStatus.swift of the Mac app has
// the same fields. The microphone uses it too.
public sealed record StreamStatus(StreamPhase Phase = StreamPhase.Idle, string Message = "", string? DeviceId = null)
{
    // No stream, and no message.
    public static readonly StreamStatus None = new();

    // True while the stream runs or starts.
    public bool Active => Phase is StreamPhase.Connecting or StreamPhase.Starting or StreamPhase.Live;

    // True while a stream to the computer with the ID runs or starts.
    public bool ActiveFor(string deviceId) => Active && DeviceId == deviceId;

    // The message of an error, or null in the other phases.
    public string? Error => Phase == StreamPhase.Error ? Message : null;
}

// A failure of a stream, with a message for the user. The platform
// interfaces of the streams throw it, and the stream shows the message.
public sealed class StreamException : Exception
{
    public StreamException(string message)
        : base(message)
    {
    }

    public StreamException(string message, Exception inner)
        : base(message, inner)
    {
    }
}

// The failures that end a stream. A stream catches only these. A platform
// interface throws StreamException, or an ExternalException such as the
// COMException of Media Foundation or WASAPI.
internal static class StreamErrors
{
    public static bool Expected(Exception e) => e is StreamException or IOException or TimeoutException or
        OperationCanceledException or ObjectDisposedException or SocketException or AuthenticationException or
        ExternalException or InvalidOperationException or UnauthorizedAccessException or NotSupportedException;

    // The message for the user. A StreamException has one. Another failure
    // gives its own message, or fallback when it has none.
    public static string Message(Exception e, string fallback) => e switch
    {
        StreamException s => s.Message,
        TimeoutException or OperationCanceledException or ObjectDisposedException => fallback,
        _ when e.Message.Length > 0 => e.Message,
        _ => fallback,
    };
}

// The steps that the webcam, the microphone, and the screen mirror share.
internal static class StreamPeer
{
    sealed record Peer(bool Accepts, byte[]? Certificate);

    // Returns the certificate of the paired computer for a stream of the
    // packet type. It throws StreamException when the computer is not
    // known, cannot take the stream, or has no link.
    public static byte[] Certificate(FluxCore core, string deviceId, string name, string type, string updateText)
    {
        // The core lock guards the fields of the device.
        var peer = core.WithDevice(deviceId, d => new Peer(d.Accepts(type), d.Certificate));
        if (peer is null)
        {
            throw new StreamException($"{name} is not known");
        }
        if (!peer.Accepts)
        {
            throw new StreamException(updateText);
        }
        return peer.Certificate ?? throw new StreamException($"{name} is not connected");
    }

    // Waits for the computer to connect to the listener. The computer
    // connects out, so that the stream passes a firewall that blocks
    // incoming traffic on the computer. The listener closes a connection
    // with another certificate and waits on.
    public static async Task<TlsStream> AcceptAsync(PayloadServer server, TimeSpan timeout, string name)
    {
        try
        {
            return await server.AcceptAsync(timeout).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            throw new StreamException($"{name} did not connect. Update Flux on the computer.");
        }
    }
}
