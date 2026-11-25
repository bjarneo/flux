using System.Text.Json.Nodes;

namespace FluxKit;

// The flux.desktop packets. This computer opens a TLS listener and sends
// "start" with its port, the longest side of the stream, and optionally a
// monitor. The Omarchy computer connects and writes frames, see
// DesktopFrameReader. It answers "live" with the monitor and the size,
// "error", or "stop". The mouse goes as flux.mousepad.request with a
// position. docs/remote-desktop.md describes the fields.
public static class DesktopPackets
{
    // The limits of the longest side of the stream, as fluxd has them.
    public const int MinSize = 640;
    public const int MaxSize = 3840;

    // The size that fluxd uses when this computer does not know its screen.
    public const int DefaultSize = 1920;

    // The longest side of the stream for a screen with this longest side in
    // pixels, from MinSize to MaxSize.
    public static int Size(int screenPixels) =>
        screenPixels <= 0 ? DefaultSize : Math.Min(MaxSize, Math.Max(MinSize, screenPixels));

    public static Packet Start(int port, string? monitor = null, int maxSize = DefaultSize, bool audio = false)
    {
        var body = new JsonObject { ["state"] = "start", ["port"] = port, ["maxSize"] = maxSize };
        if (!string.IsNullOrEmpty(monitor))
        {
            body["monitor"] = monitor;
        }
        if (audio)
        {
            body["audio"] = true;
        }
        return new Packet(PacketType.Desktop, body);
    }

    public static Packet Stop() => new(PacketType.Desktop, new JsonObject { ["state"] = "stop" });
}

// An answer from the computer.
public abstract record DesktopReply
{
    // The computer streams Monitor at Width × Height. Monitors are all the
    // monitors that it can stream.
    public sealed record Live(string Monitor, IReadOnlyList<string> Monitors, int Width, int Height) : DesktopReply
    {
        public bool Equals(Live? other) =>
            other is not null && Monitor == other.Monitor && Monitors.SequenceEqual(other.Monitors) && Width == other.Width && Height == other.Height;

        public override int GetHashCode() => HashCode.Combine(Monitor, Width, Height);
    }

    public sealed record Failed(string Message) : DesktopReply;

    // The user stopped the stream on the computer.
    public sealed record Stop() : DesktopReply;

    // Parses a flux.desktop packet. It returns null for other packets and
    // unknown states.
    public static DesktopReply? Parse(Packet p)
    {
        if (p.Type != PacketType.Desktop)
        {
            return null;
        }
        switch (p.String("state"))
        {
            case "live":
                return new Live(p.String("monitor") ?? "", p.Strings("monitors"), p.Int("width") ?? 0, p.Int("height") ?? 0);
            case "error":
                var message = p.String("message") ?? "";
                return new Failed(message.Length == 0 ? "The computer could not stream its screen" : message);
            case "stop":
                return new Stop();
            default:
                return null;
        }
    }
}

// 1 frame of the stream. Data is H.264 in Annex-B form with 4-byte start
// codes, the video size for a format frame, or PCM for an audio frame.
public sealed class DesktopFrame(byte flags, byte[] data) : IEquatable<DesktopFrame>
{
    // The SPS and the PPS.
    public const byte Config = 1;

    // A frame that a decoder can start at.
    public const byte Key = 2;

    // The video size: the width and the height as 2 big-endian 16-bit
    // numbers.
    public const byte Format = 4;

    // 20 ms of stereo, 48 kHz, signed 16-bit little-endian PCM.
    public const byte Audio = 8;

    public byte Flags { get; } = flags;
    public byte[] Data { get; } = data;

    public bool IsConfig => (Flags & Config) != 0;
    public bool IsKey => (Flags & Key) != 0;
    public bool IsFormat => (Flags & Format) != 0;
    public bool IsAudio => Flags == Audio;

    // The width and the height of a format frame.
    public (int Width, int Height)? Size =>
        IsFormat && Data.Length >= 4 ? (Data[0] << 8 | Data[1], Data[2] << 8 | Data[3]) : null;

    public bool Equals(DesktopFrame? other) => other is not null && Flags == other.Flags && Data.AsSpan().SequenceEqual(other.Data);
    public override bool Equals(object? obj) => obj is DesktopFrame f && Equals(f);
    public override int GetHashCode() => HashCode.Combine(Flags, Data.Length);
}

// Reads the frames that the computer writes: the size of the data as a
// big-endian 32-bit number, 1 byte of flags, and the data. The size comes
// first, so a frame is complete as soon as its last byte arrives. The
// network gives the bytes in pieces of any size.
public sealed class DesktopFrameReader(int maxFrame = DesktopFrameReader.DefaultMaxFrame)
{
    public const int DefaultMaxFrame = 16 << 20;

    byte[] buffer = new byte[64 * 1024];
    // The first byte of buffer that no frame has used yet, and the end of
    // the data in buffer.
    int start;
    int end;

