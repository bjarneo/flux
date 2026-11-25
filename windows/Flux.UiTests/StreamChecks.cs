using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Flux;
using FluxKit;
using static Harness;

// The streams: the Stream tools of Control, the microphone page, the webcam
// and screen mirror page, the tray actions, the window of a stream page, the
// prompt of a stream request, the renderer of the webcam, and the H.264
// encoder of Media Foundation.
public static class StreamChecks
{
    public static void Run(Harness h)
    {
        h.ApplyDevices();
        Pump();
        Tools(h);
        Mic(h);
        Stream(h);
        Tray(h);
        Windows(h);
        Prompt(h);
        Renderer(h);
        Encoder(h);
        h.Model.SetScope(null);
        h.Model.Go(Destination.Chat);
        Pump();
    }

    // The 3 tools under Stream in Control.
    static void Tools(Harness h)
    {
        var window = h.Window;
        h.Model.Go(Destination.Control);
        Pump();
        h.Check(Shows(window, "Stream"), "Control shows the Stream group");
        h.Check(Shows(window, "Mic") && Shows(window, "Webcam") && Shows(window, "Mirror"), "Control shows the Mic, Webcam, and Mirror tools");
        h.Model.Go(Destination.Chat);
        Pump();
    }

    // The microphone page: the live state, the input, the note, and the
    // privacy setting.
    static void Mic(Harness h)
    {
        var window = h.Window;
        var paired = h.Paired;
        var mic = h.Core.Plugin<MicPlugin>()!;
        h.Model.Go(Destination.Control);
        h.Model.Push(new Route.Feature(Card.Mic, paired.Id));
        Pump();
        // The page reads the permission when it opens, so the samples come after it.
        mic.Model.Permission = MicPermission.Granted;
        mic.Model.Inputs = ValueList.From(new[] { new MicInput("in-1", "USB Microphone"), new MicInput("in-2", "Headset") });
        mic.Model.Input = "in-1";
        mic.Model.Status = new StreamStatus(StreamPhase.Live, "Live on omarchy-xps as Flux Microphone", paired.Id);
        mic.Model.Level = 0.5f;
        Pump();
        h.Check(window.CurrentPage is MicPage, "the Mic tool opens the microphone page");
        h.Check(Shows(window, "Microphone") && Shows(window, "Live"), "the microphone page shows that the stream is live");
        h.Check(Shows(window, "Live on omarchy-xps as Flux Microphone"), "the microphone page shows the state of the stream");
        h.Check(Shows(window, "Input") && Shows(window, "USB Microphone"), "the microphone page shows the chosen input");
        h.Check(Shows(window, "Apps on omarchy-xps see this computer as Flux Microphone."), "the microphone page tells what the computer sees");
        h.Check(Shows(window, "Stop"), "the microphone page shows Stop while the stream runs");

        mic.Model.Status = StreamStatus.None;
        mic.Model.Input = "gone";
        Pump();
        h.Check(Shows(window, "Ready to use this computer as a microphone on omarchy-xps."), "the microphone page shows the idle text");
        h.Check(Shows(window, "Disconnected Input"), "the microphone page names an input that is gone");
        h.Check(Shows(window, "Start"), "the microphone page shows Start");

        mic.Model.Permission = MicPermission.Denied;
        Pump();
        h.Check(Shows(window, "Flux cannot use the microphone") && Shows(window, "Open Privacy Settings"),
            "the microphone page tells how to allow the microphone");

        mic.RefreshPermission();
        mic.Model.Inputs = ValueList<MicInput>.Empty;
        mic.Model.Input = "";
        mic.Model.Level = 0;
        h.Model.Go(Destination.Chat);
        Pump();
    }

