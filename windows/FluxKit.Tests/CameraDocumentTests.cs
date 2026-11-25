using FluxKit;

namespace FluxKit.Tests;

// The page search and the flattening of Document mode. The Mac uses the
// document segmentation of Vision, so these tests have no Mac source.
public class CameraDocumentTests
{
    // A photo of 400 by 300 pixels: a dark desk with noise, and a white page
    // with the 4 corners. A black square sits near the top left corner of the
    // page, and gray lines of text run across the page.
    static BgraImage Photo((double X, double Y)[] page, bool lightDesk = false)
    {
        const int w = 400;
        const int h = 300;
        var random = new JavaRandom(5);
        var pixels = new byte[w * h * 4];
        var map = DocumentFinder.SquareToQuad(page[0], page[1], page[2], page[3]);
        for (var y = 0; y < h; y++)
        {
            for (var x = 0; x < w; x++)
            {
                var desk = (lightDesk ? 235 : 60) + random.NextInt(21) - 10;
                var v = Inside(page, x + 0.5, y + 0.5) ? 235 : desk;
                var at = (y * w + x) * 4;
                pixels[at] = pixels[at + 1] = pixels[at + 2] = (byte)v;
                pixels[at + 3] = 255;
            }
        }
        // The marks on the page, drawn through the map of the page.
        for (var v = 0.0; v < 1; v += 0.002)
        {
            for (var u = 0.0; u < 1; u += 0.002)
            {
                var square = u is > 0.1 and < 0.3 && v is > 0.1 and < 0.3;
                var line = u is > 0.1 and < 0.9 && v > 0.45 && (int)(v * 100) % 8 == 0;
                if (!square && !line)
                {
                    continue;
                }
                var (x, y) = map(u, v);
                if (x < 0 || x >= w || y < 0 || y >= h)
                {
                    continue;
                }
                var at = ((int)y * w + (int)x) * 4;
                pixels[at] = pixels[at + 1] = pixels[at + 2] = (byte)(square ? 10 : 120);
            }
        }
        return new BgraImage(w, h, pixels);
    }

    // True when the point is inside the convex polygon.
    static bool Inside((double X, double Y)[] poly, double x, double y)
    {
        var sign = 0;
        for (var i = 0; i < poly.Length; i++)
        {
            var a = poly[i];
            var b = poly[(i + 1) % poly.Length];
            var cross = (b.X - a.X) * (y - a.Y) - (b.Y - a.Y) * (x - a.X);
            var s = Math.Sign(cross);
            if (s == 0)
            {
                continue;
            }
            if (sign == 0)
            {
                sign = s;
            }
            else if (s != sign)
            {
                return false;
            }
        }
        return true;
    }

    static readonly (double X, double Y)[] Tilted = [(80, 50), (330, 70), (310, 260), (60, 240)];

    static void Near(ScanPoint p, (double X, double Y) expected)
    {
        Assert.InRange(p.X * 400, expected.X - 6, expected.X + 6);
        Assert.InRange(p.Y * 300, expected.Y - 6, expected.Y + 6);
    }

    [Fact]
    public void FindsTheCornersOfATiltedPage()
    {
        var quad = DocumentFinder.Find(Photo(Tilted));
        Assert.NotNull(quad);
        Near(quad.TopLeft, Tilted[0]);
        Near(quad.TopRight, Tilted[1]);
        Near(quad.BottomRight, Tilted[2]);
        Near(quad.BottomLeft, Tilted[3]);
    }

    [Fact]
    public void FindsAPageTurnedNearlyAQuarter()
    {
        // The corner nearest to the top left of the photo comes first.
        (double X, double Y)[] turned = [(120, 30), (330, 110), (270, 280), (60, 200)];
        var quad = DocumentFinder.Find(Photo(turned));
        Assert.NotNull(quad);
        Near(quad.TopLeft, turned[0]);
        Near(quad.TopRight, turned[1]);
        Near(quad.BottomRight, turned[2]);
        Near(quad.BottomLeft, turned[3]);
    }

    [Fact]
    public void APageThatFillsThePhotoOrALightDeskGivesNoPage()
    {
        Assert.Null(DocumentFinder.Find(Photo([(-5, -5), (405, -5), (405, 305), (-5, 305)])));
        Assert.Null(DocumentFinder.Find(Photo(Tilted, lightDesk: true)));
        // A small card is no page.
        Assert.Null(DocumentFinder.Find(Photo([(150, 120), (230, 120), (230, 180), (150, 180)])));
    }

    [Fact]
    public void FlatteningPutsThePageUpright()
    {
        var photo = Photo(Tilted);
        var quad = DocumentFinder.Find(photo)!;
        var page = DocumentFinder.Flatten(photo, quad);
        // The page is about 250 by 190 pixels.
        Assert.InRange(page.Width, 240, 262);
        Assert.InRange(page.Height, 182, 200);
        double Mean(double u0, double v0, double u1, double v1)
        {
            double sum = 0;
            var n = 0;
            for (var y = (int)(v0 * page.Height); y < (int)(v1 * page.Height); y++)
            {
                for (var x = (int)(u0 * page.Width); x < (int)(u1 * page.Width); x++)
                {
                    sum += page.Pixels[(y * page.Width + x) * 4];
                    n++;
                }
            }
            return sum / n;
        }
        Assert.True(Mean(0.14, 0.14, 0.26, 0.26) < 60, "the square is at the top left of the page");
        Assert.True(Mean(0.65, 0.12, 0.9, 0.35) > 200, "the top right of the page is white");
        Assert.True(Mean(0.02, 0.02, 0.06, 0.06) > 180, "the desk is cut off");
    }

    [Fact]
    public void TheMapOfARectangleIsLinear()
    {
        var map = DocumentFinder.SquareToQuad((10, 20), (110, 20), (110, 70), (10, 70));
        Assert.Equal((60.0, 45.0), map(0.5, 0.5));
        Assert.Equal((110.0, 70.0), map(1, 1));
        var tilted = DocumentFinder.SquareToQuad(Tilted[0], Tilted[1], Tilted[2], Tilted[3]);
        foreach (var (u, v, i) in new[] { (0.0, 0.0, 0), (1.0, 0.0, 1), (1.0, 1.0, 2), (0.0, 1.0, 3) })
        {
            var (x, y) = tilted(u, v);
            Assert.Equal(Tilted[i].X, x, 6);
            Assert.Equal(Tilted[i].Y, y, 6);
        }
    }
}