    // Adds the bytes and returns the frames that are complete. It throws
    // InvalidDataException for a frame that is larger than the limit.
    public IReadOnlyList<DesktopFrame> Push(ReadOnlySpan<byte> bytes)
    {
        Append(bytes);
        var frames = new List<DesktopFrame>();
        while (end - start >= 5)
        {
            var size = (long)buffer[start] << 24 | (long)buffer[start + 1] << 16 | (long)buffer[start + 2] << 8 | buffer[start + 3];
            if (size > maxFrame)
            {
                throw new InvalidDataException($"A frame of {size} bytes is too large");
            }
            if (end - start < 5 + size)
            {
                break;
            }
            frames.Add(new DesktopFrame(buffer[start + 4], buffer.AsSpan(start + 5, (int)size).ToArray()));
            start += 5 + (int)size;
        }
        if (start == end)
        {
            start = 0;
            end = 0;
        }
        return frames;
    }

    void Append(ReadOnlySpan<byte> bytes)
    {
        if (end + bytes.Length > buffer.Length)
        {
            // Drop the used bytes first, then grow when the rest still does
            // not fit.
            var used = end - start;
            var target = used + bytes.Length > buffer.Length ? new byte[Math.Max(buffer.Length * 2, used + bytes.Length)] : buffer;
            Buffer.BlockCopy(buffer, start, target, 0, used);
            buffer = target;
            start = 0;
            end = used;
        }
        bytes.CopyTo(buffer.AsSpan(end));
        end += bytes.Length;
    }
}

// H.264 helpers for the frames of the computer.
public static class DesktopH264
{
    internal const byte NalSps = 7;
    internal const byte NalPps = 8;
    internal const byte NalAud = 9;

    // The offsets of the first byte after each start code in b.
    internal static List<int> NalStarts(ReadOnlySpan<byte> b)
    {
        var output = new List<int>();
        var i = 0;
        while (i + 2 < b.Length)
        {
            if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1)
            {
                output.Add(i + 3);
                i += 3;
            }
            else
            {
                i++;
            }
        }
        return output;
    }

    // The NAL units of Annex-B data, without the start codes.
    internal static List<ArraySegment<byte>> Units(byte[] b)
    {
        var starts = NalStarts(b);
        var output = new List<ArraySegment<byte>>();
        for (var i = 0; i < starts.Count; i++)
        {
            var start = starts[i];
            if (start >= b.Length)
            {
                continue;
            }
            // The unit ends at the start code of the next unit, without the
            // zero bytes before it.
            var end = i + 1 < starts.Count ? starts[i + 1] - 3 : b.Length;
            while (end > start && b[end - 1] == 0)
            {
                end--;
            }
            if (end > start)
            {
                output.Add(new ArraySegment<byte>(b, start, end - start));
            }
        }
        return output;
    }

    // The first SPS and the first PPS of a config frame or a key frame,
    // without start codes. It returns null when 1 of them is missing.
    public static (byte[] Sps, byte[] Pps)? ParameterSets(byte[] data)
    {
        byte[]? sps = null;
        byte[]? pps = null;
        foreach (var unit in Units(data))
        {
            switch (unit[0] & 0x1F)
            {
                case NalSps when sps is null:
                    sps = unit.ToArray();
                    break;
                case NalPps when pps is null:
                    pps = unit.ToArray();
                    break;
            }
        }
        return sps is not null && pps is not null ? (sps, pps) : null;
    }

    // Turns Annex-B data into AVCC: each NAL unit with a 4-byte length in
    // front. It drops the parameter sets and the access unit delimiters,
    // because the format of the decoder holds the parameter sets. A decoder
    // that takes Annex-B, such as the H.264 decoder of Media Foundation,
    // does not need it.
    public static byte[] Avcc(byte[] data)
    {
        var output = new List<byte>(data.Length);
        foreach (var unit in Units(data))
        {
            var type = unit[0] & 0x1F;
            if (type is NalSps or NalPps or NalAud)
            {
                continue;
            }
            var n = (uint)unit.Count;
            output.Add((byte)(n >> 24));
            output.Add((byte)(n >> 16 & 0xFF));
            output.Add((byte)(n >> 8 & 0xFF));
            output.Add((byte)(n & 0xFF));
            output.AddRange(unit);
        }
        return output.ToArray();
    }
}

// A position on the remote desktop, from 0 at the top left corner to 1 at
// the bottom right corner of the monitor.
public readonly record struct DesktopPoint(double X, double Y);

