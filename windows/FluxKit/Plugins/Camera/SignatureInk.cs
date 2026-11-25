namespace FluxKit;

// The ink of a signature. Alpha holds 1 byte for each pixel, row by row,
// from 0 for paper to 255 for ink. Original is the mean color of the ink as
// 0xRRGGBB.
public sealed class SignatureInk(int width, int height, byte[] alpha, int original)
{
    public int Width { get; } = width;
    public int Height { get; } = height;
    public byte[] Alpha { get; } = alpha;
    public int Original { get; } = original;

    // Returns the ARGB pixels of the signature in rgb, on a transparent background.
    public uint[] Pixels(int rgb)
    {
        var color = (uint)(rgb & 0xFFFFFF);
        return Alpha.Select(a => ((uint)a << 24) | color).ToArray();
    }
}

// The colors that the signature can have.
public enum InkColor
{
    Black,
    Blue,
    Original,
}

public static class InkColors
{
    public static readonly IReadOnlyList<InkColor> All = [InkColor.Black, InkColor.Blue, InkColor.Original];

    public static string Label(this InkColor c) => c switch
    {
        InkColor.Black => "Black",
        InkColor.Blue => "Blue",
        _ => "Original",
    };

    // The color as 0xRRGGBB, or null for the color of the pen.
    public static int? Rgb(this InkColor c) => c switch
    {
        InkColor.Black => 0x000000,
        InkColor.Blue => 0x1A3DB0,
        _ => null,
    };

    public static int Of(this InkColor c, SignatureInk ink) => c.Rgb() ?? ink.Original;
}

// A rectangle in image pixels.
public readonly record struct SignatureCrop(int Left, int Top, int Width, int Height);

// A rectangle in a view, in device-independent pixels.
public readonly record struct ViewRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
}

// Cuts the ink of a signature out of a photo of paper, like Flux for
// Android. The steps remove uneven light, find the split between paper and
// ink, remove specks and dark areas at the border, and crop to the ink.
// SignatureInk.swift of the Mac app has the same steps.
public static class SignatureCut
{
    // The largest image that Extract reads.
    public const int MaxPixels = 8_000_000;

    // The largest side of the image that the ink comes from.
    public const int MaxSide = 1600;

    // Returns the ink in argb, an image of width by height pixels as
    // 0xAARRGGBB, row by row. It returns null when the image has no ink.
    public static SignatureInk? Extract(uint[] argb, int width, int height)
    {
        if (width <= 0 || height <= 0 || argb.Length != width * height)
        {
            throw new ArgumentException("The pixels do not match the size");
        }
        if ((long)width * height > MaxPixels)
        {
            throw new ArgumentException("The image is too large");
        }
        var luma = new int[argb.Length];
        for (var i = 0; i < argb.Length; i++)
        {
            var c = argb[i];
            luma[i] = (77 * (int)((c >> 16) & 0xFF) + 150 * (int)((c >> 8) & 0xFF) + 29 * (int)(c & 0xFF)) >> 8;
        }
        var dark = Darkness(luma, width, height);
        var split = Math.Min(Math.Max(Otsu(dark), 0.08f), 0.40f);
        var alpha = Ramp(dark, split * 0.6f, Math.Min(split * 1.4f, 0.95f));
        KeepStrokes(alpha, width, height);
        if (InkBounds(alpha, width, height) is not { } box)
        {
            return null;
        }
        // The mean color of the pixels that are surely ink.
        long r = 0, g = 0, b = 0, core = 0;
        for (var y = box.MinY; y <= box.MaxY; y++)
        {
            for (var x = box.MinX; x <= box.MaxX; x++)
            {
                if (alpha[y * width + x] < 230)
                {
                    continue;
                }
                var c = argb[y * width + x];
                r += (c >> 16) & 0xFF;
                g += (c >> 8) & 0xFF;
                b += c & 0xFF;
                core++;
            }
        }
        if (core == 0)
        {
            return null;
        }
        return Crop(alpha, width, height, box, (int)(r / core) << 16 | (int)(g / core) << 8 | (int)(b / core));
    }

    // Crops alpha that is already clean, such as a drawn signature, to the
    // ink with the same margin as Extract. It returns null without ink.
    public static SignatureInk? Ink(byte[] alpha, int width, int height, int original)
    {
        if (alpha.Length != width * height)
        {
            throw new ArgumentException("The pixels do not match the size");
        }
        var values = alpha.Select(a => (int)a).ToArray();
        return InkBounds(values, width, height) is { } box ? Crop(values, width, height, box, original) : null;
    }

