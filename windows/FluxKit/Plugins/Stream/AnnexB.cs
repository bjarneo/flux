namespace FluxKit;

// Helpers for H.264 in Annex-B form: NAL units that start with 00 00 01 or
// 00 00 00 01. The computer reads the stream in this form. AnnexB.swift of
// the Mac app has the same rules.
public static class AnnexB
{
    public const byte NalIdr = 5;
    public const byte NalSps = 7;
    public const byte NalPps = 8;

    public static ReadOnlySpan<byte> StartCode => [0, 0, 0, 1];

    // Returns the offsets of the first byte after each start code in b.
    public static IReadOnlyList<int> NalStarts(ReadOnlySpan<byte> b)
    {
        var starts = new List<int>();
        var i = 0;
        while (i + 2 < b.Length)
        {
            if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1)
            {
                starts.Add(i + 3);
                i += 3;
            }
            else
            {
                i++;
            }
        }
        return starts;
    }

    // Returns the NAL unit types in b, in order.
    public static IReadOnlyList<byte> NalTypes(ReadOnlySpan<byte> b)
    {
        var types = new List<byte>();
        foreach (var start in NalStarts(b))
        {
            if (start < b.Length)
            {
                types.Add((byte)(b[start] & 0x1F));
            }
        }
        return types;
    }

    public static bool HasStartCode(ReadOnlySpan<byte> b) =>
        (b.Length >= 3 && b[0] == 0 && b[1] == 0 && b[2] == 1) ||
        (b.Length >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 1);

    // Returns b with a 4-byte start code in front, when it has none.
    public static byte[] WithStartCode(ReadOnlySpan<byte> b) => HasStartCode(b) ? b.ToArray() : [.. StartCode, .. b];

    // Turns NAL units with a big-endian length in front, as the MP4 form
    // writes them, into Annex-B form. headerLength is the size of each
    // length field. With 4-byte lengths the bytes change in place. It
    // returns false when a length runs past the end.
    public static bool ConvertLengthPrefixed(ref byte[] b, int headerLength)
    {
        if (headerLength is < 1 or > 4)
        {
            return false;
        }
        var units = new List<(int Start, int Length)>();
        var i = 0;
        while (i < b.Length)
        {
            if (i + headerLength > b.Length)
            {
                return false;
            }
            long length = 0;
            for (var k = 0; k < headerLength; k++)
            {
                length = length << 8 | b[i + k];
            }
            var start = i + headerLength;
            if (length > b.Length - start)
            {
                return false;
            }
            units.Add((start, (int)length));
            i = start + (int)length;
        }
        if (headerLength == 4)
        {
            foreach (var (start, _) in units)
            {
                StartCode.CopyTo(b.AsSpan(start - 4));
            }
            return true;
        }
        var output = new List<byte>(b.Length + units.Count * (4 - headerLength));
        foreach (var (start, length) in units)
        {
            output.AddRange(StartCode);
            output.AddRange(b.AsSpan(start, length));
        }
        b = output.ToArray();
        return true;
    }
}

// Turns encoder output into a stream that a decoder can join at any IDR
// frame. The encoder gives SPS and PPS as codec config. The framer keeps
// them and writes them in front of each IDR frame that lacks them.
// AnnexBFramer of the Mac app has the same rules.
public sealed class AnnexBFramer
{
    byte[]? config;
    bool started;

    // Stores codec config. It returns no bytes, because the config goes out
    // with the next IDR frame.
    public void OnConfig(ReadOnlySpan<byte> data) => config = AnnexB.WithStartCode(data);

    // Returns the bytes to write for 1 encoded frame. It returns null for a
    // frame that a decoder cannot use yet: a frame before the first IDR frame.
    public byte[]? OnFrame(ReadOnlySpan<byte> data, bool keyFrame)
    {
        var frame = AnnexB.WithStartCode(data);
        var types = AnnexB.NalTypes(frame);
        var isIdr = keyFrame || types.Contains(AnnexB.NalIdr);
        if (!isIdr && !started)
        {
            return null;
        }
        if (isIdr)
        {
            started = true;
        }
        if (!isIdr || (types.Contains(AnnexB.NalSps) && types.Contains(AnnexB.NalPps)) || config is null)
        {
            return frame;
        }
        return [.. config, .. frame];
    }
}
