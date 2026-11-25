using System.Buffers.Binary;
using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace FluxKit;

// An image in 32-bit BGRA with straight alpha: 4 bytes for each pixel, rows
// from the top, and no gap between the rows. The camera modes work on it.
// The app decodes and encodes the image files, and FluxKit does the rest.
public sealed class BgraImage
{
    public BgraImage(int width, int height, byte[] pixels)
    {
        if (width <= 0 || height <= 0 || pixels.Length != width * height * 4)
        {
            throw new ArgumentException("The pixels do not match the size");
        }
        Width = width;
        Height = height;
        Pixels = pixels;
    }

    public int Width { get; }
    public int Height { get; }
    public byte[] Pixels { get; }

    // Returns the pixels as 0xAARRGGBB, row by row from the top, with
    // transparent parts on white paper. Each pixel is opaque.
    public uint[] Argb()
    {
        var output = new uint[Width * Height];
        var p = Pixels;
        for (var i = 0; i < output.Length; i++)
        {
            var at = i * 4;
            int a = p[at + 3];
            uint b = (uint)((p[at] * a + 255 * (255 - a) + 127) / 255);
            uint g = (uint)((p[at + 1] * a + 255 * (255 - a) + 127) / 255);
            uint r = (uint)((p[at + 2] * a + 255 * (255 - a) + 127) / 255);
            output[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
        }
        return output;
    }

    // Returns a part of the image, scaled so that its largest side is at
    // most maxSide. A null crop takes the whole image.
    public BgraImage Crop(SignatureCrop? crop, int maxSide)
    {
        var part = this;
        if (crop is { } c)
        {
            var left = Math.Clamp(c.Left, 0, Width - 1);
            var top = Math.Clamp(c.Top, 0, Height - 1);
            var w = Math.Clamp(c.Width, 1, Width - left);
            var h = Math.Clamp(c.Height, 1, Height - top);
            var pixels = new byte[w * h * 4];
            for (var y = 0; y < h; y++)
            {
                Buffer.BlockCopy(Pixels, ((top + y) * Width + left) * 4, pixels, y * w * 4, w * 4);
            }
            part = new BgraImage(w, h, pixels);
        }
        return part.Scaled(maxSide);
    }

    // Returns the image with its largest side at most maxSide. A smaller
    // image stays as it is.
    public BgraImage Scaled(int maxSide)
    {
        var (w, h) = CameraImages.Fit(Width, Height, maxSide);
        if (w == Width && h == Height)
        {
            return this;
        }
        var pixels = new byte[w * h * 4];
        CameraImages.Scale(Pixels, Width, Height, pixels, w, h);
        return new BgraImage(w, h, pixels);
    }

    // Returns the image upright for an EXIF orientation from 1 to 8. The
    // steps are those that the EXIF standard gives: mirror the image
    // horizontally first when the orientation says so, then turn it
    // clockwise.
    public BgraImage Upright(int orientation)
    {
        var (turn, mirror) = CameraImages.Orientation(orientation);
        if (turn == 0 && !mirror)
        {
            return this;
        }
        var w = turn % 180 == 0 ? Width : Height;
        var h = turn % 180 == 0 ? Height : Width;
        var output = new byte[Pixels.Length];
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width; x++)
            {
                var sx = mirror ? Width - 1 - x : x;
                // The position of pixel (x, y) of the mirrored image after the turn.
                var (dx, dy) = turn switch
                {
                    90 => (Height - 1 - y, x),
                    180 => (Width - 1 - x, Height - 1 - y),
                    270 => (y, Width - 1 - x),
                    _ => (x, y),
                };
                Buffer.BlockCopy(Pixels, (y * Width + sx) * 4, output, (dy * w + dx) * 4, 4);
            }
        }
        return new BgraImage(w, h, output);
    }
}

// The image rules of the camera modes: the sizes, the scale, the PDF, and
// the PNG of a signature. CameraImages.swift of the Mac app has the same
// rules. The app decodes and encodes JPEG files.
public static class CameraImages
{
    // The largest side of a still image that Flux reads. It keeps memory use low.
    public const int MaxStillSide = 2048;

    // The JPEG quality of a photo, from 0 to 100.
    public const int PhotoQuality = 92;

    // The JPEG quality of a page of a PDF, from 0 to 100.
    public const int PageQuality = 85;

    // The long side of a PDF page in points: the long side of A4.
    public const double PageLongSide = 842;

    // Returns the size with its largest side at most maxSide, with the same
    // aspect. A smaller size stays as it is.
    public static (int Width, int Height) Fit(int width, int height, int maxSide)
    {
        var side = Math.Max(width, height);
        if (side <= maxSide)
        {
            return (width, height);
        }
        var s = (double)maxSide / side;
        return (Math.Max(1, (int)(width * s)), Math.Max(1, (int)(height * s)));
    }

    // Returns the clockwise turn in degrees and the horizontal mirror that
    // make an image with the EXIF orientation upright. An unknown value
    // gives no change.
    public static (int Turn, bool Mirror) Orientation(int exif) => exif switch
    {
        2 => (0, true),
        3 => (180, false),
        4 => (180, true),
        5 => (270, true),
        6 => (90, false),
        7 => (90, true),
        8 => (270, false),
        _ => (0, false),
    };

