using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using FluxKit;

namespace FluxKit.Tests;

// The image rules of CameraImagesTests.swift of the Mac app: the sizes, the
// PDF, and the PNG of a signature. The app decodes and encodes JPEG files,
// so the UI checks on Windows test those.
public class CameraImagesTests
{
    // The start of a JPEG file: SOI, an APP0 segment, and a baseline frame
    // header, then the end. The PDF needs only the header.
    internal static byte[] Jpeg(int width, int height, int components = 3)
    {
        var data = new List<byte> { 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10 };
        data.AddRange("JFIF\0"u8.ToArray());
        data.AddRange(new byte[9]);
        data.AddRange(new byte[] { 0xFF, 0xC0, 0x00, (byte)(8 + 3 * components), 8, (byte)(height >> 8), (byte)height, (byte)(width >> 8), (byte)width, (byte)components });
        for (var c = 0; c < components; c++)
        {
            data.AddRange(new byte[] { (byte)(c + 1), 0x11, 0 });
        }
        data.AddRange(new byte[] { 0xFF, 0xD9 });
        return data.ToArray();
    }

    static BgraImage Image(int w, int h, Func<int, int, (byte B, byte G, byte R, byte A)> color)
    {
        var pixels = new byte[w * h * 4];
        for (var y = 0; y < h; y++)
        {
            for (var x = 0; x < w; x++)
            {
                var (b, g, r, a) = color(x, y);
                var at = (y * w + x) * 4;
                pixels[at] = b;
                pixels[at + 1] = g;
                pixels[at + 2] = r;
                pixels[at + 3] = a;
            }
        }
        return new BgraImage(w, h, pixels);
    }

    // The blue value of a pixel, which the tests use as its number.
    static int At(BgraImage image, int x, int y) => image.Pixels[(y * image.Width + x) * 4];

    [Fact]
    public void JpegInfoReadsTheFrameHeader()
    {
        Assert.Equal((640, 480, 3), CameraImages.JpegInfo(Jpeg(640, 480)));
        Assert.Equal((2, 3000, 1), CameraImages.JpegInfo(Jpeg(2, 3000, 1)));
        Assert.True(CameraImages.IsJpeg(Jpeg(1, 1)));
        Assert.Null(CameraImages.JpegInfo("not an image"u8));
        Assert.False(CameraImages.IsJpeg("\x89PNG"u8));
        // A file that ends before its frame header.
        Assert.Null(CameraImages.JpegInfo(Jpeg(640, 480)[..12]));
    }

    [Fact]
    public void APdfHasAPageForEachJpeg()
    {
        var pages = new[] { Jpeg(1200, 1600), Jpeg(3000, 2000) };
        var pdf = CameraImages.Pdf(pages);
        var text = Encoding.Latin1.GetString(pdf);
        Assert.StartsWith("%PDF-1.4\n", text);
        Assert.EndsWith("%%EOF\n", text);
        Assert.Contains("/Count 2", text);
        Assert.Equal(2, Regex.Matches(text, @"/Type /Page\b(?!s)").Count);
        // The long side of each page is as long as A4.
        Assert.Contains("/MediaBox [0 0 632 842]", text);
        Assert.Contains("/MediaBox [0 0 842 561]", text);
        Assert.Contains("/Width 1200 /Height 1600 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", text);
        // Each JPEG is in the file as it is.
        foreach (var page in pages)
        {
            Assert.True(pdf.AsSpan().IndexOf(page) > 0);
        }
        // Each entry of the cross-reference table points at its object.
        var start = int.Parse(Regex.Match(text, @"startxref\n(\d+)\n").Groups[1].Value);
        Assert.StartsWith("xref\n", text[start..]);
        var entries = Regex.Matches(text[start..], @"(\d{10}) 00000 n \n");
        Assert.Equal(9, entries.Count);
        for (var i = 0; i < entries.Count; i++)
        {
            var offset = int.Parse(entries[i].Groups[1].Value);
            Assert.StartsWith($"{i + 1} 0 obj\n", text[offset..]);
        }
        Assert.Contains("/Size 10 /Root 1 0 R", text);
    }

    [Fact]
    public void APdfNeedsJpegPages()
    {
        Assert.Throws<ArgumentException>(() => CameraImages.Pdf([]));
        Assert.Throws<ArgumentException>(() => CameraImages.Pdf([Jpeg(10, 10), "not an image"u8.ToArray()]));
    }

    [Fact]
    public void AGrayPageIsGray()
    {
        var text = Encoding.Latin1.GetString(CameraImages.Pdf([Jpeg(100, 100, 1)]));
        Assert.Contains("/ColorSpace /DeviceGray", text);
    }

