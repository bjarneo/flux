using System.Net.Sockets;
using System.Security.Authentication;
using System.Text.Json.Nodes;
using System.Windows.Threading;
using FluxKit;

namespace Flux;

// The modes of the camera window, in the order of the mode bar. Webcam
// streaming is a feature of its own.
public enum CameraMode
{
    Text,
    Qr,
    Photo,
    Document,
    Signature,
}

public static class CameraModes
{
    public static readonly IReadOnlyList<CameraMode> All = [CameraMode.Text, CameraMode.Qr, CameraMode.Photo, CameraMode.Document, CameraMode.Signature];

    // The glyphs that the kit does not have: the pen of a signature, a
    // crop for a part of the screen, and undo.
    public const string SignatureGlyph = "";
    public const string RegionGlyph = "";
    public const string UndoGlyph = "";

    public static string Label(this CameraMode m) => m switch
    {
        CameraMode.Text => "Text",
        CameraMode.Qr => "QR",
        CameraMode.Photo => "Photo",
        CameraMode.Document => "Document",
        _ => "Signature",
    };

    public static string Glyph(this CameraMode m) => m switch
    {
        CameraMode.Text => Icons.Text,
        CameraMode.Qr => Icons.QrCode,
        CameraMode.Photo => Icons.Camera,
        CameraMode.Document => Icons.Document,
        _ => SignatureGlyph,
    };

    public static string Hint(this CameraMode m) => m switch
    {
        CameraMode.Text => "Scan text and send it",
        CameraMode.Qr => "Read a QR code or barcode",
        CameraMode.Photo => "Take a photo for the computer",
        CameraMode.Document => "Scan pages to a PDF",
        _ => "Sign on paper or draw, paste on the computer",
    };

    // The name of the mode in the settings.
    public static string Key(this CameraMode m) => m.ToString().ToLowerInvariant();

    public static CameraMode? FromKey(string? key) => All.Cast<CameraMode?>().FirstOrDefault(m => m!.Value.Key() == key);
}

// Sends what the camera modes make to 1 computer, and shows short messages
// in the camera window. CameraOutput of CameraInput.swift of the Mac app has
// the same job.
public sealed class CameraOutput(string deviceId, AppModel app)
{
    public string DeviceId => deviceId;

    // Shows a message in the camera window.
    public Action<string>? OnMessage { get; set; }

    public DeviceSnapshot? Device => app.DeviceOf(deviceId);
    public string Name => Device?.Name ?? "the computer";

    public void Say(string message) => OnMessage?.Invoke(message);

    // Sends text that the camera read. The computer saves it in its scan folder.
    public bool SendScan(string text) => app.Core.Plugin<SharePlugin>()?.SendScan(text, deviceId) ?? false;

    // Sends the packet of a code action, as Flux for Android does.
    public bool Send(ShareBody body) => app.Core.Send(body.Packet, deviceId);

    // Sends 1 captured file with the extra share fields, such as "photo".
    // It throws CameraException with a message for the user.
    public async Task SendCaptureAsync(byte[] data, string name, JsonObject extra)
    {
        var share = app.Core.Plugin<SharePlugin>() ?? throw new CameraException("Sharing is not available");
        var dir = Path.Combine(Path.GetTempPath(), "Flux Camera", Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(dir);
            var file = Path.Combine(dir, name);
            await File.WriteAllBytesAsync(file, data);
            await share.SendCaptureAsync(file, name, extra, deviceId);
        }
        catch (Exception e) when (e is ShareException or IOException or UnauthorizedAccessException or TimeoutException or OperationCanceledException or
                                      SocketException or AuthenticationException or ObjectDisposedException or ArgumentException)
        {
            throw new CameraException(e is OperationCanceledException ? "Canceled" : e is ShareException ? e.Message : $"Sending {name} failed", e);
        }
        finally
        {
            try
            {
                Directory.Delete(dir, true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // The temporary folder stays until Windows cleans it.
            }
        }
    }
}

// The state of 1 camera window: the mode, the camera, and each mode.
// CameraWindowModel of CameraModel.swift of the Mac app has the same parts.
public sealed class CameraWindowModel : Model
{
    CameraMode mode;
    string? message;
    readonly DispatcherTimer messageTimer = new() { Interval = TimeSpan.FromSeconds(3) };