    // Maps a frame in a view to the image that the view shows with aspect
    // fill: the image fills the view and the overflow is cut off equally on
    // both sides. pad enlarges the frame by that part of its size on each
    // side. The result stays inside the image.
    public static SignatureCrop FrameInImage(float left, float top, float right, float bottom,
                                             int viewWidth, int viewHeight, int imageWidth, int imageHeight, float pad = 0)
    {
        var scale = Math.Max((float)viewWidth / imageWidth, (float)viewHeight / imageHeight);
        var offsetX = (viewWidth - imageWidth * scale) / 2;
        var offsetY = (viewHeight - imageHeight * scale) / 2;
        var padX = (right - left) * pad;
        var padY = (bottom - top) * pad;
        var x0 = Math.Clamp(Round((left - padX - offsetX) / scale), 0, imageWidth - 1);
        var y0 = Math.Clamp(Round((top - padY - offsetY) / scale), 0, imageHeight - 1);
        var x1 = Math.Clamp(Round((right + padX - offsetX) / scale), x0 + 1, imageWidth);
        var y1 = Math.Clamp(Round((bottom + padY - offsetY) / scale), y0 + 1, imageHeight);
        return new SignatureCrop(x0, y0, x1 - x0, y1 - y0);
    }

    // The guide frame, 5 by 2, in the center of a view. It is 88% of the
    // width when the height allows it.
    public static ViewRect GuideFrame(double width, double height)
    {
        var w = width * 0.88;
        var h = w * 0.4;
        if (h > height * 0.6)
        {
            h = height * 0.6;
            w = h * 2.5;
        }
        return new ViewRect((width - w) / 2, (height - h) / 2, w, h);
    }

    // Rounds half up, like roundToInt of Kotlin.
    static int Round(float v) => (int)MathF.Floor(v + 0.5f);

    // Returns how much darker each pixel is than the paper around it, from
    // 0 to 1. The paper is the mean of a large window. A second pass leaves
    // out the pixels that look like ink, so dense strokes do not darken the
    // paper.
    static float[] Darkness(int[] luma, int w, int h)
    {
        var radius = Math.Max(12, Math.Max(w, h) / 20);
        var ones = new int[luma.Length];
        Array.Fill(ones, 1);
        var first = BoxMean(luma, ones, w, h, radius, null);
        var paper = new int[luma.Length];
        var paperLuma = new int[luma.Length];
        for (var i = 0; i < luma.Length; i++)
        {
            paper[i] = luma[i] * 100 >= first[i] * 85 ? 1 : 0;
            paperLuma[i] = luma[i] * paper[i];
        }
        var second = BoxMean(paperLuma, paper, w, h, radius, first);
        var output = new float[luma.Length];
        for (var i = 0; i < luma.Length; i++)
        {
            var bg = Math.Max(second[i], 1);
            output[i] = Math.Min(Math.Max(1 - luma[i] / bg, 0), 1);
        }
        return output;
    }

    // Returns the sum of values divided by the sum of weights in a square
    // window around each pixel. Where the window has no weight, the result
    // comes from fallback.
    static float[] BoxMean(int[] values, int[] weights, int w, int h, int r, float[]? fallback)
    {
        var sv = Integral(values, w, h);
        var sw = Integral(weights, w, h);
        var stride = w + 1;
        var output = new float[w * h];
        for (var y = 0; y < h; y++)
        {
            var y0 = Math.Max(0, y - r);
            var y1 = Math.Min(h, y + r + 1);
            for (var x = 0; x < w; x++)
            {
                var x0 = Math.Max(0, x - r);
                var x1 = Math.Min(w, x + r + 1);
                var v = sv[y1 * stride + x1] - sv[y0 * stride + x1] - sv[y1 * stride + x0] + sv[y0 * stride + x0];
                var c = sw[y1 * stride + x1] - sw[y0 * stride + x1] - sw[y1 * stride + x0] + sw[y0 * stride + x0];
                output[y * w + x] = c > 0 ? (float)v / c : fallback?[y * w + x] ?? 255;
            }
        }
        return output;
    }

    // Returns the summed-area table of a, with 1 extra row and column of zeros.
    static long[] Integral(int[] a, int w, int h)
    {
        var stride = w + 1;
        var s = new long[stride * (h + 1)];
        for (var y = 0; y < h; y++)
        {
            long row = 0;
            for (var x = 0; x < w; x++)
            {
                row += a[y * w + x];
                s[(y + 1) * stride + x + 1] = s[y * stride + x + 1] + row;
            }
        }
        return s;
    }

    // Returns the split between paper and ink with the method of Otsu, from 0 to 1.
    static float Otsu(float[] dark)
    {
        const int bins = 256;
        var hist = new int[bins];
        foreach (var v in dark)
        {
            hist[Round(v * (bins - 1))]++;
        }
        double total = dark.Length;
        var sumAll = 0.0;
        for (var i = 0; i < bins; i++)
        {
            sumAll += (double)i * hist[i];
        }
        double sumBack = 0, countBack = 0, best = 0;
        var split = 0;
        for (var i = 0; i < bins; i++)
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
        return (float)split / (bins - 1);
    }

    // Maps darkness to alpha with a smooth step from low to high, so edges stay soft.
    static int[] Ramp(float[] dark, float low, float high)
    {
        var output = new int[dark.Length];
        for (var i = 0; i < dark.Length; i++)
        {
            var s = Math.Min(Math.Max((dark[i] - low) / (high - low), 0), 1);
            output[i] = Round(s * s * (3 - 2 * s) * 255);
        }
        return output;
    }

