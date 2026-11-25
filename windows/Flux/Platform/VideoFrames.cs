using System.Windows.Media;
using System.Windows.Media.Imaging;
using FluxKit;

namespace Flux;

// A video frame in 32-bit BGRA in managed memory: 4 bytes for each pixel and
// no gap between the rows. The camera, the renderer, and the screen capture
// give this type, and the H.264 encoder takes it. A FrameRing writes later
// frames into the same memory, so a reader checks the version: it reads the
// version before and after it reads the pixels. When both are the same even
// number, no write ran during the read.
public sealed class BgraFrame : IVideoFrame
{
    int version;

    public BgraFrame(int width, int height)
    {
        Width = width;
        Height = height;
        Pixels = new byte[width * height * 4];
    }

    public int Width { get; }
    public int Height { get; }
    public int Stride => Width * 4;
    public byte[] Pixels { get; }

    // An odd version means that a write runs now.
    public int Version => Volatile.Read(ref version);

    internal void BeginWrite() => Interlocked.Increment(ref version);

    internal void EndWrite() => Interlocked.Increment(ref version);
}

// The frames of 1 producer, used again in turn, so that 30 frames each
// second do not each take new memory. The encoder keeps the last frame for a
// repeat after 100 ms. With 4 frames, the producer writes 3 frames before it
// writes into that frame again, and the version check of the encoder finds
// the rare overlap.
public sealed class FrameRing(int count = 4)
{
    readonly BgraFrame?[] frames = new BgraFrame?[count];
    int next;

    // The next frame of the size, with its write started. The caller writes
    // the pixels and then calls EndWrite.
    public BgraFrame Next(int width, int height)
    {
        var f = frames[next];
        if (f is null || f.Width != width || f.Height != height)
        {
            f = new BgraFrame(width, height);
            frames[next] = f;
        }
        next = (next + 1) % frames.Length;
        f.BeginWrite();
        return f;
    }
}

// Pixel work on BGRA frames: the scale for the screen and the preview, the
// conversion to NV12 for the encoder, and the preview image for WPF.
public static class Bgra
{
    // Scales src into dst. Each pixel of dst is the mean of the pixels of
    // src that it covers, so that small text stays readable after a large
    // reduction. A larger dst repeats the pixels. The rows run in parallel.
    public static void Scale(byte[] src, int srcWidth, int srcHeight, byte[] dst, int dstWidth, int dstHeight)
    {
        if (srcWidth == dstWidth && srcHeight == dstHeight)
        {
            Buffer.BlockCopy(src, 0, dst, 0, dstWidth * dstHeight * 4);
            return;
        }
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
                int b = 0, g = 0, r = 0;
                var n = (y1 - y0) * (x1 - x0);
                for (var yy = y0; yy < y1; yy++)
                {
                    var p = (yy * srcWidth + x0) * 4;
                    for (var xx = x0; xx < x1; xx++)
                    {
                        b += src[p];
                        g += src[p + 1];
                        r += src[p + 2];
                        p += 4;
                    }
                }
                dst[at] = (byte)(b / n);
                dst[at + 1] = (byte)(g / n);
                dst[at + 2] = (byte)(r / n);
                dst[at + 3] = 255;
                at += 4;
            }
        });
    }

    // Converts a frame to NV12 with the BT.709 matrix in limited range, as
    // the encoder announces: the Y plane with width bytes in each row, then
    // the plane of the interleaved U and V samples of each 2x2 block. The
    // factors are the BT.709 factors times 219 or 224 over 255, times 256.
    public static void ToNv12(byte[] src, int width, int height, byte[] dst)
    {
        var uvStart = width * height;
        Parallel.For(0, (height + 1) / 2, pair =>
        {
            var top = pair * 2;
            var bottom = Math.Min(top + 1, height - 1);
            var uv = uvStart + pair * width;
            for (var x = 0; x < width; x += 2)
            {
                var right = Math.Min(x + 1, width - 1);
                int sr = 0, sg = 0, sb = 0;
                Luma(src, dst, top * width + x, ref sr, ref sg, ref sb);
                Luma(src, dst, top * width + right, ref sr, ref sg, ref sb);
                Luma(src, dst, bottom * width + x, ref sr, ref sg, ref sb);
                Luma(src, dst, bottom * width + right, ref sr, ref sg, ref sb);
                if (uv + x + 1 < dst.Length)
                {
                    dst[uv + x] = Clamp(128 + ((-26 * sr - 86 * sg + 112 * sb + 512) >> 10));
                    dst[uv + x + 1] = Clamp(128 + ((112 * sr - 102 * sg - 10 * sb + 512) >> 10));
                }
            }
        });
    }

    // Writes the Y sample of pixel i and adds its colors to the sums of its
    // 2x2 block.
    static void Luma(byte[] src, byte[] dst, int i, ref int sr, ref int sg, ref int sb)
    {
        var p = i * 4;
        int b = src[p], g = src[p + 1], r = src[p + 2];
        dst[i] = (byte)(16 + ((47 * r + 157 * g + 16 * b + 128) >> 8));
        sr += r;
        sg += g;
        sb += b;
    }

    // A frozen copy of the frame, at most maxWidth pixels wide, that WPF can
    // show on the UI thread.
    public static BitmapSource Preview(BgraFrame frame, int maxWidth)
    {
        var w = Math.Max(1, Math.Min(maxWidth, frame.Width));
        var h = Math.Max(1, (int)Math.Round((double)frame.Height * w / frame.Width));
        var pixels = new byte[w * h * 4];
        Scale(frame.Pixels, frame.Width, frame.Height, pixels, w, h);
        var image = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgr32, null, pixels, w * 4);
        image.Freeze();
        return image;
    }

    static byte Clamp(int v) => (byte)(v < 0 ? 0 : v > 255 ? 255 : v);
}