// Where the video shows in its view. The video keeps its shape, fills the
// view in 1 direction, and has bars in the other direction. The view uses a
// top left origin.
public readonly record struct DesktopGeometry(RemoteSize View, RemoteSize Video)
{
    // The view points for 1 video pixel.
    public double Scale =>
        Video.Width > 0 && Video.Height > 0 ? Math.Min(View.Width / Video.Width, View.Height / Video.Height) : 0;

    // The rectangle of the video in the view.
    public RemoteRect Fit
    {
        get
        {
            var s = Scale;
            var w = Video.Width * s;
            var h = Video.Height * s;
            return new RemoteRect((View.Width - w) / 2, (View.Height - h) / 2, w, h);
        }
    }

    // The position on the video for a point of the view. It returns null
    // for a point on the bars, unless clamp moves the point to the nearest
    // edge.
    public DesktopPoint? Position(RemotePoint p, bool clamp = false)
    {
        var f = Fit;
        if (!(f.Width > 0) || !(f.Height > 0))
        {
            return null;
        }
        var x = (p.X - f.MinX) / f.Width;
        var y = (p.Y - f.MinY) / f.Height;
        if (clamp)
        {
            return new DesktopPoint(Math.Min(Math.Max(x, 0), 1), Math.Min(Math.Max(y, 0), 1));
        }
        if (!(x >= 0 && x <= 1 && y >= 0 && y <= 1))
        {
            return null;
        }
        return new DesktopPoint(x, y);
    }
}

// Limits the pointer motion over the video to 1 packet each interval. The
// last position of a fast motion waits and goes out with Flush. Times are
// in seconds.
public sealed class DesktopMotionThrottle(double interval = 1.0 / 60)
{
    double sentAt = double.NegativeInfinity;
    DesktopPoint? sent;

    public double Interval { get; } = interval;
    public DesktopPoint? Pending { get; private set; }

    // Returns the position to send now, or null when it waits or did not
    // change.
    public DesktopPoint? Move(DesktopPoint p, double now)
    {
        if (p == sent)
        {
            Pending = null;
            return null;
        }
        if (now - sentAt < Interval)
        {
            Pending = p;
            return null;
        }
        Pending = null;
        sent = p;
        sentAt = now;
        return p;
    }

    // Returns the waiting position when its time came.
    public DesktopPoint? Flush(double now)
    {
        if (Pending is not { } p || now - sentAt < Interval)
        {
            return null;
        }
        return Move(p, now);
    }

    // Forgets the waiting position and the last position, for example after
    // a click.
    public void Reset(DesktopPoint? sentPoint = null, double now = double.NegativeInfinity)
    {
        Pending = null;
        sent = sentPoint;
        sentAt = now;
    }
}

// Turns the left button over the video into packets with positions. A
// press that moves is a drag: singlehold at the press, the motion, then
// singlerelease. A press that does not move clicks. The second click of a
// double click goes to the position of the first click, so that the
// computer sees a double click.
public sealed class DesktopPointer
{
    // The motion in view points after which a press becomes a drag.
    public const double DragSlop = 3.0;

    // The largest distance in view points between the 2 clicks of a double
    // click.
    public const double DoubleClickDistance = 6.0;

    (RemotePoint Point, DesktopPoint At)? press;
    (RemotePoint Point, DesktopPoint At)? lastClick;

    public bool Dragging { get; private set; }

    public bool Pressed => press is not null;

    public void LeftDown(RemotePoint point, DesktopPoint at)
    {
        press = (point, at);
        Dragging = false;
    }

    // The packets for a motion of the pressed button.
    public IReadOnlyList<Packet> LeftDragged(RemotePoint point, DesktopPoint at)
    {
        if (press is not { } p)
        {
            return [];
        }
        if (!Dragging)
        {
            if (double.Hypot(point.X - p.Point.X, point.Y - p.Point.Y) < DragSlop)
            {
                return [];
            }
            Dragging = true;
            return [RemoteInput.HoldAt(true, p.At.X, p.At.Y), RemoteInput.At(at.X, at.Y)];
        }
        return [RemoteInput.At(at.X, at.Y)];
    }

    // The packets for the release. clickCount is 2 or more for the second
    // click of a double click.
    public IReadOnlyList<Packet> LeftUp(RemotePoint point, DesktopPoint at, int clickCount)
    {
        var current = press;
        var dragging = Dragging;
        press = null;
        Dragging = false;
        if (current is not { } p)
        {
            return [];
        }
        if (dragging)
        {
            lastClick = null;
            return [RemoteInput.HoldAt(false, at.X, at.Y)];
        }
        var target = p.At;
        if (clickCount >= 2 && lastClick is { } last &&
            double.Hypot(p.Point.X - last.Point.X, p.Point.Y - last.Point.Y) < DoubleClickDistance)
        {
            target = last.At;
        }
        lastClick = (p.Point, target);
        return [RemoteInput.ClickAt(RemoteClick.Left, target.X, target.Y)];
    }

    // Ends a press without a click. A drag releases the button at at.
    public IReadOnlyList<Packet> Cancel(DesktopPoint? at)
    {
        var current = press;
        var dragging = Dragging;
        press = null;
        Dragging = false;
        if (!dragging || (at ?? current?.At) is not { } p)
        {
            return [];
        }
        return [RemoteInput.HoldAt(false, p.X, p.Y)];
    }
}
