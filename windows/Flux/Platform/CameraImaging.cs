using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using FluxKit;
using SoftwareBitmap = Windows.Graphics.Imaging.SoftwareBitmap;
using BitmapPixelFormat = Windows.Graphics.Imaging.BitmapPixelFormat;
using BitmapAlphaMode = Windows.Graphics.Imaging.BitmapAlphaMode;
using Windows.Media.Ocr;

namespace Flux;

// A failure of a camera mode, with a message for the user.
public sealed class CameraException(string message, Exception? inner = null) : Exception(message, inner);

// The image files of the camera modes with the imaging of WPF: decode a file
// upright, encode JPEG, and read images from the clipboard, a drop, or a
// file dialog. CameraImages.swift and CameraInput.swift of the Mac app have
// the same jobs.
public static class CameraImaging
{
    // The errors that WPF and WIC give for a file that is not a readable image.
    static bool Unreadable(Exception e) =>
        e is NotSupportedException or FileFormatException or IOException or ArgumentException or InvalidOperationException or
            COMException or OverflowException or UnauthorizedAccessException or ExternalException;

    // Decodes an image file upright, with its largest side at most maxSide.
    // It throws CameraException with the name of the file.
    public static BgraImage Load(string path, int maxSide = CameraImages.MaxStillSide)
    {
        try
        {
            return Decode(File.ReadAllBytes(path), maxSide);
        }
        catch (Exception e) when (Unreadable(e))
        {
            throw new CameraException($"Cannot open {Path.GetFileName(path)}", e);
        }
    }

    // Decodes image data upright, with its largest side at most maxSide. A
    // JPEG turns by its EXIF orientation, as the Mac does. Large images
    // shrink in the decoder, so that they take little memory.
    public static BgraImage Decode(byte[] data, int maxSide = CameraImages.MaxStillSide)
    {
        try
        {
            int width, height, orientation;
            using (var probe = new MemoryStream(data, writable: false))
            {
                var decoder = BitmapDecoder.Create(probe, BitmapCreateOptions.DelayCreation | BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.None);
                var frame = decoder.Frames[0];
                width = frame.PixelWidth;
                height = frame.PixelHeight;
                orientation = Orientation(frame);
            }
            var (w, _) = CameraImages.Fit(width, height, maxSide);
            var image = new BitmapImage();
            image.BeginInit();
            image.StreamSource = new MemoryStream(data, writable: false);
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            if (w != width)
            {
                // The decoder keeps the aspect.
                image.DecodePixelWidth = w;
            }
            image.EndInit();
            image.Freeze();
            return FromBitmap(image, maxSide).Upright(orientation);
        }
        catch (Exception e) when (Unreadable(e) && e is not CameraException)
        {
            throw new CameraException("Cannot read the image", e);
        }
    }

    // The EXIF orientation of the frame, or 1 when it has none.
    static int Orientation(BitmapFrame frame)
    {
        BitmapMetadata? metadata;
        try
        {
            metadata = frame.Metadata as BitmapMetadata;
        }
        catch (Exception e) when (e is NotSupportedException or InvalidOperationException or COMException)
        {
            // A format such as BMP has no metadata.
            return 1;
        }
        foreach (var query in new[] { "/app1/ifd/{ushort=274}", "/ifd/{ushort=274}" })
        {
            try
            {
                if (metadata?.GetQuery(query) is ushort value)
                {
                    return value;
                }
            }
            catch (Exception e) when (e is NotSupportedException or InvalidOperationException or ArgumentException or COMException)
            {
                // The format has no such block.
            }
        }
        return 1;
    }

    // Copies a bitmap into 32-bit BGRA, with its largest side at most maxSide.
    public static BgraImage FromBitmap(BitmapSource source, int maxSide = CameraImages.MaxStillSide)
    {
        BitmapSource bgra = source.Format == PixelFormats.Bgra32 ? source : new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        var w = bgra.PixelWidth;
        var h = bgra.PixelHeight;
        if (w <= 0 || h <= 0)
        {
            throw new CameraException("The image is empty");
        }
        var pixels = new byte[w * h * 4];
        bgra.CopyPixels(pixels, w * 4, 0);
        return new BgraImage(w, h, pixels).Scaled(maxSide);
    }

