using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// The webcam against a computer on loopback that speaks the wire of fluxd.
// A headless fluxd refuses the webcam, see StreamEndToEndTests, so the
// computer here takes the stream: it reads the start and config packets,
// connects to the payload listener with its certificate, and reads the
// H.264 stream.
public class WebcamLoopbackTests
{
    sealed class Rig : IDisposable
    {
        public required SystemTestComputer Computer { get; init; }
        public required TestCore Core { get; init; }
        public required WebcamPlugin Webcam { get; init; }
        public required FakeCameraSource Cameras { get; init; }
        public required FakeRenderer Renderer { get; init; }
        public required FakeEncoderFactory Encoders { get; init; }
        public MicPlugin? Mic { get; init; }
        public FakeMicSource? MicSource { get; init; }

        public void Dispose()
        {
            Computer.Dispose();
            Core.Dispose();
        }

        public IReadOnlyList<Packet> Got(string state) => Computer.Got(PacketType.Webcam).Where(p => p.String("state") == state).ToArray();

        // The start packet number count that the computer got, after it arrived.
        public async Task<Packet> StartAsync(int count = 1)
        {
            await Wait.UntilAsync(() => Got("start").Count >= count, $"start packet {count}");
            return Got("start")[count - 1];
        }
    }

    // A block of 35 ports from first: the computer, the core, and the
    // payload listeners.
    static Rig Make(int first, bool withMic = false, IReadOnlyList<string>? computerTakes = null)
    {
        var cameras = new FakeCameraSource();
        var renderer = new FakeRenderer();
        var encoders = new FakeEncoderFactory();
        var webcam = new WebcamPlugin(cameras, renderer, encoders) { PayloadPorts = (first + 30, first + 34) };
        var micSource = withMic ? new FakeMicSource() : null;
        var mic = withMic ? new MicPlugin(micSource) { PayloadPorts = (first + 6, first + 9) } : null;
        IReadOnlyList<IFluxPlugin> plugins = mic is null ? [webcam] : [webcam, mic];
        return new Rig
        {
            Computer = new SystemTestComputer(first, first + 1, computerTakes ?? [PacketType.Webcam, PacketType.Mic], [PacketType.Webcam, PacketType.Mic]),
            Core = new TestCore(SystemTestComputer.CoreLan(first + 10), plugins),
            Webcam = webcam,
            Cameras = cameras,
            Renderer = renderer,
            Encoders = encoders,
            Mic = mic,
            MicSource = micSource,
        };
    }

    static readonly byte[] Config = [.. FakeEncoderFactory.Sps, .. FakeEncoderFactory.Pps];

    // The NAL types of an Annex-B stream, in order.
    static IReadOnlyList<byte> Types(byte[] stream) => AnnexB.NalTypes(stream);

    [Fact]
    public async Task StreamsAnnexBWithTheConfigBeforeEachIdr()
    {
        using var r = Make(35420);
        var snapshot = await r.Computer.PairAsync(r.Core);
        r.Webcam.Start(snapshot.Id);
        var start = await r.StartAsync();
        Assert.Equal(1280, start.Int("width"));
        Assert.Equal(720, start.Int("height"));
        Assert.Equal(30, start.Int("fps"));
        Assert.Equal("h264", start.String("codec"));
        Assert.InRange(start.Int("port") ?? 0, 35450, 35454);
        // The full settings and the caps follow the start.
        await Wait.UntilAsync(() => r.Got("config").Count >= 1, "the config packet");
        var config = r.Got("config")[0];
        Assert.Equal("16:9", Json.String(config.Object("config")?["aspect"]));
        Assert.Equal(["integrated camera"], Json.Strings(config.Object("caps")?["cameras"]));
        Assert.Equal(4, Json.Double(config.Object("caps")?["zoomMax"]));
        // The camera runs before the computer connects, for the preview.
        Assert.Equal(720, r.Cameras.Running!.ShortSide);
        Assert.Equal(new StreamStatus(StreamPhase.Connecting, $"Waiting for {r.Computer.Name}…", snapshot.Id), r.Webcam.Model.Status);

        await using var client = await StreamClient.ConnectAsync(r.Computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => r.Webcam.Model.Status.Phase == StreamPhase.Starting, "the start of the stream");
        Assert.Equal($"Starting Flux Camera on {r.Computer.Name}…", r.Webcam.Model.Status.Message);
        await Wait.UntilAsync(() => r.Webcam.Pipeline?.Encoder is not null, "the encoder");
        var encoder = r.Encoders.Last!;
        Assert.Equal(new VideoEncoderSettings(1280, 720, 4_000_000), encoder.Settings);

        // 3 camera frames: an IDR frame with SPS and PPS, then P frames.
        var camera = r.Cameras.Running!;
        camera.Push();
        camera.Push();
        camera.Push();
        var bytes = await client.ReadUntilAsync(b => Types(b).Count(t => t == 1) >= 2);
        Assert.Equal<byte>([7, 8, 5, 1, 1], Types(bytes).Take(5));
        Assert.Equal([.. Config, 0, 0, 0, 1, 0x65, 1, 0, 0, 0, 1, 0x41, 2, 0, 0, 0, 1, 0x41, 3], bytes.Take(Config.Length + 18));

        // A key frame that the encoder makes later gets SPS and PPS again.
        r.Webcam.Pipeline!.RequestKeyFrame();
        camera.Push();
        bytes = await client.ReadUntilAsync(b => Types(b).Count(t => t == 5) >= 2);
        Assert.Equal<byte>([7, 8, 5], LastIdrGroup(bytes));
        Assert.Equal(2, Types(bytes).Count(t => t == AnnexB.NalSps));

        r.Computer.Send(new Packet(PacketType.Webcam, new JsonObject { ["state"] = "live", ["device"] = "/dev/video9", ["label"] = "Flux Camera" }));
        await Wait.UntilAsync(() => r.Webcam.Model.Status.Phase == StreamPhase.Live, "the live state");
        Assert.Equal($"Live on {r.Computer.Name} as Flux Camera", r.Webcam.Model.Status.Message);

        // The user stops the camera on the computer.
        r.Computer.Send(new Packet(PacketType.Webcam, new JsonObject { ["state"] = "stop" }));
        await Wait.UntilAsync(() => r.Webcam.Model.Status.Phase == StreamPhase.Idle, "the stop");
        Assert.Equal($"Stopped on {r.Computer.Name}", r.Webcam.Model.Status.Message);
        Assert.True(await client.EndsAsync());
        await Wait.UntilAsync(() => r.Cameras.Running is null, "the stop of the camera");
        Assert.True(encoder.Disposed);
        Assert.Empty(r.Got("stop"));
    }

