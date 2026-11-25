using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Flux;
using FluxKit;
using static Harness;

// The camera modes and the screenshots: the tools of the tray of a chat, the
// tray action, the setting Send new screenshots, the camera window in each mode
// with sample images, the text recognition of Windows, the QR decoder, the
// PDF, the signature PNG, the EXIF orientation, the screenshot folder, and
// the screen capture.
public static class CameraChecks
{
    public static void Run(Harness h)
    {
        // The modes await their work, and it must come back to this thread.
        var context = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        try
        {
            h.ApplyDevices();
            Pump();
            Tools(h);
            Settings(h);
            Window(h);
            Region(h);
            Ocr(h);
            Qr(h);
            Pdf(h);
            Signature(h);
            Orientation(h);
            Screenshots(h);
        }
        finally
        {
            CameraWindows.CloseAll();
            Pump();
            SynchronizationContext.SetSynchronizationContext(context);
        }
        h.Check(CameraWindows.All.Count == 0, "the camera windows close");
        h.Model.SetScope(null);
        h.Model.Go(Destination.Chat);
        Pump();
    }

    // Runs the UI thread until the condition is true, for at most the time.
    static void Wait(Func<bool> done, double seconds = 10)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (!done() && DateTime.UtcNow < end)
        {
            Pump();
            Thread.Sleep(20);
        }
    }

    static T Await<T>(Task<T> task, double seconds = 30)
    {
        Wait(() => task.IsCompleted, seconds);
        return task.GetAwaiter().GetResult();
    }

    static void Await(Task task, double seconds = 30)
    {
        Wait(() => task.IsCompleted, seconds);
        task.GetAwaiter().GetResult();
    }

    static bool HasButton(DependencyObject root, string name) =>
        Buttons(root).Any(b => System.Windows.Automation.AutomationProperties.GetName(b) == name);

    // An image of the size in 1 color, opaque.
    static BgraImage Plain(int w, int h, byte b, byte g, byte r)
    {
        var pixels = new byte[w * h * 4];
        for (var i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = b;
            pixels[i + 1] = g;
            pixels[i + 2] = r;
            pixels[i + 3] = 255;
        }
        return new BgraImage(w, h, pixels);
    }

    // A photo of a white page on a dark desk.
    static BgraImage Page()
    {
        var image = Plain(400, 300, 60, 60, 60);
        for (var y = 50; y < 250; y++)
        {
            for (var x = 90; x < 310; x++)
            {
                var at = (y * 400 + x) * 4;
                image.Pixels[at] = image.Pixels[at + 1] = image.Pixels[at + 2] = 235;
            }
        }
        return image;
    }

    // The text in black on white, as a still image.
    static BgraImage Rendered(string text, double size)
    {
        var block = new TextBlock { Text = text, FontSize = size, FontFamily = new FontFamily("Segoe UI"), Foreground = Brushes.Black };
        var paper = new Border { Child = block, Background = Brushes.White, Padding = new Thickness(40) };
        paper.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        paper.Arrange(new Rect(paper.DesiredSize));
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(paper.ActualWidth), (int)Math.Ceiling(paper.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(paper);
        return CameraImaging.FromBitmap(bitmap);
    }

    // A QR code of ZXing as a PNG file, black on white.
    static byte[] QrPng(string text)
    {
        var matrix = new ZXing.QrCode.QRCodeWriter().encode(text, ZXing.BarcodeFormat.QR_CODE, 0, 0);
        const int scale = 8;
        var w = matrix.Width * scale;
        var h = matrix.Height * scale;
        var image = Plain(w, h, 255, 255, 255);
        for (var y = 0; y < h; y++)
        {
            for (var x = 0; x < w; x++)
            {
                if (matrix[x / scale, y / scale])
                {
                    var at = (y * w + x) * 4;
                    image.Pixels[at] = image.Pixels[at + 1] = image.Pixels[at + 2] = 0;
                }
            }
        }
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(CameraImaging.ToBitmap(image)));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    // The tools of the tray of a chat and the action of the tray menu.
    static void Tools(Harness h)
    {
        var titles = ChatDock.Tools.Select(t => t(h.Model, h.Paired)).OfType<(string Title, string Glyph, Action Run)>().Select(t => t.Title).ToArray();
        h.Check(new[] { "Camera", "Scan", "Text", "QR", "Signature" }.All(titles.Contains),
            $"the tray has Camera, Scan, Text, QR, and Signature, not {string.Join(", ", titles)}");
        h.Check(TrayActions.For(h.Model, h.Paired).Any(a => a.Title == "Camera…"), "the tray menu of a computer has Camera…");
    }

    // Send new screenshots in Settings > Features.
    static void Settings(Harness h)
    {
        var capture = h.Core.Plugin<CaptureWatchPlugin>();
        h.Check(capture is not null, "the app has the capture watch");
        Wait(() => capture?.Model.ScreenshotFolder.Length > 0, 5);
        var settings = new SettingsWindow(h.Model);
        settings.Show();
        Pump();
        Click(settings, "Features");
        h.Check(Shows(settings, "Send by themselves") && Shows(settings, "Send new screenshots"), "the settings show Send new screenshots");
        h.Check(Shows(settings, "Screenshots wait until a computer connects"), "the settings tell that screenshots wait");
        h.Check(capture?.Model.Screenshots == false, "Send new screenshots is off by default");
        settings.Close();
    }

    // The camera window in each mode, with sample images in place of the camera.
    static void Window(Harness h)
    {
        var w = CameraWindows.Show(h.Model, h.Paired, CameraMode.Text);
        var m = w.Model;
        Wait(() => m.Camera.Listed);
        Pump();
        h.Check(w.Title == "Camera for omarchy-xps", $"the window names the computer, not {w.Title}");
        h.Check(new[] { "Text", "QR", "Photo", "Document", "Signature" }.All(t => Shows(w, t)), "the mode bar shows the 5 modes");
        h.Check(Shows(w, "Scan text and send it") && Shows(w, "From Image") && HasButton(w, "Scan Text"), "Text mode shows its hint, its sources, and its shutter");
        var cameraState = m.Camera.Denied ? "Flux cannot use the camera" : m.Camera.Cameras.Count == 0 ? "No camera found" : null;
        h.Check(cameraState is null || Shows(w, cameraState), $"the stage tells why the camera does not show: {cameraState}");
        if (m.Camera.Cameras.Count == 0)
        {
            Console.WriteLine("SKIP: the live camera: the runner has no camera");
        }

        // Text: a result to edit and send, then no text.
        m.Text.Image = Rendered("Invoice 0925", 40);
        m.Text.Text = "Invoice 0925\n\nTotal 12.40";
        m.Text.Found = true;
        m.Text.State = TextScan.Phase.Result;
        Pump();
        h.Check(Shows(w, "Total 12.40") && HasButton(w, "Send to omarchy-xps") && HasButton(w, "Retake") && HasButton(w, "Clear"),
            "Text mode shows the text with Send, Retake, and Clear");
        h.Check(HasButton(w, "Dictate"), "Text mode has the mic key");
        h.Check(w.View.SendText(), "Ctrl+Enter sends the text");
        Pump();
        h.Check(Shows(w, "Not connected"), "a send to a computer without a link says Not connected");
        m.Text.Text = "";
        m.Text.Found = false;
        Pump();
        h.Check(Shows(w, "No text found. Move closer or add light."), "Text mode tells when it found no text");
        m.Text.Retake();
        Pump();
        h.Check(HasButton(w, "Scan Text"), "Retake shows the shutter again");

        // QR: a code from an image, then an image without a code.
        m.Mode = CameraMode.Qr;
        Pump();
        h.Check(Shows(w, "Read a QR code or barcode") && Shows(w, "Point the camera at a code"), "QR mode shows its hint");
        var qr = CameraImaging.Decode(QrPng("https://omarchy.org/flux"));
        m.Use([qr]);
        Wait(() => m.Codes.State != CodeScan.Phase.Live);
        Pump();
        h.Check(Shows(w, "QR code · Link") && Shows(w, "https://omarchy.org/flux"), "QR mode shows the type and the value of the code");
        h.Check(HasButton(w, "Open on omarchy-xps") && HasButton(w, "Copy on omarchy-xps") && HasButton(w, "Scan Again"), "QR mode shows the actions of a link");
        m.Codes.Again();
        Await(m.Codes.ReadAsync(Plain(200, 200, 230, 230, 230)));
        Pump();
        h.Check(Shows(w, "No code found in this image."), "QR mode tells when an image has no code");
        m.Codes.Again();

        // Photo: the shutter, and a photo that did not go out.
        m.Mode = CameraMode.Photo;
        Pump();
        h.Check(Shows(w, "Take a photo for the computer") && HasButton(w, "Take Photo"), "Photo mode shows its hint and its shutter");
        h.Check(!Shows(w, "From Image") && !m.AcceptsImages, "Photo mode takes photos with the camera only");
        m.Photo.Thumb = Plain(64, 48, 0, 128, 255);
        m.Photo.Failure = "Not connected";
        m.Photo.State = PhotoShots.Phase.Failed;
        Pump();
        h.Check(Shows(w, "Click to send again"), "Photo mode offers to send a failed photo again");
        m.Photo.State = PhotoShots.Phase.None;

        // Document: 2 pages, 1 found on a desk and 1 whole image, and a send.
        m.Mode = CameraMode.Document;
        Pump();
        h.Check(Shows(w, "Scan pages to a PDF") && Shows(w, "Send PDF") && HasButton(w, "Add Page"), "Document mode shows its hint, Send PDF, and its shutter");
        Await(m.Document.AddAsync([Page(), Plain(300, 400, 200, 200, 200)]));
        Pump();
        h.Check(m.Document.Pages.Count == 2 && m.Document.Pages[0].Flat is not null && m.Document.Pages[1].Flat is null, "Document mode finds the page on the desk");
        h.Check(Shows(w, "Send PDF, 2 pages") && Shows(w, "2 · whole image"), "Document mode shows the pages");
        Await(m.Document.SendAsync());
        Pump();
        h.Check(Shows(w, "Not connected") && m.Document.Pages.Count == 2, "a PDF that does not go out keeps its pages");
        m.Document.Remove(m.Document.Pages[1].Id);
        Pump();
        h.Check(Shows(w, "Send PDF, 1 page"), "a page goes away");

        // Signature: paper, then a drawing.
        m.Mode = CameraMode.Signature;
        Pump();
        h.Check(Shows(w, "Sign on paper or draw, paste on the computer") && Shows(w, "Paper") && Shows(w, "Draw") && HasButton(w, "Capture Signature"),
            "Signature mode shows its sources and its shutter");
        m.Signature.From = SignatureCapture.Source.Draw;
        Pump();
        h.Check(Shows(w, "Sign here with the mouse, a pen, or a touch screen") && HasButton(w, "Undo") && HasButton(w, "Done"), "Draw shows the canvas");
        m.Signature.Drawing.Add([new InkPoint(60, 120), new InkPoint(160, 100), new InkPoint(260, 130)]);
        m.Signature.DrawingChanged();
        Pump();
        w.View.UndoInk();
        Pump();
        h.Check(m.Signature.Drawing.IsEmpty, "Ctrl+Z removes the stroke");
        m.Signature.Drawing.Add([new InkPoint(60, 120), new InkPoint(160, 100), new InkPoint(260, 130)]);
        m.Signature.DrawingChanged();
        m.Signature.FinishDrawing(400, 200);
        Pump();
        h.Check(m.Signature.Ink is not null && Shows(w, "Black") && Shows(w, "Blue") && !Shows(w, "Original"), "a drawn signature offers black and blue");
        h.Check(HasButton(w, "Draw Again") && HasButton(w, "Send to omarchy-xps"), "a drawn signature shows Draw Again and Send");
        m.Signature.From = SignatureCapture.Source.Camera;
        var paper = Rendered("Dan Kim", 64);
        Await(m.Signature.CutAsync(paper, null));
        Pump();
        h.Check(m.Signature.Ink is not null && Shows(w, "Original") && HasButton(w, "Retake"), "a signature on paper offers its own color");
        m.Signature.Retake();

        m.Show("Sent to omarchy-xps");
        Pump();
        h.Check(Shows(w, "Sent to omarchy-xps"), "the window shows a short message");
        w.Close();
        Pump();
    }

    // The window that picks a part of the screen.
    static void Region(Harness h)
    {
        var region = new RegionWindow(Plain(64, 48, 40, 40, 40));
        region.Show();
        Pump();
        h.Check(Shows(region, "Drag over the part of the screen to read. Esc cancels."), "the screen region tells what to do");
        region.Close();
        if (ScreenRegion.Capture() is { } shot)
        {
            h.Check(shot.Width > 0 && shot.Height > 0, "the capture of the screen has pixels");
        }
        else
        {
            Console.WriteLine("SKIP: the capture of the screen: the runner has no screen to capture");
        }
    }

    // The text recognition of Windows on an image with known text.
    static void Ocr(Harness h)
    {
        if (CameraOcr.Engine() is null)
        {
            Console.WriteLine("SKIP: the text recognition of Windows: the runner has no OCR language");
            return;
        }
        var image = Rendered("Flux reads this text", 48);
        var text = TextAssembly.Assemble(Await(CameraOcr.TextAsync(image)));
        h.Check(text.Contains("reads this text", StringComparison.OrdinalIgnoreCase), $"the OCR reads the text, not {text}");
    }

    // A QR code in a PNG file, decoded with WPF and read with ZXing.
    static void Qr(Harness h)
    {
        var image = CameraImaging.Decode(QrPng("WIFI:S:home;T:WPA;P:secret;;"));
        var found = CodeReader.Read(image);
        h.Check(found.Count == 1 && found[0].Code.Wifi == new WifiInfo("home", "secret", "WPA"), "the QR decoder reads a Wi-Fi code from a PNG");
    }

    // A PDF of 2 JPEG pages from the encoder of WPF.
    static void Pdf(Harness h)
    {
        var first = CameraImaging.Jpeg(Page(), CameraImages.PageQuality);
        var second = CameraImaging.Jpeg(Plain(300, 500, 255, 255, 255), CameraImages.PageQuality);
        h.Check(CameraImages.JpegInfo(first) == (400, 300, 3), $"the JPEG of WPF has a frame header that the PDF reads: {CameraImages.JpegInfo(first)}");
        var path = Path.Combine(Path.GetTempPath(), $"flux-check-{Guid.NewGuid():N}.pdf");
        try
        {
            File.WriteAllBytes(path, CameraImages.Pdf([first, second]));
            var text = Encoding.Latin1.GetString(File.ReadAllBytes(path));
            h.Check(text.StartsWith("%PDF-1.4\n", StringComparison.Ordinal) && text.EndsWith("%%EOF\n", StringComparison.Ordinal), "the PDF has its header and its end");
            h.Check(text.Contains("/Count 2", StringComparison.Ordinal) && Regex.Matches(text, @"/Type /Page\b").Count == 2, "the PDF has 2 pages");
            var start = int.Parse(Regex.Match(text, @"startxref\n(\d+)\n").Groups[1].Value);
            h.Check(text[start..].StartsWith("xref\n", StringComparison.Ordinal), "the PDF points at its cross-reference table");
        }
        finally
        {
            File.Delete(path);
        }
    }

    // The PNG of a signature is transparent around the ink.
    static void Signature(Harness h)
    {
        var drawing = new SignatureDrawing();
        drawing.Add([new InkPoint(20, 40), new InkPoint(120, 20), new InkPoint(220, 50)]);
        var ink = drawing.Ink(240, 80)!;
        var png = CameraImages.Png(ink, InkColor.Blue.Rgb()!.Value);
        var decoder = new PngBitmapDecoder(new MemoryStream(png), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var frame = new FormatConvertedBitmap(decoder.Frames[0], PixelFormats.Bgra32, null, 0);
        var pixels = new byte[frame.PixelWidth * frame.PixelHeight * 4];
        frame.CopyPixels(pixels, frame.PixelWidth * 4, 0);
        h.Check(frame.PixelWidth == ink.Width && frame.PixelHeight == ink.Height, "the PNG has the size of the ink");
        h.Check(pixels[3] == 0 && pixels[^1] == 0, "the corners of the signature PNG are transparent");
        var opaque = Enumerable.Range(0, pixels.Length / 4).Where(i => pixels[i * 4 + 3] == 255).ToArray();
        h.Check(opaque.Length > 100, "the ink of the signature PNG is opaque");
        h.Check(opaque.Length > 0 && pixels[opaque[0] * 4] == 0xB0 && pixels[opaque[0] * 4 + 1] == 0x3D && pixels[opaque[0] * 4 + 2] == 0x1A,
            "the ink has the blue of the choice");
        h.Check(CameraImaging.InkBitmap(ink, 0) is { IsFrozen: true } b && b.PixelWidth == ink.Width, "the preview of the ink is a frozen image");
    }

    // A JPEG with the EXIF orientation 6 turns upright.
    static void Orientation(Harness h)
    {
        var image = Plain(40, 20, 0, 0, 0);
        for (var y = 0; y < 20; y++)
        {
            for (var x = 0; x < 20; x++)
            {
                image.Pixels[(y * 40 + x) * 4 + 2] = 255;
            }
        }
        byte[] data;
        try
        {
            var metadata = new BitmapMetadata("jpg");
            metadata.SetQuery("/app1/ifd/{ushort=274}", (ushort)6);
            var encoder = new JpegBitmapEncoder { QualityLevel = 95 };
            encoder.Frames.Add(BitmapFrame.Create(CameraImaging.ToBitmap(image), null, metadata, null));
            using var output = new MemoryStream();
            encoder.Save(output);
            data = output.ToArray();
        }
        catch (Exception e) when (e is NotSupportedException or InvalidOperationException or ArgumentException or System.Runtime.InteropServices.COMException)
        {
            Console.WriteLine($"SKIP: a JPEG with an EXIF orientation: {e.Message}");
            return;
        }
        var upright = CameraImaging.Decode(data);
        h.Check(upright.Width == 20 && upright.Height == 40, $"the orientation 6 turns the photo, not {upright.Width} by {upright.Height}");
        // The red left half is at the top after a clockwise turn.
        h.Check(upright.Pixels[(5 * 20 + 10) * 4 + 2] > 200 && upright.Pixels[(35 * 20 + 10) * 4 + 2] < 60, "the red half is at the top");
    }

    // The Screenshots folder of Windows.
    static void Screenshots(Harness h)
    {
        var folder = new WindowsScreenshots().ScreenshotFolder();
        h.Check(folder is not null && Path.IsPathRooted(folder), $"Windows names the Screenshots folder: {folder}");
    }
}