    // The webcam and screen mirror page with its 2 cards and the image settings.
    static void Stream(Harness h)
    {
        var window = h.Window;
        var paired = h.Paired;
        var webcam = h.Core.Plugin<WebcamPlugin>()!;
        var screen = h.Core.Plugin<ScreenPlugin>()!;
        h.Model.Go(Destination.Control);
        h.Model.Push(new Route.Feature(Card.Stream, paired.Id));
        Pump();
        // The page reads the displays when it opens, so the samples come after it.
        var display = new DisplayInfo(@"\\.\DISPLAY1", "Display 1", 2560, 1440);
        screen.Model.Displays = ValueList.From(new[] { display });
        screen.Model.Display = display.Id;
        screen.Model.HasAccess = true;
        var camera = new CameraDevice("cam-1", "Integrated Camera", true);
        webcam.Model.Cameras = ValueList.From(CameraNames.Name([camera]));
        webcam.Model.Status = new StreamStatus(StreamPhase.Live, "Live on omarchy-xps as Flux Camera", paired.Id);
        webcam.Model.Preview = SampleImage();
        Pump();
        h.Check(window.CurrentPage is StreamPage, "the Webcam tool opens the stream page");
        h.Check(Shows(window, "Webcam") && Shows(window, "Live on omarchy-xps as Flux Camera"), "the webcam card shows the live state");
        h.Check(Shows(window, "Camera") && Shows(window, "Integrated Camera"), "the webcam card shows the chosen camera");
        h.Check(Shows(window, "Also send the microphone") && Shows(window, "Apps on the computer also get Flux Microphone"),
            "the webcam card shows Also send the microphone");
        h.Check(Shows(window, "Screen Mirror") && Shows(window, "Show a display of this computer in a window on omarchy-xps."),
            "the mirror card shows its idle text");
        h.Check(Shows(window, "Display 1 (2560 × 1440)"), "the mirror card shows the display and its size");
        h.Check(Shows(window, "Image settings"), "the webcam card shows the line of the image settings");

        Click(window, "Show Image settings of Webcam");
        h.Check(Shows(window, "Shape") && Shows(window, "16:9") && Shows(window, "720p"), "the image settings show the shape and the resolution");
        h.Check(Shows(window, "Mirror the image") && Shows(window, "Zoom") && Shows(window, "1.0×"), "the image settings show the mirror and the zoom");
        h.Check(Shows(window, "Exposure") && Shows(window, "+0.0 EV") && Shows(window, "Warmth"), "the image settings show the exposure and the colors");
        h.Check(Shows(window, "Reset Image"), "the image settings show Reset Image");
        Click(window, "Hide Image settings of Webcam");
        h.Check(!Shows(window, "Reset Image"), "the image settings close");

        webcam.Model.Status = new StreamStatus(StreamPhase.Error, "Another app uses Integrated Camera", paired.Id);
        screen.Model.HasAccess = false;
        Pump();
        h.Check(Shows(window, "Another app uses Integrated Camera"), "the webcam card shows an error");
        h.Check(Shows(window, "This version of Windows cannot record the screen."), "the mirror card tells that Windows cannot record");

        webcam.Model.Status = StreamStatus.None;
        webcam.Model.Preview = null;
        screen.Model.HasAccess = true;
        h.Model.Go(Destination.Chat);
        Pump();
    }

    // The actions of the tray panel for a computer.
    static void Tray(Harness h)
    {
        var paired = h.Paired;
        var webcam = h.Core.Plugin<WebcamPlugin>()!;
        var screen = h.Core.Plugin<ScreenPlugin>()!;
        var titles = TrayActions.For(h.Model, paired).Select(a => a.Title).ToList();
        h.Check(titles.Contains("Start Microphone"), "the tray starts the microphone");
        h.Check(!titles.Contains("Stop Webcam") && !titles.Contains("Stop Screen Mirror"), "the tray shows no stop without a stream");
        webcam.Model.Status = new StreamStatus(StreamPhase.Live, "Live", paired.Id);
        screen.Model.Status = new StreamStatus(StreamPhase.Live, "Mirrors to omarchy-xps", paired.Id);
        titles = TrayActions.For(h.Model, paired).Select(a => a.Title).ToList();
        h.Check(titles.Contains("Stop Webcam") && titles.Contains("Stop Screen Mirror"), "the tray stops the webcam and the mirror");
        webcam.Model.Status = StreamStatus.None;
        screen.Model.Status = StreamStatus.None;
        Pump();
    }