    // Keeps the strokes and removes the rest. A stroke is a connected area
    // of pixels with alpha of 128 or more. The step removes specks, and
    // solid areas that touch the border, such as a table, a shadow, or the
    // edge of the paper. Thin strokes fill only a small part of their box.
    // Soft edge pixels stay only next to a stroke that stays.
    static void KeepStrokes(int[] alpha, int w, int h)
    {
        var n = w * h;
        var label = new int[n];
        var stack = new int[n];
        var minSize = Math.Max(4, n / 60_000);
        // keepLabel[k - 1] tells whether the stroke with label k stays.
        var keepLabel = new List<bool>();
        var next = 0;
        for (var start = 0; start < n; start++)
        {
            if (alpha[start] < 128 || label[start] != 0)
            {
                continue;
            }
            next++;
            var top = 0;
            stack[top++] = start;
            label[start] = next;
            var size = 0;
            int minX = w, minY = h, maxX = -1, maxY = -1;
            var border = false;
            while (top > 0)
            {
                var p = stack[--top];
                size++;
                var x = p % w;
                var y = p / w;
                minX = Math.Min(minX, x);
                maxX = Math.Max(maxX, x);
                minY = Math.Min(minY, y);
                maxY = Math.Max(maxY, y);
                if (x == 0 || y == 0 || x == w - 1 || y == h - 1)
                {
                    border = true;
                }
                for (var ny = Math.Max(0, y - 1); ny <= Math.Min(h - 1, y + 1); ny++)
                {
                    for (var nx = Math.Max(0, x - 1); nx <= Math.Min(w - 1, x + 1); nx++)
                    {
                        var q = ny * w + nx;
                        if (alpha[q] >= 128 && label[q] == 0)
                        {
                            label[q] = next;
                            stack[top++] = q;
                        }
                    }
                }
            }
            var boxArea = (long)(maxX - minX + 1) * (maxY - minY + 1);
            var solid = border && size * 100L > boxArea * 35;
            keepLabel.Add(size >= minSize && !solid);
        }
        var keep = new bool[n];
        for (var i = 0; i < n; i++)
        {
            keep[i] = label[i] != 0 && keepLabel[label[i] - 1];
        }
        // Soft pixels stay within 2 pixels of a stroke that stays.
        var near = Grow(Grow(keep, w, h), w, h);
        for (var i = 0; i < n; i++)
        {
            if (!near[i])
            {
                alpha[i] = 0;
            }
        }
    }

    // Returns mask grown by 1 pixel in the 8 directions.
    static bool[] Grow(bool[] mask, int w, int h)
    {
        var output = new bool[mask.Length];
        for (var y = 0; y < h; y++)
        {
            for (var x = 0; x < w; x++)
            {
                if (!mask[y * w + x])
                {
                    continue;
                }
                for (var ny = Math.Max(0, y - 1); ny <= Math.Min(h - 1, y + 1); ny++)
                {
                    for (var nx = Math.Max(0, x - 1); nx <= Math.Min(w - 1, x + 1); nx++)
                    {
                        output[ny * w + nx] = true;
                    }
                }
            }
        }
        return output;
    }

    readonly record struct Bounds(int MinX, int MinY, int MaxX, int MaxY);

    // The box of the pixels with some alpha, or null when there are none.
    static Bounds? InkBounds(int[] alpha, int w, int h)
    {
        int minX = w, minY = h, maxX = -1, maxY = -1;
        for (var y = 0; y < h; y++)
        {
            for (var x = 0; x < w; x++)
            {
                if (alpha[y * w + x] == 0)
                {
                    continue;
                }
                minX = Math.Min(minX, x);
                maxX = Math.Max(maxX, x);
                minY = Math.Min(minY, y);
                maxY = Math.Max(maxY, y);
            }
        }
        return maxX < 0 ? null : new Bounds(minX, minY, maxX, maxY);
    }

    // Crops to the ink with a margin.
    static SignatureInk Crop(int[] alpha, int w, int h, Bounds box, int original)
    {
        var margin = Math.Max(8, Math.Max(box.MaxX - box.MinX, box.MaxY - box.MinY) / 40);
        var left = box.MinX - margin;
        var top = box.MinY - margin;
        var cw = box.MaxX - box.MinX + 1 + 2 * margin;
        var ch = box.MaxY - box.MinY + 1 + 2 * margin;
        var output = new byte[cw * ch];
        for (var y = 0; y < ch; y++)
        {
            var sy = top + y;
            if (sy < 0 || sy >= h)
            {
                continue;
            }
            for (var x = 0; x < cw; x++)
            {
                var sx = left + x;
                if (sx < 0 || sx >= w)
                {
                    continue;
                }
                output[y * cw + x] = (byte)alpha[sy * w + sx];
            }
        }
        return new SignatureInk(cw, ch, output, original);
    }
}