    // Reads the chunks of a PNG file.
    static List<(string Type, byte[] Data)> Chunks(byte[] png)
    {
        Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, png[..8]);
        var chunks = new List<(string, byte[])>();
        var at = 8;
        while (at < png.Length)
        {
            var length = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(at));
            var type = Encoding.ASCII.GetString(png, at + 4, 4);
            chunks.Add((type, png[(at + 8)..(at + 8 + length)]));
            at += 12 + length;
        }
        return chunks;
    }

    [Fact]
    public void TheSignaturePngIsTransparentAroundTheInk()
    {
        var alpha = new byte[20 * 10];
        for (var x = 5; x < 15; x++)
        {
            alpha[5 * 20 + x] = 255;
        }
        alpha[4 * 20 + 5] = 128;
        var ink = new SignatureInk(20, 10, alpha, 0x123456);
        var png = CameraImages.Png(ink, 0x1A3DB0);
        var chunks = Chunks(png);
        Assert.Equal(["IHDR", "IDAT", "IEND"], chunks.Select(c => c.Type));
        var header = chunks[0].Data;
        Assert.Equal(20, BinaryPrimitives.ReadInt32BigEndian(header));
        Assert.Equal(10, BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(4)));
        Assert.Equal(8, header[8]);
        Assert.Equal(6, header[9]);
        using var z = new ZLibStream(new MemoryStream(chunks[1].Data), CompressionMode.Decompress);
        using var raw = new MemoryStream();
        z.CopyTo(raw);
        var rows = raw.ToArray();
        Assert.Equal(10 * (1 + 20 * 4), rows.Length);
        for (var y = 0; y < 10; y++)
        {
            Assert.Equal(0, rows[y * 81]);
            for (var x = 0; x < 20; x++)
            {
                var p = y * 81 + 1 + x * 4;
                Assert.Equal(new byte[] { 0x1A, 0x3D, 0xB0, alpha[y * 20 + x] }, rows[p..(p + 4)]);
            }
        }
    }

    [Fact]
    public void ArgbPutsTransparentPartsOnWhitePaper()
    {
        var image = Image(3, 1, (x, _) => x switch
        {
            0 => ((byte)0, (byte)0, (byte)0, (byte)0),
            1 => ((byte)10, (byte)20, (byte)30, (byte)255),
            _ => ((byte)0, (byte)0, (byte)0, (byte)128),
        });
        Assert.Equal(new uint[] { 0xFFFFFFFF, 0xFF1E140A, 0xFF7F7F7F }, image.Argb());
    }

    [Fact]
    public void ImagesScaleToTheirLargestSide()
    {
        Assert.Equal((2048, 1536), CameraImages.Fit(4000, 3000, CameraImages.MaxStillSide));
        Assert.Equal((300, 200), CameraImages.Fit(300, 200, CameraImages.MaxStillSide));
        Assert.Equal((100, 1), CameraImages.Fit(5000, 1, 100));
        var image = Image(400, 100, (x, _) => ((byte)(x < 200 ? 0 : 200), 0, 0, 255));
        var small = image.Scaled(100);
        Assert.Equal((100, 25), (small.Width, small.Height));
        Assert.Equal(0, At(small, 10, 10));
        Assert.Equal(200, At(small, 90, 10));
        Assert.Same(image, image.Scaled(400));
    }

    [Fact]
    public void ACropTakesThePartAndScalesIt()
    {
        var image = Image(100, 80, (x, y) => ((byte)(x + y), 0, 0, 255));
        var part = image.Crop(new SignatureCrop(10, 20, 30, 40), 100);
        Assert.Equal((30, 40), (part.Width, part.Height));
        Assert.Equal(30, At(part, 0, 0));
        Assert.Equal(10 + 29 + 20 + 39, At(part, 29, 39));
        var scaled = image.Crop(null, 50);
        Assert.Equal((50, 40), (scaled.Width, scaled.Height));
        // A crop that leaves the image stays inside it.
        var edge = image.Crop(new SignatureCrop(90, 70, 50, 50), 100);
        Assert.Equal((10, 10), (edge.Width, edge.Height));
    }

    // A 3 by 2 image with the pixel numbers 0 to 5, row by row:
    // 0 1 2
    // 3 4 5
    static BgraImage Numbers() => Image(3, 2, (x, y) => ((byte)(y * 3 + x), 0, 0, 255));

    static int[] Rows(BgraImage image) =>
        Enumerable.Range(0, image.Width * image.Height).Select(i => At(image, i % image.Width, i / image.Width)).ToArray();

    [Fact]
    public void TheExifOrientationTurnsTheImageUpright()
    {
        var numbers = Numbers();
        Assert.Same(numbers, numbers.Upright(1));
        Assert.Equal([0, 1, 2, 3, 4, 5], Rows(Numbers().Upright(1)));
        Assert.Equal([2, 1, 0, 5, 4, 3], Rows(Numbers().Upright(2)));
        Assert.Equal([5, 4, 3, 2, 1, 0], Rows(Numbers().Upright(3)));
        Assert.Equal([3, 4, 5, 0, 1, 2], Rows(Numbers().Upright(4)));
        // A turn makes the image 2 wide and 3 high.
        var turned = Numbers().Upright(6);
        Assert.Equal((2, 3), (turned.Width, turned.Height));
        Assert.Equal([3, 0, 4, 1, 5, 2], Rows(turned));
        Assert.Equal([2, 5, 1, 4, 0, 3], Rows(Numbers().Upright(8)));
        Assert.Equal([0, 3, 1, 4, 2, 5], Rows(Numbers().Upright(5)));
        Assert.Equal([5, 2, 4, 1, 3, 0], Rows(Numbers().Upright(7)));
        Assert.Equal([0, 1, 2, 3, 4, 5], Rows(Numbers().Upright(42)));
    }
}
