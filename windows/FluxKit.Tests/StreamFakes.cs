using System.Collections.Concurrent;
using System.Net.Security;
using System.Net.Sockets;
using FluxKit;

namespace FluxKit.Tests;

// The fakes of the platform parts of the streams: the microphone, the
// camera, the renderer, the encoder, and the screen capture. They stand in
// for WASAPI, Media Foundation, Direct3D, and Windows.Graphics.Capture.

// A frame that holds only its size and a number.
public sealed record FakeFrame(int Width, int Height, int Number = 0) : IVideoFrame;

public sealed class FakeMicSource : IMicSource
{
    readonly Lock gate = new();
    List<MicInput> inputs = [new("mic-1", "Built-in Microphone"), new("mic-2", "USB Headset")];

    public MicPermission Permission { get; set; } = MicPermission.Granted;

    // The answer to the question for the permission.
    public bool GrantOnAsk { get; set; } = true;
    public int Asked { get; private set; }

    public ConcurrentQueue<FakeMicCapture> Captures { get; } = new();

    public event Action? InputsChanged;

    public IReadOnlyList<MicInput> Inputs()
    {
        lock (gate)
        {
            return inputs.ToArray();
        }
    }

    public void SetInputs(params MicInput[] next)
    {
        lock (gate)
        {
            inputs = [.. next];
        }
        InputsChanged?.Invoke();
    }

    public Task<bool> AuthorizeAsync()
    {
        Asked++;
        Permission = GrantOnAsk ? MicPermission.Granted : MicPermission.Denied;
        return Task.FromResult(GrantOnAsk);
    }

    public Task<IMicCapture> StartAsync(string inputId, MicFeed feed, CancellationToken ct)
    {
        var capture = new FakeMicCapture(inputId, feed);
        Captures.Enqueue(capture);
        return Task.FromResult<IMicCapture>(capture);
    }

    public FakeMicCapture? Last => Captures.LastOrDefault();
}

public sealed class FakeMicCapture(string input, MicFeed feed) : IMicCapture
{
    public string Input { get; private set; } = input;
    public MicFeed Feed { get; } = feed;
    public bool Disposed { get; private set; }
    public ConcurrentQueue<string> Used { get; } = new();

    public void Use(string inputId)
    {
        Used.Enqueue(inputId);
        Input = inputId;
    }

    public void Dispose() => Disposed = true;
}

public sealed class FakeCameraSource : ICameraSource
{
    readonly Lock gate = new();
    List<CameraDevice> devices = [new("usb#integrated", "Integrated Camera", true)];

    public bool AccessDenied { get; set; }

    // A message that the next open throws as a StreamException.
    public string? FailOpen { get; set; }

    public ConcurrentQueue<FakeCameraSession> Opened { get; } = new();

    public event Action? DevicesChanged;

    public IReadOnlyList<CameraDevice> Devices()
    {
        lock (gate)
        {
            return devices.ToArray();
        }
    }

    public void SetDevices(params CameraDevice[] next)
    {
        lock (gate)
        {
            devices = [.. next];
        }
        DevicesChanged?.Invoke();
    }

    public Task<IDisposable> OpenAsync(CameraDevice device, int shortSide, IFrameSink frames)
    {
        if (FailOpen is { } message)
        {
            throw new StreamException(message);
        }
        var session = new FakeCameraSession(device, shortSide, frames);
        Opened.Enqueue(session);
        return Task.FromResult<IDisposable>(session);
    }

    // The camera that runs now, or null.
    public FakeCameraSession? Running => Opened.LastOrDefault(s => !s.Disposed);
}

public sealed class FakeCameraSession(CameraDevice device, int shortSide, IFrameSink frames) : IDisposable
{
    int number;

    public CameraDevice Device { get; } = device;
    public int ShortSide { get; } = shortSide;
    public IFrameSink Frames { get; } = frames;
    public bool Disposed { get; private set; }

