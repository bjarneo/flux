using FluxKit;

namespace FluxKit.Tests;

// java.util.Random, so that the images match the Android and Mac tests.
sealed class JavaRandom(long seed)
{
    long state = (seed ^ 0x5DEECE66DL) & ((1L << 48) - 1);

    int Next(int bits)
    {
        state = (state * 0x5DEECE66DL + 0xBL) & ((1L << 48) - 1);
        return (int)(state >> (48 - bits));
    }

    public int NextInt(int bound)
    {
        if ((bound & -bound) == bound)
        {
            return (int)((bound * (long)Next(31)) >> 31);
        }
        int bits, val;
        do
        {
            bits = Next(31);
            val = bits % bound;
        }
        while (bits - val + (bound - 1) < 0);
        return val;
    }
}

// SignatureInkTests.swift of the Mac app.
public class SignatureInkTests
{
    const int W = 800;
    const int H = 320;
    const uint InkRgb = 0x283278;

    // Paper that goes from bright on the left to a shadow on the right, with noise.
    static uint[] Paper(long seed = 1)
    {
        var random = new JavaRandom(seed);
        var img = new uint[W * H];
        for (var i = 0; i < img.Length; i++)
        {
            var x = i % W;
            var b = 235 - 80 * x / W;
            var v = Math.Min(Math.Max(b + random.NextInt(13) - 6, 0), 255);
            img[i] = Rgb(v, v, Math.Max(v - 8, 0));
        }
        return img;
    }

    static uint Rgb(int r, int g, int b) => 0xFF000000 | (uint)r << 16 | (uint)g << 8 | (uint)b;

    // Draws a filled disc of ink.
    static void Dot(uint[] img, int cx, int cy, int radius)
    {
        for (var y = cy - radius; y <= cy + radius; y++)
        {
            for (var x = cx - radius; x <= cx + radius; x++)
            {
                var dx = x - cx;
                var dy = y - cy;
                if (x >= 0 && x < W && y >= 0 && y < H && dx * dx + dy * dy <= radius * radius)
                {
                    img[y * W + x] = 0xFF000000 | InkRgb;
                }
            }
        }
    }

    // Draws a wave from x = 200 to 600 around y = 160, 3 pixels thick on
    // each side. It returns its box.
    static int[] Stroke(uint[] img)
    {
        int minY = H, maxY = 0;
        for (var x = 200; x <= 600; x++)
        {
            var y = 160 + (int)(40 * Math.Sin(x / 30.0));
            Dot(img, x, y, 3);
            minY = Math.Min(minY, y - 3);
            maxY = Math.Max(maxY, y + 3);
        }
        return [197, minY, 603, maxY];
    }

    static int Margin(int[] box) => Math.Max(8, Math.Max(box[2] - box[0], box[3] - box[1]) / 40);

    static SignatureInk Signature()
    {
        var img = Paper();
        Stroke(img);
        return SignatureCut.Extract(img, W, H)!;
    }

    [Fact]
    public void KeepsTheStrokeOnUnevenPaper()
    {
        var img = Paper();
        var box = Stroke(img);
        var ink = SignatureCut.Extract(img, W, H);
        Assert.NotNull(ink);
        var m = Margin(box);
        Assert.Equal(box[2] - box[0] + 1 + 2 * m, ink.Width);
        Assert.Equal(box[3] - box[1] + 1 + 2 * m, ink.Height);
        // The stroke is opaque and the paper around it is transparent.
        var opaque = ink.Alpha.Count(a => a == 255);
        var visible = ink.Alpha.Count(a => a != 0);
        Assert.True(opaque > 2000, $"opaque pixels: {opaque}");
        Assert.True(visible < ink.Alpha.Length / 3, $"visible pixels: {visible} of {ink.Alpha.Length}");
        Assert.Equal(0, ink.Alpha[0]);
        Assert.Equal(0, ink.Alpha[^1]);
    }