    // Scales src into dst. Each pixel of dst is the mean of the pixels of src
    // that it covers, so that small text stays readable after a large
    // reduction. A larger dst repeats the pixels. The rows run in parallel.
    public static void Scale(byte[] src, int srcWidth, int srcHeight, byte[] dst, int dstWidth, int dstHeight)
    {
        var fx = (double)srcWidth / dstWidth;
        var fy = (double)srcHeight / dstHeight;
        Parallel.For(0, dstHeight, y =>
        {
            var y0 = Math.Min(srcHeight - 1, (int)(y * fy));
            var y1 = Math.Min(srcHeight, Math.Max(y0 + 1, (int)((y + 1) * fy)));
            var at = y * dstWidth * 4;
            for (var x = 0; x < dstWidth; x++)
            {
                var x0 = Math.Min(srcWidth - 1, (int)(x * fx));
                var x1 = Math.Min(srcWidth, Math.Max(x0 + 1, (int)((x + 1) * fx)));
                int b = 0, g = 0, r = 0, a = 0;
                var n = (y1 - y0) * (x1 - x0);
                for (var yy = y0; yy < y1; yy++)
                {
                    var p = (yy * srcWidth + x0) * 4;
                    for (var xx = x0; xx < x1; xx++)
                    {
                        b += src[p];
                        g += src[p + 1];
                        r += src[p + 2];
                        a += src[p + 3];
                        p += 4;
                    }
                }
                dst[at] = (byte)(b / n);
                dst[at + 1] = (byte)(g / n);
                dst[at + 2] = (byte)(r / n);
                dst[at + 3] = (byte)(a / n);
                at += 4;
            }
        });
    }

    // JPEG

    // The size and the color components of a JPEG file, from its frame
    // header, or null when the data is not a JPEG file.
    public static (int Width, int Height, int Components)? JpegInfo(ReadOnlySpan<byte> data)
    {
        if (data.Length < 4 || data[0] != 0xFF || data[1] != 0xD8)
        {
            return null;
        }
        var at = 2;
        while (at + 4 <= data.Length)
        {
            if (data[at] != 0xFF)
            {
                return null;
            }
            var marker = data[at + 1];
            if (marker == 0xFF)
            {
                // A fill byte.
                at++;
                continue;
            }
            if (marker is 0x01 or (>= 0xD0 and <= 0xD7))
            {
                at += 2;
                continue;
            }
            var length = BinaryPrimitives.ReadUInt16BigEndian(data[(at + 2)..]);
            if (length < 2 || at + 2 + length > data.Length)
            {
                return null;
            }
            // The start of frame markers. C4, C8, and CC are other markers.
            if (marker is >= 0xC0 and <= 0xCF and not 0xC4 and not 0xC8 and not 0xCC)
            {
                if (length < 8)
                {
                    return null;
                }
                var segment = data.Slice(at + 4, length - 2);
                var height = BinaryPrimitives.ReadUInt16BigEndian(segment[1..]);
                var width = BinaryPrimitives.ReadUInt16BigEndian(segment[3..]);
                int components = segment[5];
                return width > 0 && height > 0 && components is 1 or 3 or 4 ? (width, height, components) : null;
            }
            if (marker == 0xDA)
            {
                // The scan starts before a frame header.
                return null;
            }
            at += 2 + length;
        }
        return null;
    }

    // Reports whether the data starts like a JPEG file.
    public static bool IsJpeg(ReadOnlySpan<byte> data) => data.Length >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF;

    // PDF