    // Sends 1 camera frame of 1920 x 1080 pixels.
    public void Push(int rotation = 0) => Frames.Frame(new FakeFrame(1920, 1080, Interlocked.Increment(ref number)), rotation);

    public void Dispose() => Disposed = true;
}

public sealed class FakeRenderer : IFrameRenderer
{
    int previews;

    public ConcurrentQueue<(FakeFrame Output, int Rotation, WebcamLook Look)> Rendered { get; } = new();
    public int Previews => Volatile.Read(ref previews);

    public IVideoFrame? Render(IVideoFrame camera, int width, int height, int rotation, WebcamLook look)
    {
        var output = new FakeFrame(width, height, ((FakeFrame)camera).Number);
        Rendered.Enqueue((output, rotation, look));
        return output;
    }

    public object? Preview(IVideoFrame frame, int maxWidth)
    {
        Interlocked.Increment(ref previews);
        return $"preview {((FakeFrame)frame).Number} at {maxWidth}";
    }
}

public sealed class FakeEncoderFactory : IVideoEncoderFactory
{
    public static readonly byte[] Sps = [0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1F];
    public static readonly byte[] Pps = [0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80];

    // A message that the next Create throws as a StreamException.
    public string? FailCreate { get; set; }

    public ConcurrentQueue<FakeEncoder> Made { get; } = new();

    public IVideoEncoder Create(VideoEncoderSettings settings, EncodedVideo output)
    {
        if (FailCreate is { } message)
        {
            throw new StreamException(message);
        }
        output.ParameterSets([.. Sps, .. Pps]);
        var encoder = new FakeEncoder(settings, output);
        Made.Enqueue(encoder);
        return encoder;
    }

    public FakeEncoder? Last => Made.LastOrDefault();
}

// An encoder that writes 1 small access unit per frame: an IDR slice for a
// key frame and a P slice for the others. The byte after the NAL header is
// the number of the frame.
public sealed class FakeEncoder(VideoEncoderSettings settings, EncodedVideo output) : IVideoEncoder
{
    public VideoEncoderSettings Settings { get; } = settings;
    public EncodedVideo Output { get; } = output;
    public ConcurrentQueue<(int Number, bool Key)> Encoded { get; } = new();
    public bool Disposed { get; private set; }

    public void Encode(IVideoFrame frame, bool keyFrame)
    {
        var f = (FakeFrame)frame;
        if (f.Width != Settings.Width || f.Height != Settings.Height)
        {
            throw new StreamException($"the frame has {f.Width} x {f.Height} pixels");
        }
        Encoded.Enqueue((f.Number, keyFrame));
        Output.AccessUnit(keyFrame ? [0, 0, 0, 1, 0x65, (byte)f.Number] : [0, 0, 0, 1, 0x41, (byte)f.Number], keyFrame);
    }

    public void Dispose() => Disposed = true;
}

public sealed class FakeScreenSource : IScreenSource
{
    readonly Lock gate = new();
    readonly Dictionary<string, (int Width, int Height)> sizes = new() { ["DISPLAY1"] = (2340, 1080), ["DISPLAY2"] = (1920, 1080) };

    public bool HasAccess { get; set; } = true;

    // A message that the next prepare throws as a StreamException.
    public string? FailPrepare { get; set; }

    public ConcurrentQueue<FakeScreenCapture> Prepared { get; } = new();

    public IReadOnlyList<DisplayInfo> Displays()
    {
        lock (gate)
        {
            return sizes.OrderBy(s => s.Key).Select(s => new DisplayInfo(s.Key, $"Monitor {s.Key[^1]}", s.Value.Width, s.Value.Height)).ToArray();
        }
    }

    public (int Width, int Height)? PixelSize(string displayId)
    {
        lock (gate)
        {
            return sizes.TryGetValue(displayId, out var s) ? s : null;
        }
    }