    // The NAL types from the last SPS on: the group of the last key frame.
    static IReadOnlyList<byte> LastIdrGroup(byte[] stream)
    {
        var types = Types(stream).ToList();
        var at = types.LastIndexOf(AnnexB.NalSps);
        return types.Skip(at).Take(3).ToArray();
    }

    [Fact]
    public async Task SettingsFromTheComputerChangeTheImageAndTheSize()
    {
        using var r = Make(35455);
        var snapshot = await r.Computer.PairAsync(r.Core);
        r.Webcam.Start(snapshot.Id);
        var start = await r.StartAsync();
        await using var client = await StreamClient.ConnectAsync(r.Computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => r.Webcam.Pipeline?.Encoder is not null, "the encoder");
        var configs = r.Got("config").Count;

        // A change of the image applies at once and goes back as the full settings.
        r.Computer.Send(new Packet(PacketType.Webcam, new JsonObject { ["state"] = "config", ["config"] = new JsonObject { ["brightness"] = 0.3, ["mirror"] = true } }));
        await Wait.UntilAsync(() => r.Webcam.Model.Config.Brightness == 0.3, "the brightness");
        await Wait.UntilAsync(() => r.Got("config").Count > configs, "the config answer");
        var answer = r.Got("config")[^1].Object("config")!;
        Assert.Equal(0.3, Json.Double(answer["brightness"]));
        Assert.Equal(true, Json.Bool(answer["mirror"]));
        r.Cameras.Running!.Push();
        await Wait.UntilAsync(() => !r.Renderer.Rendered.IsEmpty, "a rendered frame");
        Assert.Equal(new WebcamLook(true, 1, 0, new ColorAdjust(0.3, 1, 1, 0)), r.Renderer.Rendered.Last().Look);
        // The settings stay for the next stream.
        Assert.Equal(0.3, Json.Double(r.Core.Core.Settings.Node(WebcamSettings.Key)?["brightness"]));

        // A new aspect starts the stream again with the new size.
        r.Computer.Send(new Packet(PacketType.Webcam, new JsonObject { ["state"] = "config", ["config"] = new JsonObject { ["aspect"] = "1:1" } }));
        var second = await r.StartAsync(2);
        Assert.Equal(720, second.Int("width"));
        Assert.Equal(720, second.Int("height"));
        Assert.True(await client.EndsAsync());
        // The first stream ended with a stop, so that the computer starts again.
        Assert.Single(r.Got("stop"));
        await using var again = await StreamClient.ConnectAsync(r.Computer.Certificate, second.Int("port")!.Value);
        await Wait.UntilAsync(() => r.Encoders.Made.Count == 2, "the second encoder");
        Assert.Equal(new VideoEncoderSettings(720, 720, 2_250_000), r.Encoders.Last!.Settings);

        // A reset keeps the shape and sets the neutral image values.
        r.Computer.Send(new Packet(PacketType.Webcam, new JsonObject { ["state"] = "config", ["reset"] = true }));
        await Wait.UntilAsync(() => r.Webcam.Model.Config.Brightness == 0, "the reset");
        Assert.Equal(new WebcamConfig { Aspect = "1:1", Camera = "integrated camera" }, r.Webcam.Model.Config);

        r.Webcam.Stop();
        await Wait.UntilAsync(() => r.Got("stop").Count == 2, "the stop of the second stream");
        await Wait.UntilAsync(() => r.Webcam.Model.Status == StreamStatus.None, "the idle state");
    }