    // The window of a stream page, as a click on start opens it.
    static void Windows(Harness h)
    {
        var paired = h.Paired;
        StreamWindows.Show(h.Model, Card.Mic, paired.Id);
        Pump();
        h.Check(StreamWindows.All.Count == 1, "the microphone page opens in a window");
        if (StreamWindows.All.FirstOrDefault() is { } w)
        {
            h.Check(w.Title == "Microphone for omarchy-xps", $"the window names the page and the computer, not {w.Title}");
            h.Check(Shows(w, "Microphone"), "the window shows the microphone page");
        }
        StreamWindows.Show(h.Model, Card.Mic, paired.Id);
        Pump();
        h.Check(StreamWindows.All.Count == 1, "a second open shows the same window");
        StreamWindows.Show(h.Model, Card.Stream, h.Found.Id);
        Pump();
        h.Check(StreamWindows.All.Count == 1, "a computer that is not paired opens no window");
        StreamWindows.CloseAll();
        Pump();
        h.Check(StreamWindows.All.Count == 0, "the stream windows close");
    }

    // The prompt of a stream request, its texts, and its end.
    static void Prompt(Harness h)
    {
        var paired = h.Paired;
        var requests = h.Core.Plugin<StreamRequestPlugin>()!;
        h.Check(requests.Incoming.Contains(PacketType.StreamRequest), "this computer takes stream requests");
        var webcam = new StreamRequest(paired.Id, "omarchy-xps", StreamRequestKind.Webcam, StreamRequest.Now);
        requests.Model.Requests = ValueList.From(new[] { webcam });
        StreamRequestWindow.Present(requests);
        Pump();
        if (StreamRequestWindow.Shown is not { } prompt)
        {
            h.Check(false, "the prompt of the request opens");
            return;
        }
        h.Check(prompt.Title == "Flux", "the prompt has the title Flux");
        h.Check(Shows(prompt, "omarchy-xps asks for the webcam"), "the prompt asks for the webcam");
        h.Check(Shows(prompt, "Apps on omarchy-xps see this computer as Flux Camera. The camera stays off until you select Start webcam."),
            "the prompt tells what the start does");
        h.Check(Shows(prompt, "Not now") && Shows(prompt, "Start webcam"), "the prompt shows Not now and Start webcam");

        var mic = new StreamRequest(paired.Id, "omarchy-xps", StreamRequestKind.Mic, StreamRequest.Now);
        requests.Model.Requests = ValueList.From(new[] { webcam, mic });
        Pump();
        h.Check(Shows(prompt, "omarchy-xps asks for the mic") && Shows(prompt, "Start the mic"), "the prompt shows the newest request");

        requests.Model.Requests = ValueList<StreamRequest>.Empty;
        Pump();
        h.Check(StreamRequestWindow.Shown is null, "the prompt closes when no request is open");
    }