    public CameraWindowModel(string deviceId, AppModel app, CameraMode mode, ICameraSource cameras)
    {
        App = app;
        this.mode = mode;
        Output = new CameraOutput(deviceId, app);
        Camera = new CameraFeed(cameras, app.Core.Settings);
        Text = new TextScan(Camera, Output);
        Codes = new CodeScan(Output);
        Photo = new PhotoShots(Camera, Output);
        Document = new DocumentPages(Camera, Output);
        Signature = new SignatureCapture(Camera, Output);
        Output.OnMessage = Show;
        Camera.CodesFound += (codes, frame) => Codes.Found(frame, codes.Select(c => c.Code).ToArray(), live: true);
        messageTimer.Tick += (_, _) =>
        {
            messageTimer.Stop();
            Message = null;
        };
        foreach (var m in new Model[] { Text, Codes, Photo, Document, Signature })
        {
            m.PropertyChanged += (_, _) => Apply();
        }
    }

    public AppModel App { get; }
    public CameraOutput Output { get; }
    public CameraFeed Camera { get; }
    public TextScan Text { get; }
    public CodeScan Codes { get; }
    public PhotoShots Photo { get; }
    public DocumentPages Document { get; }
    public SignatureCapture Signature { get; }

    public CameraMode Mode
    {
        get => mode;
        set
        {
            if (Set(ref mode, value))
            {
                App.Core.Settings.Set(CameraFeature.ModeKey, value.Key());
                Apply();
            }
        }
    }

    // A short message over the stage, for 3 seconds.
    public string? Message
    {
        get => message;
        private set => Set(ref message, value);
    }

    public string DeviceName => Output.Name;

    // What the mode needs from the camera now.
    public CameraUse CameraUse => mode switch
    {
        CameraMode.Text => Text.IsLive ? CameraUse.Text : CameraUse.Off,
        CameraMode.Qr => Codes.IsLive ? CameraUse.Codes : CameraUse.Off,
        CameraMode.Photo => CameraUse.Preview,
        CameraMode.Document => Document.Sending ? CameraUse.Off : CameraUse.Document,
        _ => Signature.IsLive ? CameraUse.Preview : CameraUse.Off,
    };

    // Brings the camera to what the mode needs.
    public void Apply() => Camera.Set(CameraUse);

    // Photo mode takes photos with the camera only, like on Android.
    public bool AcceptsImages => mode != CameraMode.Photo;

    // Runs the mode on images from outside the camera: files, a screen region, the clipboard, or a drop.
    public void Use(IReadOnlyList<BgraImage> images)
    {
        if (images.Count == 0)
        {
            Show("Cannot open the image");
            return;
        }
        switch (mode)
        {
            case CameraMode.Text:
                Text.Read(images[0]);
                break;
            case CameraMode.Qr:
                Codes.Read(images[0]);
                break;
            case CameraMode.Document:
                Document.Add(images);
                break;
            case CameraMode.Signature:
                Signature.Cut(images[0], null);
                break;
        }
    }

    public void Show(string text)
    {
        Message = text;
        messageTimer.Stop();
        messageTimer.Start();
    }

    public void Close()
    {
        messageTimer.Stop();
        Camera.Dispose();
    }
}

// Text mode: reads text with the camera or from an image and sends it to the computer.
public sealed class TextScan(CameraFeed camera, CameraOutput output) : Model
{
    public enum Phase
    {
        // The camera preview runs and shows the text boxes.
        Live,

        // The image is frozen and the recognition runs. The image is null until the photo arrives.
        Reading,

        // The recognized text is ready to edit and send.
        Result,
    }

    Phase phase = Phase.Live;
    BgraImage? image;
    string text = "";
    bool found;

    public Phase State
    {
        get => phase;
        internal set => Set(ref phase, value);
    }

    // The frozen image while it reads and after.
    public BgraImage? Image
    {
        get => image;
        internal set => Set(ref image, value);
    }

    public string Text
    {
        get => text;
        set => Set(ref text, value);
    }

    // True when the scan found text. The editor stays after the user clears the text.
    public bool Found
    {
        get => found;
        internal set => Set(ref found, value);
    }

    public bool IsLive => phase == Phase.Live;

    public void Capture() => _ = CaptureAsync();

    public async Task CaptureAsync()
    {
        if (!IsLive)
        {
            return;
        }
        // The still comes first, because the camera stops while the text reads.
        var shot = camera.CaptureAsync();
        Image = null;
        State = Phase.Reading;
        try
        {
            await ReadAsync(await shot);
        }
        catch (CameraException)
        {
            State = Phase.Live;
            output.Say("Cannot take the photo");
        }
    }