    // A frozen bitmap of the image that WPF can show.
    public static BitmapSource ToBitmap(BgraImage image)
    {
        var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgra32, null, image.Pixels, image.Width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    // A frozen bitmap of the signature in the color, on a transparent background.
    public static BitmapSource InkBitmap(SignatureInk ink, int rgb)
    {
        var pixels = new byte[ink.Width * ink.Height * 4];
        for (var i = 0; i < ink.Alpha.Length; i++)
        {
            pixels[i * 4] = (byte)rgb;
            pixels[i * 4 + 1] = (byte)(rgb >> 8);
            pixels[i * 4 + 2] = (byte)(rgb >> 16);
            pixels[i * 4 + 3] = ink.Alpha[i];
        }
        var bitmap = BitmapSource.Create(ink.Width, ink.Height, 96, 96, PixelFormats.Bgra32, null, pixels, ink.Width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    // Encodes the image as JPEG with the quality from 0 to 100. Transparent
    // parts become white paper.
    public static byte[] Jpeg(BgraImage image, int quality)
    {
        var argb = image.Argb();
        var pixels = new byte[argb.Length * 4];
        Buffer.BlockCopy(argb, 0, pixels, 0, pixels.Length);
        var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgr32, null, pixels, image.Width * 4);
        var encoder = new JpegBitmapEncoder { QualityLevel = Math.Clamp(quality, 1, 100) };
        encoder.Frames.Add(BitmapFrame.Create(new FormatConvertedBitmap(bitmap, PixelFormats.Bgr24, null, 0)));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    // Input

    // The extensions that Open Image offers.
    const string Filter = "Images|*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.tif;*.tiff;*.heic;*.webp|All files|*.*";

    // Asks for image files and decodes them upright. A file that does not
    // read goes to fail with its message.
    public static IReadOnlyList<BgraImage> Open(Window? owner, bool multiple, Action<string> fail)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = Filter, Multiselect = multiple, Title = multiple ? "Open Images" : "Open Image" };
        if (dialog.ShowDialog(owner) != true)
        {
            return [];
        }
        return LoadAll(dialog.FileNames, fail);
    }

    static List<BgraImage> LoadAll(IEnumerable<string> paths, Action<string> fail)
    {
        var images = new List<BgraImage>();
        foreach (var path in paths)
        {
            try
            {
                images.Add(Load(path));
            }
            catch (CameraException e)
            {
                fail(e.Message);
            }
        }
        return images;
    }

    // Returns the image on the clipboard: an image file, PNG data, or a
    // bitmap. It returns null when the clipboard has no image.
    public static BgraImage? Paste()
    {
        try
        {
            if (Clipboard.ContainsFileDropList())
            {
                foreach (var path in Clipboard.GetFileDropList())
                {
                    if (path is not null && File.Exists(path))
                    {
                        try
                        {
                            return Load(path);
                        }
                        catch (CameraException)
                        {
                            // Not an image. The next file may be one.
                        }
                    }
                }
            }
            // Browsers and the Snipping Tool put PNG data on the clipboard,
            // with its transparency.
            if (Clipboard.GetData("PNG") is MemoryStream png)
            {
                return Decode(png.ToArray());
            }
            if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } bitmap)
            {
                return FromBitmap(bitmap);
            }
        }
        catch (Exception e) when (e is ExternalException or CameraException)
        {
            FluxLog.Info("camera", $"the clipboard image did not read: {e.GetType().Name}");
        }
        return null;
    }

    // True when the drop holds files or an image.
    public static bool CanDrop(IDataObject data) => data.GetDataPresent(DataFormats.FileDrop) || data.GetDataPresent(DataFormats.Bitmap) || data.GetDataPresent("PNG");

    // Decodes the dropped image files or image data.
    public static IReadOnlyList<BgraImage> Dropped(IDataObject data, Action<string> fail)
    {
        try
        {
            if (data.GetData(DataFormats.FileDrop) is string[] files)
            {
                return LoadAll(files.Where(File.Exists), fail);
            }
            if (data.GetData("PNG") is MemoryStream png)
            {
                return [Decode(png.ToArray())];
            }
            if (data.GetData(DataFormats.Bitmap) is BitmapSource bitmap)
            {
                return [FromBitmap(bitmap)];
            }
        }
        catch (Exception e) when (e is ExternalException or CameraException)
        {
            fail("Cannot open the image");
        }
        return [];
    }
}

// The text recognition of Windows, in the languages of the user profile.
// VisionScan.swift of the Mac app reads text with Vision.
public static class CameraOcr
{
    public const string NoLanguage =
        "Windows has no text recognition for your languages. Add a language with Optical character recognition in Settings > Time & language > Language & region";

    // The engine for the languages of the user, or null when Windows has none.
    public static OcrEngine? Engine()
    {
        try
        {
            return OcrEngine.TryCreateFromUserProfileLanguages();
        }
        catch (Exception e) when (e is COMException or UnauthorizedAccessException)
        {
            FluxLog.Info("camera", $"text recognition did not start: {e.Message}");
            return null;
        }
    }

    // Returns the text lines of an upright image, in pixels. It throws
    // CameraException when Windows cannot read text.
    public static async Task<IReadOnlyList<ScanLine>> LinesAsync(BgraImage image, OcrEngine? engine = null)
    {
        engine ??= Engine() ?? throw new CameraException(NoLanguage);
        // The engine reads images up to its largest side.
        var max = (int)Math.Min(OcrEngine.MaxImageDimension, int.MaxValue);
        var scaled = image.Scaled(max);
        var factor = (double)image.Width / scaled.Width;
        var argb = scaled.Argb();
        var pixels = new byte[argb.Length * 4];
        Buffer.BlockCopy(argb, 0, pixels, 0, pixels.Length);
        try
        {
            using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(pixels.AsBuffer(), BitmapPixelFormat.Bgra8, scaled.Width, scaled.Height, BitmapAlphaMode.Premultiplied);
            var result = await engine.RecognizeAsync(bitmap);
            var lines = new List<ScanLine>();
            foreach (var line in result.Lines)
            {
                if (line.Words.Count == 0)
                {
                    continue;
                }
                var left = line.Words.Min(w => w.BoundingRect.X);
                var top = line.Words.Min(w => w.BoundingRect.Y);
                var right = line.Words.Max(w => w.BoundingRect.X + w.BoundingRect.Width);
                var bottom = line.Words.Max(w => w.BoundingRect.Y + w.BoundingRect.Height);
                lines.Add(new ScanLine(line.Text, new ScanBox((int)Math.Round(left * factor), (int)Math.Round(top * factor),
                    (int)Math.Round(right * factor), (int)Math.Round(bottom * factor))));
            }
            return lines;
        }
        catch (Exception e) when (e is COMException or ArgumentException or InvalidOperationException)
        {
            throw new CameraException("Cannot read the image", e);
        }
    }

    // Returns the text blocks of an upright image.
    public static async Task<IReadOnlyList<ScanBlock>> TextAsync(BgraImage image) =>
        TextAssembly.Blocks(await LinesAsync(image).ConfigureAwait(false));
}