    // Returns a PDF with 1 page for each JPEG file. Each page has the aspect
    // of its image, with a long side of 842 points, the long side of A4, and
    // holds the JPEG data as it is. It throws ArgumentException for no pages
    // or for data that is not a JPEG file.
    public static byte[] Pdf(IReadOnlyList<byte[]> jpegs)
    {
        if (jpegs.Count == 0)
        {
            throw new ArgumentException("A PDF needs at least 1 page");
        }
        var pages = jpegs.Select(j => (Data: j, Info: JpegInfo(j) ?? throw new ArgumentException("A page is not a JPEG image"))).ToArray();
        using var output = new MemoryStream();
        var offsets = new List<long>();
        void Text(string s)
        {
            var bytes = Encoding.ASCII.GetBytes(s);
            output.Write(bytes);
        }
        void Begin(int number)
        {
            while (offsets.Count < number)
            {
                offsets.Add(0);
            }
            offsets[number - 1] = output.Position;
            Text($"{number} 0 obj\n");
        }
        // Object 1 is the catalog, object 2 the page tree, then 3 objects
        // for each page, and the info dictionary last.
        int PageObject(int i) => 3 + i * 3;
        var info = 3 + pages.Length * 3;
        Text("%PDF-1.4\n");
        // A comment with 4 bytes over 127 marks the file as binary.
        output.Write([(byte)'%', 0xE2, 0xE3, 0xCF, 0xD3, (byte)'\n']);
        Begin(1);
        Text("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
        Begin(2);
        var kids = string.Join(' ', Enumerable.Range(0, pages.Length).Select(i => $"{PageObject(i)} 0 R"));
        Text($"<< /Type /Pages /Kids [{kids}] /Count {pages.Length} >>\nendobj\n");
        for (var i = 0; i < pages.Length; i++)
        {
            var (data, (w, h, components)) = pages[i];
            var s = PageLongSide / Math.Max(w, h);
            var pw = Math.Round(w * s).ToString(CultureInfo.InvariantCulture);
            var ph = Math.Round(h * s).ToString(CultureInfo.InvariantCulture);
            var page = PageObject(i);
            Begin(page);
            Text($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {pw} {ph}] /Resources << /XObject << /Im0 {page + 2} 0 R >> >> /Contents {page + 1} 0 R >>\nendobj\n");
            var draw = $"q {pw} 0 0 {ph} 0 0 cm /Im0 Do Q\n";
            Begin(page + 1);
            Text($"<< /Length {draw.Length} >>\nstream\n{draw}endstream\nendobj\n");
            // An Adobe JPEG with 4 components holds inverted CMYK.
            var space = components switch
            {
                1 => "/DeviceGray",
                4 => "/DeviceCMYK /Decode [1 0 1 0 1 0 1 0]",
                _ => "/DeviceRGB",
            };
            Begin(page + 2);
            Text($"<< /Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace {space} /BitsPerComponent 8 /Filter /DCTDecode /Length {data.Length} >>\nstream\n");
            output.Write(data);
            Text("\nendstream\nendobj\n");
        }
        Begin(info);
        Text("<< /Producer (Flux) /Creator (Flux) >>\nendobj\n");
        var xref = output.Position;
        Text($"xref\n0 {offsets.Count + 1}\n0000000000 65535 f \n");
        foreach (var offset in offsets)
        {
            Text($"{offset.ToString("D10", CultureInfo.InvariantCulture)} 00000 n \n");
        }
        Text($"trailer\n<< /Size {offsets.Count + 1} /Root 1 0 R /Info {info} 0 R >>\nstartxref\n{xref.ToString(CultureInfo.InvariantCulture)}\n%%EOF\n");
        return output.ToArray();
    }

    // PNG

    // Returns the signature as a PNG in the color, on a transparent background.
    public static byte[] Png(SignatureInk ink, int rgb)
    {
        var rgba = new byte[ink.Width * ink.Height * 4];
        var r = (byte)(rgb >> 16);
        var g = (byte)(rgb >> 8);
        var b = (byte)rgb;
        for (var i = 0; i < ink.Alpha.Length; i++)
        {
            rgba[i * 4] = r;
            rgba[i * 4 + 1] = g;
            rgba[i * 4 + 2] = b;
            rgba[i * 4 + 3] = ink.Alpha[i];
        }
        return Png(ink.Width, ink.Height, rgba);
    }

    // Returns a PNG of 8-bit RGBA pixels with straight alpha, rows from the top.
    public static byte[] Png(int width, int height, byte[] rgba)
    {
        if (width <= 0 || height <= 0 || rgba.Length != width * height * 4)
        {
            throw new ArgumentException("The pixels do not match the size");
        }
        using var output = new MemoryStream();
        output.Write([0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        var header = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header, width);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), height);
        // 8 bits for each sample, color type 6 for RGBA, the deflate method,
        // the adaptive filters, and no interlace.
        header[8] = 8;
        header[9] = 6;
        Chunk(output, "IHDR", header);
        using (var packed = new MemoryStream())
        {
            using (var z = new ZLibStream(packed, CompressionLevel.Optimal, leaveOpen: true))
            {
                var row = width * 4;
                for (var y = 0; y < height; y++)
                {
                    // Filter 0: the row as it is.
                    z.WriteByte(0);
                    z.Write(rgba, y * row, row);
                }
            }
            Chunk(output, "IDAT", packed.ToArray());
        }
        Chunk(output, "IEND", []);
        return output.ToArray();
    }

    static void Chunk(Stream output, string type, byte[] data)
    {
        Span<byte> number = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(number, data.Length);
        output.Write(number);
        var name = Encoding.ASCII.GetBytes(type);
        output.Write(name);
        output.Write(data);
        BinaryPrimitives.WriteUInt32BigEndian(number, Crc.Update(Crc.Update(0xFFFFFFFF, name), data) ^ 0xFFFFFFFF);
        output.Write(number);
    }

    // The CRC-32 of PNG chunks, with the polynomial 0xEDB88320.
    static class Crc
    {
        static readonly uint[] Table = MakeTable();

        static uint[] MakeTable()
        {
            var table = new uint[256];
            for (uint n = 0; n < 256; n++)
            {
                var c = n;
                for (var k = 0; k < 8; k++)
                {
                    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
                }
                table[n] = c;
            }
            return table;
        }

        public static uint Update(uint crc, ReadOnlySpan<byte> data)
        {
            foreach (var b in data)
            {
                crc = Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
            }
            return crc;
        }
    }
}