    public void Read(BgraImage still) => _ = ReadAsync(still);

    public async Task ReadAsync(BgraImage still)
    {
        Image = still;
        State = Phase.Reading;
        try
        {
            Text = TextAssembly.Assemble(await Task.Run(() => CameraOcr.TextAsync(still)));
        }
        catch (CameraException e)
        {
            Text = "";
            output.Say(e.Message);
        }
        Found = Text.Length > 0;
        State = Phase.Result;
    }

    public void Retake()
    {
        Text = "";
        Found = false;
        Image = null;
        State = Phase.Live;
    }

    public void Send()
    {
        if (Text.Trim().Length == 0)
        {
            return;
        }
        if (output.SendScan(Text))
        {
            output.Say($"Sent to {output.Name}");
            Retake();
        }
        else
        {
            output.Say("Not connected");
        }
    }
}

// QR mode: reads QR codes and barcodes and sends the value to the computer.
public sealed class CodeScan(CameraOutput output) : Model
{
    public enum Phase
    {
        Live,
        Found,
        Missing,
    }

    Phase phase = Phase.Live;
    BgraImage? image;
    CodeSheet? sheet;

    public Phase State
    {
        get => phase;
        internal set => Set(ref phase, value);
    }

    public BgraImage? Image
    {
        get => image;
        internal set => Set(ref image, value);
    }

    public CodeSheet? Sheet
    {
        get => sheet;
        internal set => Set(ref sheet, value);
    }

    public bool IsLive => phase == Phase.Live;

    // Shows the first code with a value. A live frame pauses the camera on
    // the first code, like a camera app.
    public void Found(BgraImage? frame, IReadOnlyList<ScannedCode> codes, bool live)
    {
        if (live && !IsLive)
        {
            return;
        }
        Image = frame;
        if (codes.FirstOrDefault(c => c.Raw.Length > 0) is { } code)
        {
            Sheet = Codes.Sheet(code, output.Name);
            State = Phase.Found;
        }
        else
        {
            Sheet = null;
            State = Phase.Missing;
        }
    }

    public void Read(BgraImage still) => _ = ReadAsync(still);

    public async Task ReadAsync(BgraImage still)
    {
        var codes = await Task.Run(() => CodeReader.Read(still).Select(c => c.Code).ToArray());
        Found(still, codes, live: false);
    }

    public void Run(CodeAction action) => output.Say(output.Send(action.Body) ? $"Sent to {output.Name}" : "Not connected");

    public void Again()
    {
        Image = null;
        Sheet = null;
        State = Phase.Live;
    }
}

// Photo mode: takes a photo and sends it to the computer as a JPEG file.
public sealed class PhotoShots(CameraFeed camera, CameraOutput output) : Model
{
    public enum Phase
    {
        None,
        Saving,
        Sending,
        Sent,
        Failed,
    }

    Phase phase = Phase.None;
    BgraImage? thumb;
    byte[]? failedData;
    string failedName = "";

    public Phase State
    {
        get => phase;
        internal set => Set(ref phase, value);
    }

    // The thumbnail of the last photo.
    public BgraImage? Thumb
    {
        get => thumb;
        internal set => Set(ref thumb, value);
    }

    // Why the last photo did not go out, or an empty text.
    public string Failure { get; internal set; } = "";

    public bool Busy => phase is Phase.Saving or Phase.Sending;

    public void Shoot() => _ = ShootAsync();

    public async Task ShootAsync()
    {
        if (Busy)
        {
            return;
        }
        var name = CaptureNames.Photo();
        State = Phase.Saving;
        byte[] data;
        BgraImage small;
        try
        {
            var still = await camera.CaptureAsync();
            (data, small) = await Task.Run(() => (CameraImaging.Jpeg(still, CameraImages.PhotoQuality), still.Scaled(256)));
        }
        catch (Exception e) when (e is CameraException or InvalidOperationException or NotSupportedException or System.Runtime.InteropServices.ExternalException)
        {
            State = Phase.None;
            output.Say("Cannot take the photo");
            return;
        }
        await SendAsync(data, name, small);
    }

    // Sends a photo that failed again.
    public void Retry() => _ = RetryAsync();

    public async Task RetryAsync()
    {
        if (phase == Phase.Failed && failedData is { } data)
        {
            await SendAsync(data, failedName, thumb);
        }
    }

