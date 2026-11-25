namespace FluxKit;

// A point in an image in normalized coordinates, from 0 to 1, with the
// origin at the top left corner.
public readonly record struct ScanPoint(double X, double Y);

// The 4 corners of a page in an image, in normalized coordinates with the
// origin at the top left corner.
public sealed record DocumentQuad(ScanPoint TopLeft, ScanPoint TopRight, ScanPoint BottomRight, ScanPoint BottomLeft)
{
    public IReadOnlyList<ScanPoint> Points => [TopLeft, TopRight, BottomRight, BottomLeft];
}

// Finds a page in a photo and flattens it. Windows has no page detection,
// so this takes the place of the document segmentation of Vision on the
// Mac: the page is the largest bright area, and its corners are the corners
// of the largest quadrilateral in its convex hull. A page that fills the
// photo, a page on a light desk, or a page with a large dark picture gives
// no page, and the PDF gets the whole photo.
public static class DocumentFinder
{
    // The largest side of the image that the search reads.
    const int SearchSide = 256;

    // The smallest part of the image that a page covers, as the Mac asks of Vision.
    const double MinArea = 0.2;

    // A page that covers more of the image is the whole image.
    const double MaxArea = 0.95;

    // The smallest ratio of the short side to the long side.
    const double MinAspect = 0.3;

    // The smallest part of the quadrilateral that the bright area fills.
    const double MinFill = 0.85;

    // Returns the page in the image, or null when there is none.
    public static DocumentQuad? Find(BgraImage image)
    {
        var small = image.Scaled(SearchSide);
        var w = small.Width;
        var h = small.Height;
        if (w < 8 || h < 8)
        {
            return null;
        }
        var luma = Luma(small.Argb());
        var split = Otsu(luma);
        var bright = new bool[luma.Length];
        for (var i = 0; i < luma.Length; i++)
        {
            bright[i] = luma[i] > split;
        }
        if (Largest(bright, w, h) is not { } area)
        {
            return null;
        }
        var filled = FillHoles(area, w, h);
        var hull = Hull(Edges(filled, w, h));
        if (hull.Count < 4)
        {
            return null;
        }
        var corners = LargestQuad(hull);
        var quadArea = Area(corners);
        var count = filled.Count(f => f);
        var imageArea = (double)w * h;
        if (quadArea < MinArea * imageArea || quadArea > MaxArea * imageArea || count < MinFill * quadArea)
        {
            return null;
        }
        var sides = Enumerable.Range(0, 4).Select(i => Distance(corners[i], corners[(i + 1) % 4])).ToArray();
        if (Math.Min(sides[0] + sides[2], sides[1] + sides[3]) < MinAspect * Math.Max(sides[0] + sides[2], sides[1] + sides[3]))
        {
            return null;
        }
        var ordered = Order(corners);
        ScanPoint Norm((double X, double Y) p) => new(p.X / w, p.Y / h);
        return new DocumentQuad(Norm(ordered[0]), Norm(ordered[1]), Norm(ordered[2]), Norm(ordered[3]));
    }

    // Flattens the page inside quad into a rectangle with its largest side
    // at most maxSide. The size follows the longer of the opposite sides.
    public static BgraImage Flatten(BgraImage image, DocumentQuad quad, int maxSide = 3000)
    {
        (double X, double Y) Px(ScanPoint p) => (p.X * image.Width, p.Y * image.Height);
        var tl = Px(quad.TopLeft);
        var tr = Px(quad.TopRight);
        var br = Px(quad.BottomRight);
        var bl = Px(quad.BottomLeft);
        var width = Math.Max(Distance(tl, tr), Distance(bl, br));
        var height = Math.Max(Distance(tl, bl), Distance(tr, br));
        var (ow, oh) = CameraImages.Fit(Math.Max(1, (int)Math.Round(width)), Math.Max(1, (int)Math.Round(height)), maxSide);
        var map = SquareToQuad(tl, tr, br, bl);
        var src = image.Pixels;
        var sw = image.Width;
        var sh = image.Height;
        var output = new byte[ow * oh * 4];
        Parallel.For(0, oh, y =>
        {
            var v = (y + 0.5) / oh;
            for (var x = 0; x < ow; x++)
            {
                var u = (x + 0.5) / ow;
                var (sx, sy) = map(u, v);
                Sample(src, sw, sh, sx - 0.5, sy - 0.5, output, (y * ow + x) * 4);
            }
        });
        return new BgraImage(ow, oh, output);
    }