    // The renderer of the webcam on the CPU: the orientation, the mirror,
    // the rotation, the exposure, the colors, and the preview.
    static void Renderer(Harness h)
    {
        var renderer = new CpuFrameRenderer();
        // Red at the top left, green at the top right, blue at the bottom
        // left, and white at the bottom right.
        var source = new BgraFrame(8, 8);
        for (var y = 0; y < 8; y++)
        {
            for (var x = 0; x < 8; x++)
            {
                var (r, g, b) = (y < 4, x < 4) switch
                {
                    (true, true) => (255, 0, 0),
                    (true, false) => (0, 255, 0),
                    (false, true) => (0, 0, 255),
                    _ => (255, 255, 255),
                };
                Put(source, x, y, r, g, b);
            }
        }
        var plain = (BgraFrame)renderer.Render(source, 8, 8, 0, new WebcamLook())!;
        h.Check(Pixel(plain, 1, 1) == (255, 0, 0) && Pixel(plain, 6, 1) == (0, 255, 0) && Pixel(plain, 1, 6) == (0, 0, 255),
            "the renderer keeps the image upright");
        var mirrored = (BgraFrame)renderer.Render(source, 8, 8, 0, new WebcamLook(Mirror: true))!;
        h.Check(Pixel(mirrored, 1, 1) == (0, 255, 0) && Pixel(mirrored, 6, 1) == (255, 0, 0), "the mirror swaps left and right");
        var turned = (BgraFrame)renderer.Render(source, 8, 8, 90, new WebcamLook())!;
        h.Check(Pixel(turned, 1, 1) == (0, 0, 255) && Pixel(turned, 6, 1) == (255, 0, 0), "a rotation of 90 degrees turns the image clockwise");
        var zoomed = (BgraFrame)renderer.Render(source, 8, 8, 0, new WebcamLook(Zoom: 2))!;
        h.Check(Pixel(zoomed, 0, 0) == (255, 0, 0) && Pixel(zoomed, 7, 7) == (255, 255, 255), "the zoom shows the center of the image");

        var gray = new BgraFrame(4, 4);
        for (var i = 0; i < 16; i++)
        {
            Put(gray, i % 4, i / 4, 128, 128, 128);
        }
        var brighter = Pixel((BgraFrame)renderer.Render(gray, 4, 4, 0, new WebcamLook(Exposure: 1))!, 1, 1);
        h.Check(brighter.R is > 160 and < 190 && brighter.R == brighter.B, $"1 EV more doubles the light of gray, not {brighter}");
        var flat = Pixel((BgraFrame)renderer.Render(source, 8, 8, 0, new WebcamLook(Color: new ColorAdjust(Saturation: 0)))!, 1, 1);
        h.Check(flat.R == flat.G && flat.G == flat.B, $"a saturation of 0 gives gray, not {flat}");

        h.Check(renderer.Preview(plain, 4) is BitmapSource { PixelWidth: 4, PixelHeight: 4, IsFrozen: true }, "the preview is a small frozen image");
        h.Check(renderer.Render(source, 8, 8, 0, new WebcamLook()) is BgraFrame { Version: var v } && v % 2 == 0, "the renderer ends each write");
    }