    public void SetSize(string displayId, int width, int height)
    {
        lock (gate)
        {
            sizes[displayId] = (width, height);
        }
    }

    public Task<IScreenCapture> PrepareAsync(string displayId, IFrameSink frames)
    {
        if (FailPrepare is { } message)
        {
            throw new StreamException(message);
        }
        var capture = new FakeScreenCapture(displayId, frames);
        Prepared.Enqueue(capture);
        return Task.FromResult<IScreenCapture>(capture);
    }

    public FakeScreenCapture? Last => Prepared.LastOrDefault();
}

public sealed class FakeScreenCapture(string display, IFrameSink frames) : IScreenCapture
{
    int number;

    public string Display { get; } = display;
    public IFrameSink Frames { get; } = frames;
    public (int Width, int Height)? Size { get; private set; }
    public ConcurrentQueue<(int Width, int Height)> Resizes { get; } = new();
    public bool Disposed { get; private set; }

    public Task StartAsync(int width, int height)
    {
        Size = (width, height);
        return Task.CompletedTask;
    }

    public Task ResizeAsync(int width, int height)
    {
        Size = (width, height);
        Resizes.Enqueue((width, height));
        return Task.CompletedTask;
    }

    // Sends 1 frame of the capture size, or of the size given.
    public void Push(int? width = null, int? height = null) =>
        Frames.Frame(new FakeFrame(width ?? Size!.Value.Width, height ?? Size!.Value.Height, Interlocked.Increment(ref number)), 0);

    public void Dispose() => Disposed = true;
}

// The side of the computer of a stream: it connects to the payload listener
// of this computer as the TLS client, as fluxd does with DialPeer.
public sealed class StreamClient : IAsyncDisposable
{
    readonly TcpClient tcp;
    readonly SslStream ssl;
    readonly List<byte> received = [];

    StreamClient(TcpClient tcp, SslStream ssl)
    {
        this.tcp = tcp;
        this.ssl = ssl;
    }

    public static async Task<StreamClient> ConnectAsync(LocalCertificate certificate, int port)
    {
        var tcp = new TcpClient();
        await tcp.ConnectAsync("127.0.0.1", port);
        var ssl = await new FluxTls(certificate).ClientAsync(tcp.GetStream(), "flux-payload", default);
        return new StreamClient(tcp, ssl);
    }

    // The bytes that arrived so far.
    public byte[] Received
    {
        get
        {
            lock (received)
            {
                return received.ToArray();
            }
        }
    }

    // Reads until done holds for the bytes so far. It throws TimeoutException
    // after the time, and IOException when the stream ends first.
    public async Task<byte[]> ReadUntilAsync(Func<byte[], bool> done, double seconds = 10)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        var buffer = new byte[16 * 1024];
        while (!done(Received))
        {
            int n;
            try
            {
                n = await ssl.ReadAsync(buffer, timeout.Token);
            }
            catch (OperationCanceledException)
            {
                throw new TimeoutException($"the stream gave {Received.Length} bytes in {seconds} seconds");
            }
            if (n == 0)
            {
                throw new IOException($"the stream ended after {Received.Length} bytes");
            }
            lock (received)
            {
                received.AddRange(buffer.AsSpan(0, n));
            }
        }
        return Received;
    }

    // Reads until the stream ends. It returns false when the stream did not
    // end within the time.
    public async Task<bool> EndsAsync(double seconds = 10)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        var buffer = new byte[16 * 1024];
        try
        {
            while (true)
            {
                var n = await ssl.ReadAsync(buffer, timeout.Token);
                if (n == 0)
                {
                    return true;
                }
                lock (received)
                {
                    received.AddRange(buffer.AsSpan(0, n));
                }
            }
        }
        catch (OperationCanceledException)
        {
            return false;
        }
        catch (IOException)
        {
            return true;
        }
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            await ssl.DisposeAsync();
        }
        catch (IOException)
        {
        }
        tcp.Dispose();
    }
}