    async Task SendAsync(byte[] data, string name, BgraImage? small)
    {
        Thumb = small;
        State = Phase.Sending;
        try
        {
            await output.SendCaptureAsync(data, name, new JsonObject { ["photo"] = true });
            failedData = null;
            State = Phase.Sent;
            output.Say($"Sent to {output.Name}");
        }
        catch (CameraException e)
        {
            failedData = data;
            failedName = name;
            Failure = e.Message;
            State = Phase.Failed;
            output.Say(e.Message);
        }
    }
}

// Document mode: finds the page edges in photos or images, flattens the
// pages, and sends them to the computer as 1 PDF.
public sealed class DocumentPages(CameraFeed camera, CameraOutput output) : Model
{
    // 1 page of the document. Flat is the page cut out along its edges, or
    // null when no edges were found. Whole uses the whole image in place of
    // the page that was found.
    public sealed record Page(Guid Id, BgraImage Original, BgraImage? Flat, bool Whole)
    {
        public BgraImage Image => Whole ? Original : Flat ?? Original;
    }

    // The largest side of a page photo.
    const int MaxSide = 3000;

    ValueList<Page> pages = ValueList<Page>.Empty;
    bool busy;
    bool sending;
    string? status;

    public ValueList<Page> Pages
    {
        get => pages;
        internal set => Set(ref pages, value);
    }

    public bool Busy
    {
        get => busy;
        internal set => Set(ref busy, value);
    }

    public bool Sending
    {
        get => sending;
        internal set => Set(ref sending, value);
    }

    public string? Status
    {
        get => status;
        internal set => Set(ref status, value);
    }

    public void Capture() => _ = CaptureAsync();

    public async Task CaptureAsync()
    {
        if (busy || sending)
        {
            return;
        }
        Busy = true;
        try
        {
            await AddNowAsync([await camera.CaptureAsync()]);
        }
        catch (CameraException)
        {
            output.Say("Cannot take the photo");
        }
        Busy = false;
    }

    public void Add(IReadOnlyList<BgraImage> images) => _ = AddAsync(images);

    public async Task AddAsync(IReadOnlyList<BgraImage> images)
    {
        if (sending)
        {
            return;
        }
        Busy = true;
        await AddNowAsync(images);
        Busy = false;
    }

    async Task AddNowAsync(IReadOnlyList<BgraImage> images)
    {
        foreach (var image in images)
        {
            var original = image.Scaled(MaxSide);
            var flat = await Task.Run(() => DocumentFinder.Find(original) is { } quad ? DocumentFinder.Flatten(original, quad, MaxSide) : null);
            Pages = ValueList.From(pages.Append(new Page(Guid.NewGuid(), original, flat, false)));
        }
        Status = null;
    }

    public void Remove(Guid id) => Pages = ValueList.From(pages.Where(p => p.Id != id));

    public void ToggleWhole(Guid id) => Pages = ValueList.From(pages.Select(p => p.Id == id ? p with { Whole = !p.Whole } : p));

    public void Send() => _ = SendAsync();

    public async Task SendAsync()
    {
        if (pages.Count == 0 || sending || busy)
        {
            return;
        }
        var name = CaptureNames.Document();
        var images = pages.Select(p => p.Image).ToArray();
        var label = Label(images.Length);
        Sending = true;
        Status = $"Sending {name}, {label}…";
        try
        {
            var pdf = await Task.Run(() => CameraImages.Pdf(images.Select(i => CameraImaging.Jpeg(i, CameraImages.PageQuality)).ToArray()));
            await output.SendCaptureAsync(pdf, name, new JsonObject { ["scan"] = true });
            Pages = ValueList<Page>.Empty;
            Status = $"Sent {name}, {label}, to {output.Name}";
            output.Say($"Sent to {output.Name}");
        }
        catch (CameraException e)
        {
            Status = e.Message;
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or NotSupportedException or System.Runtime.InteropServices.ExternalException)
        {
            Status = "Cannot make the PDF";
        }
        Sending = false;
    }

    public static string Label(int n) => n == 1 ? "1 page" : $"{n} pages";
}

// Signature mode: photographs a signature on paper, or takes one drawn with
// the mouse, a pen, or a touch screen, cuts out the ink, and sends it as a
// transparent PNG. The computer puts it on the clipboard.
public sealed class SignatureCapture(CameraFeed camera, CameraOutput output) : Model
{
    public enum Source
    {
        Camera,
        Draw,
    }

    public enum Phase
    {
        // The camera preview runs with the guide frame, or the drawing canvas shows.
        Live,

        // The ink is cut out.
        Working,

        // The ink is ready to send. It is null when the image has no ink.
        Result,
    }

