using System.Collections.Concurrent;
using System.Net.Security;
using System.Net.Sockets;
using FluxKit;

namespace FluxKit.Tests;

// The parts of the video streams between the capture and the network: the
// encoder rules, the camera control, the frame routing of the webcam, and
// the backlog of the sink.
public class StreamPipelineTests
{
    static readonly byte[] Config = [.. FakeEncoderFactory.Sps, .. FakeEncoderFactory.Pps];

    // A sink whose stream does not run, so that pushed bytes stay pending.
    static VideoSink IdleSink(int bitrate = 1_000_000)
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        return new VideoSink(new TlsStream(new SslStream(new MemoryStream()), socket, []), bitrate);
    }

    [Fact]
    public void EncoderMakesTheFirstFrameAKeyFrame()
    {
        var factory = new FakeEncoderFactory();
        var output = new ConcurrentQueue<byte[]>();
        using var encoder = new H264Encoder(factory, 1280, 720, 4_000_000, () => false, output.Enqueue, _ => { });
        var made = Assert.Single(factory.Made);
        Assert.Equal(new VideoEncoderSettings(1280, 720, 4_000_000), made.Settings);
        Assert.Equal(30, made.Settings.Fps);
        encoder.Encode(new FakeFrame(1280, 720, 1));
        encoder.Encode(new FakeFrame(1280, 720, 2));
        encoder.RequestKeyFrame();
        encoder.Encode(new FakeFrame(1280, 720, 3));
        Assert.Equal([(1, true), (2, false), (3, true)], made.Encoded.Take(3));
        // SPS and PPS go in front of each IDR frame.
        Assert.Equal<byte[]>([[.. Config, 0, 0, 0, 1, 0x65, 1], [0, 0, 0, 1, 0x41, 2], [.. Config, 0, 0, 0, 1, 0x65, 3]], output.Take(3));
    }

    [Fact]
    public async Task EncoderRepeatsTheLastFrameOfAStillScene()
    {
        var factory = new FakeEncoderFactory();
        using var encoder = new H264Encoder(factory, 64, 64, 2_000_000, () => false, _ => { }, _ => { });
        encoder.Encode(new FakeFrame(64, 64, 7));
        var made = factory.Last!;
        await Wait.UntilAsync(() => made.Encoded.Count >= 3, "the repeats of the last frame", seconds: 5);
        Assert.All(made.Encoded, e => Assert.Equal(7, e.Number));
        Assert.Equal(1, made.Encoded.Count(e => e.Key)); // a repeat is no key frame
        encoder.Dispose();
        Assert.True(made.Disposed);
        var after = made.Encoded.Count;
        await Task.Delay(300);
        Assert.Equal(after, made.Encoded.Count); // no repeats after the end
        encoder.Encode(new FakeFrame(64, 64, 8));
        Assert.Equal(after, made.Encoded.Count); // an encoder that ended takes no frame
    }

    [Fact]
    public async Task EncoderDoesNotRepeatWhileTheNetworkIsBehind()
    {
        var factory = new FakeEncoderFactory();
        var backlogged = true;
        using var encoder = new H264Encoder(factory, 64, 64, 2_000_000, () => Volatile.Read(ref backlogged), _ => { }, _ => { });
        encoder.Encode(new FakeFrame(64, 64, 1));
        await Task.Delay(400);
        Assert.Single(factory.Last!.Encoded);
        Volatile.Write(ref backlogged, false);
        await Wait.UntilAsync(() => factory.Last!.Encoded.Count > 1, "a repeat after the backlog", seconds: 5);
    }

    [Fact]
    public async Task EncoderReportsAFailureOnce()
    {
        var factory = new FakeEncoderFactory();
        var errors = new ConcurrentQueue<string>();
        using var encoder = new H264Encoder(factory, 64, 64, 2_000_000, () => false, _ => { }, errors.Enqueue);
        encoder.Encode(new FakeFrame(32, 32, 1)); // the fake throws for a wrong size
        encoder.Encode(new FakeFrame(32, 32, 2));
        await Wait.UntilAsync(() => !errors.IsEmpty, "the error", seconds: 5);
        await Task.Delay(200);
        Assert.Equal(["The video encoder failed: the frame has 32 x 32 pixels"], errors);
        encoder.Encode(new FakeFrame(64, 64, 3));
        Assert.Empty(factory.Last!.Encoded); // a failed encoder takes no frame

        // An error of the app encoder after the start goes the same way.
        var later = new ConcurrentQueue<string>();
        using var second = new H264Encoder(factory, 64, 64, 2_000_000, () => false, _ => { }, later.Enqueue);
        factory.Last!.Output.Fail("the GPU was removed");
        factory.Last!.Output.Fail("again");
        await Wait.UntilAsync(() => !later.IsEmpty, "the error of the app encoder", seconds: 5);
        await Task.Delay(100);
        Assert.Equal(["the GPU was removed"], later);
    }

    [Fact]
    public void FactoryErrorsReachTheCaller()
    {
        var factory = new FakeEncoderFactory { FailCreate = "no H.264 encoder" };
        var e = Assert.Throws<StreamException>(() => new H264Encoder(factory, 64, 64, 2_000_000, () => false, _ => { }, _ => { }));
        Assert.Equal("no H.264 encoder", e.Message);
    }

    [Fact]
    public void SinkTurnsBackloggedAfterAboutASecondOfVideo()
    {
        var sink = IdleSink(bitrate: 4_000_000);
        Assert.Equal(500_000, sink.Limit);
        Assert.Equal(256 * 1024, IdleSink(bitrate: 1_000_000).Limit); // the floor
        sink.Push(new byte[400_000]);
        Assert.False(sink.Backlogged);
        sink.Push(new byte[200_000]);
        Assert.True(sink.Backlogged);
        sink.Close();
        sink.Close(); // a second close does nothing
    }

    [Fact]
    public async Task CameraControlKeepsTheCameraOfTheLastOwner()
    {
        var source = new FakeCameraSource();
        source.SetDevices(new CameraDevice("usb#1", "Integrated Camera", true), new CameraDevice("usb#2", "USB Camera", false));
        var cameras = CameraNames.Name(source.Devices());
        var control = new CameraControl(source, new NullFrames());
        await control.OpenAsync(cameras[0], 720, owner: 1);
        Assert.True(control.IsOpen);
        Assert.Equal(720, Assert.Single(source.Opened).ShortSide);
        // The same camera and size keep the camera that runs.
        await control.OpenAsync(cameras[0], 720, owner: 2);
        Assert.Single(source.Opened);
        // A close of an owner that did not open last does nothing.
        control.Close(owner: 1);
        await Task.Delay(100);
        Assert.False(source.Opened.Single().Disposed);
        // A switch opens the other camera and stops the first one.
        await control.SwitchAsync(cameras[1], 1080);
        Assert.Equal(2, source.Opened.Count);
        Assert.True(source.Opened.First().Disposed);
        Assert.Equal("usb#2", source.Running!.Device.DeviceId);
        control.Close(owner: 2);
        Assert.False(control.IsOpen);
        await Wait.UntilAsync(() => source.Running is null, "the stop of the camera", seconds: 5);
        // A switch without an open camera opens nothing.
        await control.SwitchAsync(cameras[0], 720);
        Assert.Equal(2, source.Opened.Count);
    }

    [Fact]
    public async Task CameraControlReportsAnOpenThatFails()
    {
        var source = new FakeCameraSource { FailOpen = "Integrated Camera is used by another app" };
        var control = new CameraControl(source, new NullFrames());
        var camera = CameraNames.Name(source.Devices())[0];
        var e = await Assert.ThrowsAsync<StreamException>(() => control.OpenAsync(camera, 720, owner: 1));
        Assert.Equal("Integrated Camera is used by another app", e.Message);
        Assert.Empty(source.Opened);
    }

    sealed class NullFrames : IFrameSink
    {
        public void Frame(IVideoFrame frame, int rotation)
        {
        }

        public void Failed(string message)
        {
        }
    }

    static (WebcamPipeline Pipeline, FakeCameraSource Cameras, FakeRenderer Renderer, ConcurrentQueue<object> Previews, ConcurrentQueue<string> Errors) MakePipeline()
    {
        var cameras = new FakeCameraSource();
        var renderer = new FakeRenderer();
        var previews = new ConcurrentQueue<object>();
        var errors = new ConcurrentQueue<string>();
        return (new WebcamPipeline(cameras, renderer, previews.Enqueue, errors.Enqueue), cameras, renderer, previews, errors);
    }

    [Fact]
    public async Task PipelineRendersOnlyForTheEncoderOrAShownPreview()
    {
        var (pipeline, cameras, renderer, previews, errors) = MakePipeline();
        await pipeline.OpenCameraAsync(CameraNames.Name(cameras.Devices())[0], 720, owner: 1);
        var camera = cameras.Running!;
        for (var i = 0; i < 10; i++)
        {
            camera.Push();
        }
        Assert.Empty(renderer.Rendered); // nobody wants the frames

        pipeline.SetPreviewShown(true);
        pipeline.SetPreviewShown(true);
        pipeline.SetPreviewShown(false); // 1 view still shows it
        for (var i = 0; i < 10; i++)
        {
            camera.Push();
        }
        // Every 5th frame goes to the preview.
        Assert.Equal(2, renderer.Rendered.Count);
        Assert.Equal(["preview 15 at 480", "preview 20 at 480"], previews);
        Assert.All(renderer.Rendered, r => Assert.Equal((1280, 720), (r.Output.Width, r.Output.Height)));

        camera.Frames.Failed("Integrated Camera was disconnected");
        Assert.Equal(["Integrated Camera was disconnected"], errors);
        pipeline.CloseCamera(owner: 1);
        await Wait.UntilAsync(() => cameras.Running is null, "the stop of the camera", seconds: 5);
    }

    [Fact]
    public async Task PipelineEncodesEachFrameAtTheSizeOfTheEncoder()
    {
        var (pipeline, cameras, renderer, _, _) = MakePipeline();
        var factory = new FakeEncoderFactory();
        pipeline.Apply(new WebcamConfig { Aspect = "1:1", Mirror = true, Brightness = 0.2 });
        await pipeline.OpenCameraAsync(CameraNames.Name(cameras.Devices())[0], 720, owner: 1);
        var sink = IdleSink();
        pipeline.StartEncoder(factory, 720, 720, 2_250_000, sink, _ => { });
        var camera = cameras.Running!;
        camera.Push(rotation: 90);
        // A new frame size waits for the next stream: the encoder keeps its size.
        pipeline.Apply(new WebcamConfig { Aspect = "16:9", Mirror = true, Brightness = 0.2 });
        camera.Push();
        var rendered = renderer.Rendered.ToArray();
        Assert.Equal(2, rendered.Length);
        Assert.All(rendered, r => Assert.Equal((720, 720), (r.Output.Width, r.Output.Height)));
        Assert.Equal(90, rendered[0].Rotation);
        Assert.Equal(WebcamLook.From(new WebcamConfig { Mirror = true, Brightness = 0.2 }), rendered[0].Look);
        Assert.Equal([1, 2], factory.Last!.Encoded.Select(e => e.Number).Take(2));

        // While the network is behind, the frames skip the encoder.
        sink.Push(new byte[1_000_000]);
        var before = renderer.Rendered.Count;
        camera.Push();
        Assert.Equal(before, renderer.Rendered.Count);

        pipeline.RequestKeyFrame();
        pipeline.StopEncoder();
        Assert.True(factory.Last!.Disposed);
        Assert.Null(pipeline.Encoder);
        sink.Close();
    }
}