    [Fact]
    public async Task UpdateFromThisComputerSwitchesTheCamera()
    {
        using var r = Make(35490);
        r.Cameras.SetDevices(new CameraDevice("usb#1", "Integrated Camera", true), new CameraDevice("usb#2", "USB Camera", false));
        await Wait.UntilAsync(() => r.Webcam.Model.Cameras.Count == 2, "the cameras");
        var snapshot = await r.Computer.PairAsync(r.Core);
        r.Webcam.Start(snapshot.Id);
        var start = await r.StartAsync();
        await using var client = await StreamClient.ConnectAsync(r.Computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => r.Webcam.Pipeline?.Encoder is not null, "the encoder");
        Assert.Equal("usb#1", r.Cameras.Running!.Device.DeviceId);
        var configs = r.Got("config").Count;

        r.Cameras.Running!.Push();
        await Wait.UntilAsync(() => r.Encoders.Last!.Encoded.Count(e => e.Key) == 1, "the first key frame");

        // A new camera switches without a new stream, and starts with a key frame.
        r.Webcam.Update(c => c with { Camera = "usb camera" });
        await Wait.UntilAsync(() => r.Cameras.Running?.Device.DeviceId == "usb#2", "the switch");
        await Wait.UntilAsync(() =>
        {
            r.Cameras.Running?.Push();
            return r.Encoders.Last!.Encoded.Count(e => e.Key) == 2;
        }, "the key frame after the switch");
        Assert.Single(r.Encoders.Made);
        Assert.Single(r.Got("start"));
        await Wait.UntilAsync(() => r.Got("config").Count > configs, "the config answer");
        Assert.Equal("usb camera", Json.String(r.Got("config")[^1].Object("config")?["camera"]));

        // A camera that fails after the start shows its error.
        r.Cameras.Running!.Frames.Failed("USB Camera was disconnected");
        await Wait.UntilAsync(() => r.Webcam.Model.CameraError == "USB Camera was disconnected", "the camera error");
        Assert.Equal(StreamPhase.Starting, r.Webcam.Model.Status.Phase);
    }

    [Fact]
    public async Task ThePreviewShowsWhileAViewWantsIt()
    {
        using var r = Make(35525);
        var snapshot = await r.Computer.PairAsync(r.Core);
        r.Webcam.SetPreviewShown(true);
        r.Webcam.Start(snapshot.Id);
        await r.StartAsync();
        var camera = r.Cameras.Running!;
        for (var i = 0; i < 5; i++)
        {
            camera.Push();
        }
        await Wait.UntilAsync(() => r.Webcam.Model.Preview is not null, "the preview");
        Assert.Equal("preview 5 at 480", r.Webcam.Model.Preview);
        r.Webcam.Stop();
        await Wait.UntilAsync(() => r.Webcam.Model.Status == StreamStatus.None, "the stop");
        Assert.Null(r.Webcam.Model.Preview);
    }

    [Fact]
    public async Task SendsTheMicrophoneWithTheWebcam()
    {
        using var r = Make(35560, withMic: true);
        var snapshot = await r.Computer.PairAsync(r.Core);
        r.Webcam.SetSendsMicrophone(true);
        await Wait.UntilAsync(() => r.Webcam.Model.SendsMicrophone, "the option");
        Assert.True(r.Core.Core.Settings.Bool(WebcamPlugin.MicrophoneKey, false));

        r.Webcam.Start(snapshot.Id);
        var start = await r.StartAsync();
        await using var client = await StreamClient.ConnectAsync(r.Computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => r.Webcam.Model.Status.Phase == StreamPhase.Starting, "the start");
        Assert.Empty(r.Computer.Got(PacketType.Mic)); // the microphone waits for the live webcam

        r.Computer.Send(new Packet(PacketType.Webcam, new JsonObject { ["state"] = "live", ["label"] = "Flux Camera" }));
        await Wait.UntilAsync(() => r.Computer.Got(PacketType.Mic).Any(p => p.String("state") == "start"), "the start of the microphone");
        var micStart = r.Computer.Got(PacketType.Mic).First(p => p.String("state") == "start");
        Assert.InRange(micStart.Int("port") ?? 0, 35566, 35569);
        await using var micClient = await StreamClient.ConnectAsync(r.Computer.Certificate, micStart.Int("port")!.Value);
        await Wait.UntilAsync(() => r.MicSource!.Last is not null, "the capture");

        // The webcam stops, and the microphone that it started stops too.
        r.Webcam.Stop();
        await Wait.UntilAsync(() => r.Computer.Got(PacketType.Mic).Any(p => p.String("state") == "stop"), "the stop of the microphone");
        await Wait.UntilAsync(() => r.MicSource!.Last!.Disposed, "the end of the capture");
        Assert.Single(r.Got("stop"));

        // Without the permission, the option stays off.
        r.MicSource!.Permission = MicPermission.Denied;
        r.Webcam.SetSendsMicrophone(false);
        r.Webcam.SetSendsMicrophone(true);
        await Wait.UntilAsync(() => r.Core.Toasts.Contains("Allow the microphone for Flux to send it with the webcam"), "the toast");
        Assert.False(r.Webcam.Model.SendsMicrophone);
    }