    // The map from the unit square to the quadrilateral, with (0, 0) at a,
    // (1, 0) at b, (1, 1) at c, and (0, 1) at d. It is the projective map of
    // Heckbert, "Fundamentals of Texture Mapping and Image Warping", 1989.
    internal static Func<double, double, (double X, double Y)> SquareToQuad((double X, double Y) a, (double X, double Y) b,
                                                                           (double X, double Y) c, (double X, double Y) d)
    {
        var sx = a.X - b.X + c.X - d.X;
        var sy = a.Y - b.Y + c.Y - d.Y;
        double g = 0, h = 0;
        if (Math.Abs(sx) > 1e-9 || Math.Abs(sy) > 1e-9)
        {
            var dx1 = b.X - c.X;
            var dx2 = d.X - c.X;
            var dy1 = b.Y - c.Y;
            var dy2 = d.Y - c.Y;
            var det = dx1 * dy2 - dx2 * dy1;
            if (Math.Abs(det) > 1e-12)
            {
                g = (sx * dy2 - dx2 * sy) / det;
                h = (dx1 * sy - sx * dy1) / det;
            }
        }
        var m11 = b.X - a.X + g * b.X;
        var m12 = d.X - a.X + h * d.X;
        var m21 = b.Y - a.Y + g * b.Y;
        var m22 = d.Y - a.Y + h * d.Y;
        return (u, v) =>
        {
            var z = g * u + h * v + 1;
            return ((m11 * u + m12 * v + a.X) / z, (m21 * u + m22 * v + a.Y) / z);
        };
    }

    // Writes the bilinear sample of src at (x, y) to dst at at. A point
    // outside the image takes the nearest edge pixel.
    static void Sample(byte[] src, int w, int h, double x, double y, byte[] dst, int at)
    {
        var x0 = (int)Math.Floor(x);
        var y0 = (int)Math.Floor(y);
        var fx = x - x0;
        var fy = y - y0;
        var xa = Math.Clamp(x0, 0, w - 1);
        var xb = Math.Clamp(x0 + 1, 0, w - 1);
        var ya = Math.Clamp(y0, 0, h - 1);
        var yb = Math.Clamp(y0 + 1, 0, h - 1);
        var p00 = (ya * w + xa) * 4;
        var p01 = (ya * w + xb) * 4;
        var p10 = (yb * w + xa) * 4;
        var p11 = (yb * w + xb) * 4;
        for (var k = 0; k < 4; k++)
        {
            var value = src[p00 + k] * (1 - fx) * (1 - fy) + src[p01 + k] * fx * (1 - fy) + src[p10 + k] * (1 - fx) * fy + src[p11 + k] * fx * fy;
            dst[at + k] = (byte)Math.Clamp((int)Math.Round(value), 0, 255);
        }
    }

    static int[] Luma(uint[] argb)
    {
        var luma = new int[argb.Length];
        for (var i = 0; i < argb.Length; i++)
        {
            var c = argb[i];
            luma[i] = (77 * (int)((c >> 16) & 0xFF) + 150 * (int)((c >> 8) & 0xFF) + 29 * (int)(c & 0xFF)) >> 8;
        }
        return luma;
    }

    // The split between dark and bright with the method of Otsu.
    static int Otsu(int[] luma)
    {
        var hist = new long[256];
        foreach (var v in luma)
        {
            hist[v]++;
        }
        double total = luma.Length;
        double sumAll = 0;
        for (var i = 0; i < 256; i++)
        {
            sumAll += (double)i * hist[i];
        }
        double sumBack = 0, countBack = 0, best = 0;
        var split = 0;
        for (var i = 0; i < 256; i++)
        {
            countBack += hist[i];
            if (countBack == 0)
            {
                continue;
            }
            var countFore = total - countBack;
            if (countFore == 0)
            {
                break;
            }
            sumBack += (double)i * hist[i];
            var meanBack = sumBack / countBack;
            var meanFore = (sumAll - sumBack) / countFore;
            var between = countBack * countFore * (meanBack - meanFore) * (meanBack - meanFore);
            if (between > best)
            {
                best = between;
                split = i;
            }
        }
        return split;
    }

    // The largest 4-connected area of the mask, or null when the mask is empty.
    static bool[]? Largest(bool[] mask, int w, int h)
    {
        var label = new int[mask.Length];
        var stack = new int[mask.Length];
        int best = 0, bestSize = 0, next = 0;
        for (var start = 0; start < mask.Length; start++)
        {
            if (!mask[start] || label[start] != 0)
            {
                continue;
            }
            next++;
            var top = 0;
            stack[top++] = start;
            label[start] = next;
            var size = 0;
            while (top > 0)
            {
                var p = stack[--top];
                size++;
                var x = p % w;
                var y = p / w;
                void Visit(int q)
                {
                    if (mask[q] && label[q] == 0)
                    {
                        label[q] = next;
                        stack[top++] = q;
                    }
                }
                if (x > 0)
                {
                    Visit(p - 1);
                }
                if (x < w - 1)
                {
                    Visit(p + 1);
                }
                if (y > 0)
                {
                    Visit(p - w);
                }
                if (y < h - 1)
                {
                    Visit(p + w);
                }
            }
            if (size > bestSize)
            {
                bestSize = size;
                best = next;
            }
        }
        if (best == 0)
        {
            return null;
        }
        return label.Select(l => l == best).ToArray();
    }