    Source source = Source.Camera;
    Phase phase = Phase.Live;
    BgraImage? image;
    SignatureInk? ink;
    InkColor color = InkColor.Black;
    bool sending;
    string? failure;
    bool drawn;

    public static string Label(Source s) => s == Source.Camera ? "Paper" : "Draw";

    public Source From
    {
        get => source;
        set
        {
            if (Set(ref source, value))
            {
                Retake();
            }
        }
    }

    public Phase State
    {
        get => phase;
        internal set => Set(ref phase, value);
    }

    // The image that the ink comes from, while it works.
    public BgraImage? Image
    {
        get => image;
        internal set => Set(ref image, value);
    }

    public SignatureInk? Ink
    {
        get => ink;
        internal set => Set(ref ink, value);
    }

    public InkColor Color
    {
        get => color;
        set => Set(ref color, value);
    }

    // The strokes of the canvas. The view adds them and calls Changed.
    public SignatureDrawing Drawing { get; } = new();

    public bool Sending
    {
        get => sending;
        internal set => Set(ref sending, value);
    }

    public string? Failure
    {
        get => failure;
        internal set => Set(ref failure, value);
    }

    // True when the result comes from the canvas, where the pen is black.
    public bool Drawn
    {
        get => drawn;
        internal set => Set(ref drawn, value);
    }

    public bool IsLive => phase == Phase.Live && source == Source.Camera;

    // Reports a change of the drawing.
    public void DrawingChanged() => Changed(nameof(Drawing));

    public void Undo()
    {
        Drawing.Undo();
        DrawingChanged();
    }

    public void Clear()
    {
        Drawing.Clear();
        DrawingChanged();
    }

    // Takes a photo and cuts out the ink inside the guide frame of a preview of the size.
    public void Capture(double previewWidth, double previewHeight) => _ = CaptureAsync(previewWidth, previewHeight);

    public async Task CaptureAsync(double previewWidth, double previewHeight)
    {
        if (!IsLive || previewWidth <= 0 || previewHeight <= 0)
        {
            return;
        }
        // The still comes first, because the camera stops while the ink cuts out.
        var shot = camera.CaptureAsync();
        Image = null;
        State = Phase.Working;
        try
        {
            var still = await shot;
            var frame = SignatureCut.GuideFrame(previewWidth, previewHeight);
            var crop = SignatureCut.FrameInImage((float)frame.X, (float)frame.Y, (float)frame.Right, (float)frame.Bottom,
                (int)previewWidth, (int)previewHeight, still.Width, still.Height, 0.05f);
            await CutAsync(still, crop);
        }
        catch (CameraException)
        {
            State = Phase.Live;
            output.Say("Cannot take the photo");
        }
    }

    // Crops the image, scales it down, and cuts out the ink.
    public void Cut(BgraImage still, SignatureCrop? crop) => _ = CutAsync(still, crop);

    public async Task CutAsync(BgraImage still, SignatureCrop? crop)
    {
        Image = still;
        Ink = null;
        State = Phase.Working;
        Failure = null;
        Drawn = false;
        var cut = await Task.Run(() =>
        {
            var part = still.Crop(crop, SignatureCut.MaxSide);
            return SignatureCut.Extract(part.Argb(), part.Width, part.Height);
        });
        Ink = cut;
        State = Phase.Result;
    }

    // Cuts out the ink of the drawing on a canvas of the size.
    public void FinishDrawing(double canvasWidth, double canvasHeight)
    {
        Failure = null;
        Drawn = true;
        if (color == InkColor.Original)
        {
            Color = InkColor.Black;
        }
        Image = null;
        Ink = Drawing.Ink(canvasWidth, canvasHeight);
        State = Phase.Result;
    }

    public void Retake()
    {
        Failure = null;
        Ink = null;
        Image = null;
        State = Phase.Live;
    }

    public void Send() => _ = SendAsync();

    public async Task SendAsync()
    {
        if (sending || ink is not { } cut)
        {
            return;
        }
        Sending = true;
        Failure = null;
        var rgb = color.Of(cut);
        var name = CaptureNames.Signature();
        try
        {
            var png = await Task.Run(() => CameraImages.Png(cut, rgb));
            await output.SendCaptureAsync(png, name, new JsonObject { ["signature"] = true });
            output.Say($"Copied to the clipboard on {output.Name}");
            Clear();
            Retake();
        }
        catch (CameraException e)
        {
            Failure = e.Message;
        }
        Sending = false;
    }
}