    [Fact]
    public void FindsTheColorOfThePen()
    {
        var ink = Signature();
        Assert.InRange(((ink.Original >> 16) & 0xFF) - 0x28, -12, 12);
        Assert.InRange(((ink.Original >> 8) & 0xFF) - 0x32, -12, 12);
        Assert.InRange((ink.Original & 0xFF) - 0x78, -12, 12);
    }

    [Fact]
    public void RemovesSpecks()
    {
        var expected = Signature();
        // Specks away from the stroke. A kept speck would make the crop larger.
        var img = Paper();
        var box = Stroke(img);
        var random = new JavaRandom(7);
        var specks = 0;
        while (specks < 60)
        {
            var x = random.NextInt(W);
            var y = random.NextInt(H);
            if (x >= box[0] - 10 && x <= box[2] + 10 && y >= box[1] - 10 && y <= box[3] + 10)
            {
                continue;
            }
            img[y * W + x] = Rgb(20, 20, 20);
            specks++;
        }
        var ink = SignatureCut.Extract(img, W, H)!;
        Assert.Equal(expected.Width, ink.Width);
        Assert.Equal(expected.Height, ink.Height);
    }

    [Fact]
    public void RemovesADarkAreaAtTheBorder()
    {
        var expected = Signature();
        // A table at the bottom of the photo.
        var img = Paper();
        Stroke(img);
        for (var y = H - 40; y < H; y++)
        {
            for (var x = 0; x < W; x++)
            {
                img[y * W + x] = Rgb(50, 40, 30);
            }
        }
        var ink = SignatureCut.Extract(img, W, H)!;
        Assert.Equal(expected.Width, ink.Width);
        Assert.Equal(expected.Height, ink.Height);
    }

    [Fact]
    public void RemovesTheEdgeOfThePaper()
    {
        var expected = Signature();
        // A thin dark sliver of the table next to the right edge of the paper.
        var img = Paper();
        Stroke(img);
        for (var y = 0; y < H; y++)
        {
            for (var x = W - 6; x < W; x++)
            {
                img[y * W + x] = Rgb(60, 55, 50);
            }
        }
        var ink = SignatureCut.Extract(img, W, H)!;
        Assert.Equal(expected.Width, ink.Width);
        Assert.Equal(expected.Height, ink.Height);
    }

    [Fact]
    public void BlankPaperHasNoInk() => Assert.Null(SignatureCut.Extract(Paper(3), W, H));

    [Fact]
    public void PixelsUseTheColor()
    {
        var ink = Signature();
        var px = ink.Pixels(InkColor.Blue.Of(ink));
        Assert.Equal(ink.Width * ink.Height, px.Length);
        for (var i = 0; i < px.Length; i++)
        {
            Assert.Equal(0x1A3DB0u, px[i] & 0xFFFFFF);
            Assert.Equal(ink.Alpha[i], (byte)(px[i] >> 24));
        }
        Assert.Equal(ink.Original, InkColor.Original.Of(ink));
        Assert.Equal(0x000000, InkColor.Black.Of(ink));
    }

    [Fact]
    public void ARectangleOfTheWrongSizeFails() => Assert.Throws<ArgumentException>(() => SignatureCut.Extract(new uint[10], 4, 4));

    [Fact]
    public void FrameInAPortraitImage()
    {
        // The image is wider than the view, so aspect fill cuts off its sides.
        var crop = SignatureCut.FrameInImage(60, 555, 940, 907, 1000, 1500, 3000, 4000);
        Assert.Equal(new SignatureCrop(327, 1480, 2346, 939), crop);
    }

    [Fact]
    public void FrameInALandscapeImage()
    {
        // The image is taller than the view, so aspect fill cuts off its top and bottom.
        var crop = SignatureCut.FrameInImage(100, 100, 1500, 500, 1600, 900, 1600, 1200);
        Assert.Equal(new SignatureCrop(100, 250, 1400, 400), crop);
    }