// Draws the camera frames of the webcam on the CPU. FrameGeometry places the
// image for the rotation, the mirror, and the zoom, with a bilinear sample.
// Then the exposure gain applies in linear light, and the matrix of
// ColorAdjust applies to the encoded values. The colors stay inside 0 to 1,
// and no color management runs, so the preview shows what the computer
// gets. The rows run in parallel, so a 1080p frame takes a few milliseconds.
// The webcam calls it on the thread of the camera, 1 call at a time.
public sealed class CpuFrameRenderer : IFrameRenderer
{
    readonly FrameRing ring = new();
    readonly byte[] exposure = new byte[256];
    double exposureGain = double.NaN;

    public IVideoFrame? Render(IVideoFrame camera, int width, int height, int rotation, WebcamLook look)
    {
        if (camera is not BgraFrame src || width <= 0 || height <= 0 || src.Width <= 0 || src.Height <= 0)
        {
            return null;
        }
        var version = src.Version;
        if ((version & 1) != 0)
        {
            return null;
        }
        // The map goes from the camera to the output in coordinates with y
        // up. The draw needs the other way.
        var map = FrameGeometry.Transform(rotation, src.Width, src.Height, width, height, look.Mirror, look.Zoom).Inverted();
        var lut = Exposure(look.ExposureGain);
        var colors = look.Colors;
        var output = ring.Next(width, height);
        try
        {
            Draw(src, output, map, lut, colors.IsNeutral ? null : Matrix(colors));
        }
        finally
        {
            output.EndWrite();
        }
        return src.Version == version ? output : null;
    }

    public object? Preview(IVideoFrame frame, int maxWidth) => frame is BgraFrame f ? Bgra.Preview(f, maxWidth) : null;

    // The 3 rows of the color matrix and the bias, as 12 floats.
    static float[] Matrix(ColorAdjust c)
    {
        var rows = c.Rows;
        var bias = c.Bias;
        return
        [
            (float)rows[0][0], (float)rows[0][1], (float)rows[0][2], (float)bias[0],
            (float)rows[1][0], (float)rows[1][1], (float)rows[1][2], (float)bias[1],
            (float)rows[2][0], (float)rows[2][1], (float)rows[2][2], (float)bias[2],
        ];
    }