    [Fact]
    public async Task ChecksBeforeTheStart()
    {
        using var r = Make(35595, computerTakes: []);
        var snapshot = await r.Computer.PairAsync(r.Core);
        r.Webcam.Start(snapshot.Id);
        await Wait.UntilAsync(() => r.Webcam.Model.Status.Phase == StreamPhase.Error, "the update error");
        Assert.Equal($"Update Flux on {r.Computer.Name} to use this computer as a webcam", r.Webcam.Model.Status.Message);
        Assert.Empty(r.Cameras.Opened);
        Assert.Empty(r.Computer.Got(PacketType.Webcam));
    }

    [Fact]
    public async Task CameraProblemsStopTheStart()
    {
        using var r = Make(35630);
        var snapshot = await r.Computer.PairAsync(r.Core);
        r.Cameras.AccessDenied = true;
        Assert.True(r.Webcam.CameraAccessDenied);
        r.Webcam.Start(snapshot.Id);
        await Wait.UntilAsync(() => r.Webcam.Model.Status.Phase == StreamPhase.Error, "the access error");
        Assert.Equal(WebcamPlugin.CameraAccessText, r.Webcam.Model.Status.Message);

        r.Cameras.AccessDenied = false;
        r.Cameras.SetDevices();
        r.Webcam.Start(snapshot.Id);
        await Wait.UntilAsync(() => r.Webcam.Model.Status.Message == WebcamPlugin.NoCameraText, "the camera error");

        r.Cameras.SetDevices(new CameraDevice("usb#1", "Integrated Camera", true));
        r.Cameras.FailOpen = "Integrated Camera is used by another app";
        r.Webcam.Start(snapshot.Id);
        await Wait.UntilAsync(() => r.Webcam.Model.Status.Message == "Integrated Camera is used by another app", "the open error");
        Assert.Empty(r.Computer.Got(PacketType.Webcam));

        // An encoder that does not start ends the stream and tells the computer.
        r.Cameras.FailOpen = null;
        r.Encoders.FailCreate = "no H.264 encoder";
        r.Webcam.Start(snapshot.Id);
        var start = await r.StartAsync();
        await using var client = await StreamClient.ConnectAsync(r.Computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => r.Webcam.Model.Status.Message == "The video encoder did not start: no H.264 encoder", "the encoder error");
        await Wait.UntilAsync(() => r.Got("stop").Count == 1, "the stop");
        Assert.True(await client.EndsAsync());
        await Wait.UntilAsync(() => r.Cameras.Running is null, "the stop of the camera");
    }

    [Fact]
    public async Task BeginAttemptShowsTheWaitAndStopEndsIt()
    {
        // WebcamBackgroundTests.swift of the Mac app: a session without the
        // stream task. The iPhone stops the webcam in the background. This
        // computer keeps the camera in the background, so only the attempt
        // part applies.
        using var r = Make(35665);
        await Wait.UntilAsync(() => r.Webcam.Model.Cameras.Count == 1, "the cameras");
        Assert.NotNull(r.Webcam.BeginAttempt("computer"));
        await Wait.UntilAsync(() => r.Webcam.Model.Status.Phase == StreamPhase.Connecting, "the wait");
        Assert.Equal(new StreamStatus(StreamPhase.Connecting, "Waiting for the computer…", "computer"), r.Webcam.Model.Status);
        r.Webcam.Stop();
        await Wait.UntilAsync(() => r.Webcam.Model.Status == StreamStatus.None, "the stop");
        Assert.Empty(r.Computer.Got(PacketType.Webcam)); // the computer knew nothing of it
        // Without a camera, renderer, and encoder, the webcam starts nothing.
        var none = new WebcamPlugin();
        Assert.Null(none.BeginAttempt("computer"));
        Assert.Empty(none.Incoming);
        Assert.False(none.Supported);
    }
}