    [Fact]
    public void FramePadsAndStaysInTheImage()
    {
        Assert.Equal(new SignatureCrop(80, 90, 240, 120), SignatureCut.FrameInImage(100, 100, 300, 200, 800, 600, 800, 600, 0.1f));
        Assert.Equal(new SignatureCrop(0, 0, 800, 600), SignatureCut.FrameInImage(-50, -50, 900, 700, 800, 600, 800, 600));
    }

    [Fact]
    public void TheGuideFrameIsFiveByTwo()
    {
        var wide = SignatureCut.GuideFrame(1000, 1000);
        Assert.Equal(880, wide.Width, 6);
        Assert.Equal(352, wide.Height, 6);
        Assert.Equal(60, wide.X, 6);
        var flat = SignatureCut.GuideFrame(1000, 200);
        Assert.Equal(120, flat.Height, 6);
        Assert.Equal(300, flat.Width, 6);
        Assert.Equal(40, flat.Y, 6);
    }

    // Drawn signatures

    [Fact]
    public void ADrawnStrokeIsCroppedWithTheMargin()
    {
        var drawing = new SignatureDrawing();
        drawing.Begin(new InkPoint(100, 50));
        drawing.Extend(new InkPoint(200, 60));
        drawing.Extend(new InkPoint(300, 50));
        var ink = drawing.Ink(400, 200, 2);
        Assert.NotNull(ink);
        // The stroke spans x 200 to 600 and y about 100 to 120 in pixels, 6 pixels wide.
        const int spanX = 400 + 6;
        var margin = Math.Max(8, spanX / 40);
        Assert.InRange(ink.Width, spanX + 2 * margin - 3, spanX + 2 * margin + 3);
        Assert.True(ink.Height < 60, "the crop follows the ink, not the canvas");
        Assert.Equal(0, ink.Original);
        Assert.True(ink.Alpha.Count(a => a == 255) > 1000);
        // The stroke dips in the middle: a canvas drawn upside down would put ink at the top there.
        var mid = ink.Width / 2;
        var first = Enumerable.Range(0, ink.Height).First(y => ink.Alpha[y * ink.Width + mid] > 128);
        Assert.True(first > ink.Height / 3);
    }

    [Fact]
    public void AnEmptyDrawingHasNoInk() => Assert.Null(new SignatureDrawing().Ink(400, 200));

    [Fact]
    public void ADotIsInk()
    {
        var drawing = new SignatureDrawing();
        drawing.Begin(new InkPoint(50, 50));
        var ink = drawing.Ink(100, 100)!;
        Assert.True(ink.Alpha.Count(a => a == 255) >= 9, "a click draws a dot of the line width");
    }

    [Fact]
    public void UndoAndClearRemoveStrokes()
    {
        var drawing = new SignatureDrawing();
        drawing.Add([new InkPoint(10, 10), new InkPoint(10.2, 10.2), new InkPoint(40, 10)]);
        Assert.Equal(2, drawing.Strokes[0].Count);
        drawing.Begin(new InkPoint(10, 30));
        Assert.Equal(2, drawing.Strokes.Count);
        drawing.Undo();
        Assert.Single(drawing.Strokes);
        drawing.Clear();
        Assert.True(drawing.IsEmpty);
        drawing.Undo();
        Assert.True(drawing.IsEmpty);
    }

    [Fact]
    public void ThePathGoesThroughTheMidpoints()
    {
        var path = SignatureDrawing.Path([new InkPoint(0, 0), new InkPoint(10, 0), new InkPoint(10, 10)]);
        Assert.Equal(new InkPoint(0, 0), path[0]);
        Assert.Contains(new InkPoint(5, 0), path);
        Assert.Contains(new InkPoint(10, 5), path);
        Assert.Equal(new InkPoint(10, 10), path[^1]);
    }
}