    // The table of the exposure for each 8-bit value: from sRGB to linear
    // light, times the gain, and back to sRGB. Null for the gain 1.
    byte[]? Exposure(double gain)
    {
        if (Math.Abs(gain - 1) < 1e-6)
        {
            return null;
        }
        if (gain != exposureGain)
        {
            exposureGain = gain;
            for (var v = 0; v < 256; v++)
            {
                var c = v / 255.0;
                var linear = c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
                linear = Math.Min(1, linear * gain);
                var encoded = linear <= 0.0031308 ? linear * 12.92 : 1.055 * Math.Pow(linear, 1 / 2.4) - 0.055;
                exposure[v] = (byte)Math.Clamp(Math.Round(encoded * 255), 0, 255);
            }
        }
        return exposure;
    }

    static void Draw(BgraFrame src, BgraFrame dst, Affine map, byte[]? lut, float[]? m)
    {
        var sw = src.Width;
        var sh = src.Height;
        var dw = dst.Width;
        var dh = dst.Height;
        var s = src.Pixels;
        var d = dst.Pixels;
        Parallel.For(0, dh, row =>
        {
            // The center of the first pixel of the row, in output coordinates
            // with y up. The camera image has its first row at the top, so
            // its y flips back.
            var y = dh - (row + 0.5);
            var (cx, cy) = map.Apply(0.5, y);
            var px = cx - 0.5;
            var py = sh - cy - 0.5;
            var dx = map.A;
            var dy = -map.B;
            var at = row * dw * 4;
            for (var x = 0; x < dw; x++)
            {
                var x0 = (int)Math.Floor(px);
                var y0 = (int)Math.Floor(py);
                var fx = (float)(px - x0);
                var fy = (float)(py - y0);
                var xa = Math.Clamp(x0, 0, sw - 1);
                var xb = Math.Clamp(x0 + 1, 0, sw - 1);
                var ya = Math.Clamp(y0, 0, sh - 1);
                var yb = Math.Clamp(y0 + 1, 0, sh - 1);
                var p00 = (ya * sw + xa) * 4;
                var p01 = (ya * sw + xb) * 4;
                var p10 = (yb * sw + xa) * 4;
                var p11 = (yb * sw + xb) * 4;
                var w00 = (1 - fx) * (1 - fy);
                var w01 = fx * (1 - fy);
                var w10 = (1 - fx) * fy;
                var w11 = fx * fy;
                var b = s[p00] * w00 + s[p01] * w01 + s[p10] * w10 + s[p11] * w11;
                var g = s[p00 + 1] * w00 + s[p01 + 1] * w01 + s[p10 + 1] * w10 + s[p11 + 1] * w11;
                var r = s[p00 + 2] * w00 + s[p01 + 2] * w01 + s[p10 + 2] * w10 + s[p11 + 2] * w11;
                if (lut is not null)
                {
                    b = lut[(int)(b + 0.5f)];
                    g = lut[(int)(g + 0.5f)];
                    r = lut[(int)(r + 0.5f)];
                }
                if (m is not null)
                {
                    var rn = r / 255f;
                    var gn = g / 255f;
                    var bn = b / 255f;
                    r = (m[0] * rn + m[1] * gn + m[2] * bn + m[3]) * 255f;
                    g = (m[4] * rn + m[5] * gn + m[6] * bn + m[7]) * 255f;
                    b = (m[8] * rn + m[9] * gn + m[10] * bn + m[11]) * 255f;
                }
                d[at] = Byte(b);
                d[at + 1] = Byte(g);
                d[at + 2] = Byte(r);
                d[at + 3] = 255;
                at += 4;
                px += dx;
                py += dy;
            }
        });
    }

    static byte Byte(float v) => v <= 0 ? (byte)0 : v >= 255 ? (byte)255 : (byte)(v + 0.5f);
}
