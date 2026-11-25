using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// The microphone, the webcam, and the screen mirror against a headless
// fluxd. A headless fluxd has no pw-cat, v4l2loopback, or player, so it
// refuses each start with flux.* {"state": "error"} and never connects to
// the payload listener. MicLoopbackTests, WebcamLoopbackTests, and
// ScreenLoopbackTests check the streams against a computer on loopback.
public class StreamEndToEndTests
{
    // fluxd uses UDP first and TCP first + 4. The core uses UDP first + 15
    // and TCP first + 24 to first + 32. The payload listener uses first + 33
    // and first + 34.
    static LanConfig Lan(Fluxd fluxd, int first) => new()
    {
        UdpPort = first + 15,
        PeerUdpPort = fluxd.UdpPort,
        FirstTcpPort = first + 24,
        LastTcpPort = first + 32,
        LoopbackOnly = true,
    };

    // The error of a stream in flux-cli status --json, such as "mic".
    static async Task<string?> StatusErrorAsync(Fluxd fluxd, string stream) =>
        Json.String(JsonNode.Parse(await fluxd.CliAsync("status", "--json"))?[stream]?["error"]);

    [FluxdFact]
    public async Task HeadlessFluxdRefusesTheMicrophone()
    {
        const int first = 35000;
        await using var fluxd = await Fluxd.StartAsync(first, first + 4);
        var source = new FakeMicSource();
        var mic = new MicPlugin(source) { PayloadPorts = (first + 33, first + 34) };
        using var t = new TestCore(Lan(fluxd, first), [mic]);
        var computer = await EndToEndTests.PairFromWindowsAsync(fluxd, t);
        Assert.True(computer.Accepts(PacketType.Mic)); // fluxd takes the microphone

        mic.Start(computer.Id);
        await Wait.UntilAsync(() => mic.Model.Status.Phase == StreamPhase.Error, "the refusal of fluxd", fluxd);
        const string refusal = "the microphone is off in headless mode";
        Assert.Equal(new StreamStatus(StreamPhase.Error, refusal, computer.Id), mic.Model.Status);
        // fluxd did not connect, so no capture started.
        Assert.Empty(source.Captures);
        Assert.Contains(refusal, fluxd.Log);
        Assert.Equal(refusal, await StatusErrorAsync(fluxd, "mic"));
        // fluxd refused, so this side sends no stop, and fluxd has no stream
        // to stop.
        var stop = await Assert.ThrowsAsync<InvalidOperationException>(() => fluxd.CliAsync("mic", "stop"));
        Assert.Contains("No phone microphone is live", stop.Message);
    }

    [FluxdFact]
    public async Task HeadlessFluxdRefusesTheWebcam()
    {
        const int first = 35035;
        await using var fluxd = await Fluxd.StartAsync(first, first + 4);
        var cameras = new FakeCameraSource();
        var encoders = new FakeEncoderFactory();
        var webcam = new WebcamPlugin(cameras, new FakeRenderer(), encoders) { PayloadPorts = (first + 33, first + 34) };
        using var t = new TestCore(Lan(fluxd, first), [webcam]);
        var computer = await EndToEndTests.PairFromWindowsAsync(fluxd, t);
        Assert.True(computer.Accepts(PacketType.Webcam));

        webcam.Start(computer.Id);
        await Wait.UntilAsync(() => webcam.Model.Status.Phase == StreamPhase.Error, "the refusal of fluxd", fluxd);
        const string refusal = "the webcam is off in headless mode";
        Assert.Equal(new StreamStatus(StreamPhase.Error, refusal, computer.Id), webcam.Model.Status);
        // The camera ran for the preview, and the refusal stops it. No
        // encoder started, because fluxd did not connect.
        Assert.Single(cameras.Opened);
        await Wait.UntilAsync(() => cameras.Running is null, "the stop of the camera", fluxd);
        Assert.Empty(encoders.Made);
        Assert.Contains(refusal, fluxd.Log);
        Assert.Equal(refusal, await StatusErrorAsync(fluxd, "webcam"));
    }

    [FluxdFact]
    public async Task HeadlessFluxdRefusesTheScreenMirror()
    {
        const int first = 35070;
        await using var fluxd = await Fluxd.StartAsync(first, first + 4);
        var screens = new FakeScreenSource();
        var encoders = new FakeEncoderFactory();
        var screen = new ScreenPlugin(screens, encoders) { PayloadPorts = (first + 33, first + 34) };
        using var t = new TestCore(Lan(fluxd, first), [screen]);
        var computer = await EndToEndTests.PairFromWindowsAsync(fluxd, t);
        Assert.True(computer.Accepts(PacketType.Screen));

        screen.Start(computer.Id);
        await Wait.UntilAsync(() => screen.Model.Status.Phase == StreamPhase.Error, "the refusal of fluxd", fluxd);
        const string refusal = "the screen mirror is off in headless mode";
        Assert.Equal(new StreamStatus(StreamPhase.Error, refusal, computer.Id), screen.Model.Status);
        var capture = Assert.Single(screens.Prepared);
        Assert.Null(capture.Size); // the capture never started
        await Wait.UntilAsync(() => capture.Disposed, "the end of the capture", fluxd);
        Assert.Empty(encoders.Made);
        Assert.Contains(refusal, fluxd.Log);
        Assert.Equal(refusal, await StatusErrorAsync(fluxd, "screen"));
    }
}