    // Encodes synthetic frames with the H.264 encoder of Media Foundation,
    // and shows them through the video output of the remote desktop.
    static void Encoder(Harness h)
    {
        const int width = 320;
        const int height = 192;
        const int count = 35;
        var units = new List<byte[]>();
        string? failure = null;
        var output = new EncodedVideo(units.Add, f => failure = f);
        MediaFoundationEncoder encoder;
        try
        {
            encoder = MediaFoundationEncoder.Open(new VideoEncoderSettings(width, height, 1_000_000), output);
        }
        catch (StreamException e)
        {
            Console.WriteLine($"SKIP: the H.264 encoder of Media Foundation: {e.Message}: {e.InnerException?.Message}");
            return;
        }
        using (encoder)
        {
            for (var i = 0; i < count; i++)
            {
                encoder.Encode(Synthetic(width, height, i), keyFrame: i == 0);
            }
        }
        h.Check(failure is null, $"the encoder does not fail: {failure}");
        h.Check(units.Count == count, $"the encoder gives {count} access units, not {units.Count}");
        if (units.Count == 0)
        {
            return;
        }
        var first = AnnexB.NalTypes(units[0]);
        h.Check(first.Contains(AnnexB.NalSps) && first.Contains(AnnexB.NalPps) && first.Contains(AnnexB.NalIdr),
            "the first access unit has the SPS, the PPS, and an IDR frame");
        var sps = Unit(units[0], AnnexB.NalSps);
        h.Check(sps is { Length: > 3 } && sps[1] == 77, $"the stream has the Main profile, not {sps?.ElementAtOrDefault(1)}");
        h.Check(sps is { Length: > 3 } && sps[3] == 41, $"the stream has level 4.1, not {sps?.ElementAtOrDefault(3)}");
        var keys = units.Count(u => AnnexB.NalTypes(u).Contains(AnnexB.NalIdr));
        h.Check(keys >= 2, $"the encoder gives a key frame each 30 frames, {keys} in {count} frames");

        try
        {
            H264Decoder.Open().Dispose();
        }
        catch (NotSupportedException e)
        {
            Console.WriteLine($"SKIP: the decode of the encoded frames: {e.Message}: {e.InnerException?.Message}");
            return;
        }
        BitmapSource? shown = null;
        string? decodeFailure = null;
        var video = new MediaFoundationVideo(Dispatcher.CurrentDispatcher, b => shown = b ?? shown, f => decodeFailure = f);
        foreach (var unit in units)
        {
            Wait(() => video.IsReady);
            video.Decode(unit, AnnexB.NalTypes(unit).Contains(AnnexB.NalIdr));
        }
        Wait(() => shown is not null || decodeFailure is not null);
        // The last pictures come after the first.
        Wait(() => false, 0.5);
        h.Check(decodeFailure is null && shown is { PixelWidth: width, PixelHeight: height }, $"the decoder shows the encoded frames: {decodeFailure}");
        if (shown is { PixelWidth: width, PixelHeight: height } bitmap)
        {
            var pixels = new byte[width * height * 4];
            bitmap.CopyPixels(pixels, width * 4, 0);
            // The 4 gray bars of the frames, in the rows below the moving square.
            for (var bar = 0; bar < 4; bar++)
            {
                var expected = 32 + bar * 64;
                var at = (150 * width + bar * 80 + 40) * 4;
                var got = (pixels[at] + pixels[at + 1] + pixels[at + 2]) / 3;
                h.Check(Math.Abs(got - expected) <= 12, $"bar {bar + 1} keeps its gray {expected} through the encoder, not {got}");
            }
        }
        video.Dispose();
    }

    // A frame with 4 gray bars and a white square that moves.
    static BgraFrame Synthetic(int width, int height, int index)
    {
        var frame = new BgraFrame(width, height);
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var v = 32 + x / (width / 4) * 64;
                if (y is >= 8 and < 40 && x >= index * 8 && x < index * 8 + 32)
                {
                    v = 255;
                }
                Put(frame, x, y, v, v, v);
            }
        }
        return frame;
    }

    // The NAL unit of the type without its start code, or null.
    static byte[]? Unit(byte[] data, byte type)
    {
        var starts = AnnexB.NalStarts(data);
        for (var i = 0; i < starts.Count; i++)
        {
            var start = starts[i];
            if (start < data.Length && (data[start] & 0x1F) == type)
            {
                var end = i + 1 < starts.Count ? starts[i + 1] - 3 : data.Length;
                return data[start..end];
            }
        }
        return null;
    }

    static void Put(BgraFrame f, int x, int y, int r, int g, int b)
    {
        var at = (y * f.Width + x) * 4;
        f.Pixels[at] = (byte)b;
        f.Pixels[at + 1] = (byte)g;
        f.Pixels[at + 2] = (byte)r;
        f.Pixels[at + 3] = 255;
    }

    static (int R, int G, int B) Pixel(BgraFrame f, int x, int y)
    {
        var at = (y * f.Width + x) * 4;
        return (f.Pixels[at + 2], f.Pixels[at + 1], f.Pixels[at]);
    }

    static BitmapSource SampleImage()
    {
        var image = BitmapSource.Create(4, 4, 96, 96, PixelFormats.Bgr32, null, new byte[64], 16);
        image.Freeze();
        return image;
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
}