    // Returns the area with its holes filled, such as the text on a page: a
    // pixel is outside when a path of pixels outside the area joins it to
    // the border of the image.
    static bool[] FillHoles(bool[] area, int w, int h)
    {
        var outside = new bool[area.Length];
        var stack = new int[area.Length];
        var top = 0;
        void Seed(int p)
        {
            if (!area[p] && !outside[p])
            {
                outside[p] = true;
                stack[top++] = p;
            }
        }
        for (var x = 0; x < w; x++)
        {
            Seed(x);
            Seed((h - 1) * w + x);
        }
        for (var y = 0; y < h; y++)
        {
            Seed(y * w);
            Seed(y * w + w - 1);
        }
        while (top > 0)
        {
            var p = stack[--top];
            var x = p % w;
            var y = p / w;
            if (x > 0)
            {
                Seed(p - 1);
            }
            if (x < w - 1)
            {
                Seed(p + 1);
            }
            if (y > 0)
            {
                Seed(p - w);
            }
            if (y < h - 1)
            {
                Seed(p + w);
            }
        }
        return outside.Select(o => !o).ToArray();
    }

    // The outer corners of the first and the last pixel of the area in each
    // row. The hull of these points is the hull of the area.
    static List<(double X, double Y)> Edges(bool[] area, int w, int h)
    {
        var points = new List<(double X, double Y)>();
        for (var y = 0; y < h; y++)
        {
            var first = -1;
            var last = -1;
            for (var x = 0; x < w; x++)
            {
                if (area[y * w + x])
                {
                    if (first < 0)
                    {
                        first = x;
                    }
                    last = x;
                }
            }
            if (first >= 0)
            {
                points.Add((first, y));
                points.Add((first, y + 1));
                points.Add((last + 1, y));
                points.Add((last + 1, y + 1));
            }
        }
        return points;
    }

    // The convex hull with the monotone chain of Andrew, without points on
    // a straight edge.
    static List<(double X, double Y)> Hull(List<(double X, double Y)> points)
    {
        var sorted = points.Distinct().OrderBy(p => p.X).ThenBy(p => p.Y).ToArray();
        if (sorted.Length < 3)
        {
            return [.. sorted];
        }
        var hull = new List<(double X, double Y)>();
        foreach (var pass in new[] { sorted, sorted.Reverse().ToArray() })
        {
            var start = hull.Count;
            foreach (var p in pass)
            {
                while (hull.Count >= start + 2 && Cross(hull[^2], hull[^1], p) <= 0)
                {
                    hull.RemoveAt(hull.Count - 1);
                }
                hull.Add(p);
            }
            hull.RemoveAt(hull.Count - 1);
        }
        return hull;
    }

    static double Cross((double X, double Y) o, (double X, double Y) a, (double X, double Y) b) =>
        (a.X - o.X) * (b.Y - o.Y) - (a.Y - o.Y) * (b.X - o.X);

    // The 4 points of the convex polygon that span the largest area, in
    // the order of the polygon. For each pair of opposite corners, the best
    // third and fourth corners are the farthest points on each side.
    static (double X, double Y)[] LargestQuad(List<(double X, double Y)> hull)
    {
        var n = hull.Count;
        var best = -1.0;
        var corners = new int[4];
        for (var i = 0; i < n; i++)
        {
            for (var k = i + 2; k < n; k++)
            {
                double left = -1, right = -1;
                int bj = -1, bl = -1;
                for (var j = i + 1; j < k; j++)
                {
                    var a = Math.Abs(Cross(hull[i], hull[j], hull[k]));
                    if (a > left)
                    {
                        left = a;
                        bj = j;
                    }
                }
                for (var l = k + 1; l < n + i; l++)
                {
                    var a = Math.Abs(Cross(hull[i], hull[k], hull[l % n]));
                    if (a > right)
                    {
                        right = a;
                        bl = l % n;
                    }
                }
                if (bj < 0 || bl < 0 || left + right <= best)
                {
                    continue;
                }
                best = left + right;
                corners = [i, bj, k, bl];
            }
        }
        return corners.Select(c => hull[c]).ToArray();
    }

    // The area of a polygon with the shoelace formula.
    static double Area((double X, double Y)[] p)
    {
        double sum = 0;
        for (var i = 0; i < p.Length; i++)
        {
            var a = p[i];
            var b = p[(i + 1) % p.Length];
            sum += a.X * b.Y - b.X * a.Y;
        }
        return Math.Abs(sum) / 2;
    }

    static double Distance((double X, double Y) a, (double X, double Y) b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    // Puts the 4 corners of a convex quadrilateral in the order top left,
    // top right, bottom right, bottom left. The top left corner is nearest
    // to the top left corner of the image, and the order goes clockwise on
    // the screen, where y points down.
    static (double X, double Y)[] Order((double X, double Y)[] corners)
    {
        // The order top left, top right, bottom right, bottom left gives a
        // positive shoelace sum when y points down. A negative sum means
        // the other way.
        var signed = 0.0;
        for (var i = 0; i < 4; i++)
        {
            var a = corners[i];
            var b = corners[(i + 1) % 4];
            signed += a.X * b.Y - b.X * a.Y;
        }
        var list = signed < 0 ? corners.Reverse().ToArray() : corners;
        var first = Array.IndexOf(list, list.MinBy(p => p.X + p.Y));
        return Enumerable.Range(0, 4).Select(i => list[(first + i) % 4]).ToArray();
    }
}
