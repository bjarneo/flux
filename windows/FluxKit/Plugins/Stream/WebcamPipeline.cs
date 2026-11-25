namespace FluxKit;

// Draws camera frames into encoder frames, and makes the preview. The WPF
// app implements it on the GPU, for example with Direct3D 11, and tests use
// a fake. The webcam calls it on the thread of the camera, 1 call at a time.
public interface IFrameRenderer
{
    // Draws a camera frame into a new frame of width x height pixels:
    // FrameGeometry.Transform places the image for the rotation, the mirror,
    // and the zoom. Then the exposure gain of the look applies in linear
    // light, and the matrix of ColorAdjust applies to the encoded values.
    // The colors stay inside 0 to 1, and color management stays off, so
    // that the preview shows what the computer gets. It returns null when it
    // cannot draw the frame.
    IVideoFrame? Render(IVideoFrame camera, int width, int height, int rotation, WebcamLook look);

    // Returns a small copy of a rendered frame, at most maxWidth pixels wide,
    // for the preview in the UI, such as a WPF BitmapSource, or null.
    object? Preview(IVideoFrame frame, int maxWidth);
}

// Connects the camera, the renderer, and the encoder for the webcam. While
// no encoder runs, the frames only feed the preview. The preview renders
// only while a view shows it. WebcamPipeline.swift of the Mac app has the
// same rules.
internal sealed class WebcamPipeline : IFrameSink
{
    // Every 5th frame goes to the preview: 6 images per second.
    internal const int PreviewEvery = 5;

    // The width of the preview image, in pixels.
    internal const int PreviewWidth = 480;

    readonly IFrameRenderer renderer;
    readonly CameraControl camera;
    readonly Action<object> onPreview;
    readonly Action<string> onCameraError;

    readonly Lock gate = new();
    WebcamLook look = new();
    int width = 1280;
    int height = 720;
    H264Encoder? encoder;
    VideoSink? sink;
    // The number of views that show the preview.
    int previewViews;

    // Owned by the thread of the camera.
    int frameCount;

    public WebcamPipeline(ICameraSource cameras, IFrameRenderer renderer, Action<object> onPreview, Action<string> onCameraError)
    {
        this.renderer = renderer;
        this.onPreview = onPreview;
        this.onCameraError = onCameraError;
        camera = new CameraControl(cameras, this);
    }

    // Applies the image settings at once. The frame size applies to the
    // preview at once and to the stream with the next encoder.
    public void Apply(WebcamConfig config)
    {
        lock (gate)
        {
            look = WebcamLook.From(config);
            width = config.Width;
            height = config.Height;
        }
    }

    public bool IsCameraOpen => camera.IsOpen;

    // Opens the camera for the stream attempt owner.
    public Task OpenCameraAsync(CameraInfo info, int shortSide, int owner) => camera.OpenAsync(info, shortSide, owner);

    // Switches the open camera to info. It does nothing when no camera is open.
    public Task SwitchCameraAsync(CameraInfo info, int shortSide) => camera.SwitchAsync(info, shortSide);

    // Stops the camera when the stream attempt owner opened it last.
    public void CloseCamera(int owner) => camera.Close(owner);

    // Starts to encode frames of width x height into sink. It throws what
    // the factory of the app throws.
    public void StartEncoder(IVideoEncoderFactory factory, int width, int height, int bitrate, VideoSink sink, Action<string> onError)
    {
        var next = new H264Encoder(factory, width, height, bitrate, () => sink.Backlogged, sink.Push, onError);
        H264Encoder? old;
        lock (gate)
        {
            old = encoder;
            encoder = next;
            this.sink = sink;
        }
        old?.Dispose();
    }

    public void StopEncoder()
    {
        H264Encoder? old;
        lock (gate)
        {
            old = encoder;
            encoder = null;
            sink = null;
        }
        old?.Dispose();
    }

    // The encoder of the stream, or null. Tests read it.
    internal H264Encoder? Encoder
    {
        get
        {
            lock (gate)
            {
                return encoder;
            }
        }
    }

    // Asks for an IDR frame now, for example after a camera switch.
    public void RequestKeyFrame()
    {
        H264Encoder? e;
        lock (gate)
        {
            e = encoder;
        }
        e?.RequestKeyFrame();
    }

    // Counts the views that show the preview. A count keeps the preview on
    // when a new view appears before the old view disappears.
    public void SetPreviewShown(bool shown)
    {
        lock (gate)
        {
            previewViews = Math.Max(0, previewViews + (shown ? 1 : -1));
        }
    }

    public void Frame(IVideoFrame frame, int rotation)
    {
        WebcamLook l;
        int w;
        int h;
        H264Encoder? e;
        VideoSink? s;
        bool previewWanted;
        lock (gate)
        {
            l = look;
            e = encoder;
            s = sink;
            previewWanted = previewViews > 0;
            // The encoder keeps its size until the next stream, so the stream
            // never changes size in the middle.
            w = e?.Width ?? width;
            h = e?.Height ?? height;
        }
        frameCount++;
        var wantsPreview = previewWanted && frameCount % PreviewEvery == 0;
        var sending = e is not null && s?.Backlogged == false;
        if (!sending && !wantsPreview)
        {
            return;
        }
        try
        {
            if (renderer.Render(frame, w, h, rotation, l) is not { } image)
            {
                return;
            }
            if (sending)
            {
                e!.Encode(image);
            }
            if (wantsPreview && renderer.Preview(image, PreviewWidth) is { } preview)
            {
                onPreview(preview);
            }
        }
        catch (Exception x) when (StreamErrors.Expected(x))
        {
            // The frame drops. The next frame tries again, and the camera
            // keeps running.
            FluxLog.Debug("stream", $"a webcam frame did not render: {x.Message}");
        }
    }

    public void Failed(string message) => onCameraError(message);
}
