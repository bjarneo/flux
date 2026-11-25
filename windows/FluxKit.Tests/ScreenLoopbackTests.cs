using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// The screen mirror against a computer on loopback that speaks the wire of
// fluxd. A headless fluxd refuses the mirror, see StreamEndToEndTests, so
// the computer here takes the stream: it reads the start packet, connects
// to the payload listener with its certificate, and reads the H.264 stream.
public class ScreenLoopbackTests
{
    sealed class Rig : IDisposable
    {
        public required SystemTestComputer Computer { get; init; }
        public required TestCore Core { get; init; }
        public required ScreenPlugin Screen { get; init; }
        public required FakeScreenSource Screens { get; init; }
        public required FakeEncoderFactory Encoders { get; init; }

        public void Dispose()
        {
            Computer.Dispose();
            Core.Dispose();
        }

        public IReadOnlyList<Packet> Got(string state) => Computer.Got(PacketType.Screen).Where(p => p.String("state") == state).ToArray();

        public async Task<Packet> StartAsync(int count = 1)
        {
            await Wait.UntilAsync(() => Got("start").Count >= count, $"start packet {count}");
            return Got("start")[count - 1];
        }
    }

    // A block of 35 ports from first: the computer, the core, and the
    // payload listener.
    static Rig Make(int first, bool computerTakesScreen = true)
    {
        var screens = new FakeScreenSource();
        var encoders = new FakeEncoderFactory();
        var screen = new ScreenPlugin(screens, encoders) { PayloadPorts = (first + 30, first + 34) };
        return new Rig
        {
            Computer = new SystemTestComputer(first, first + 1, computerTakesScreen ? [PacketType.Screen] : [], [PacketType.Screen]),
            Core = new TestCore(SystemTestComputer.CoreLan(first + 10), [screen]),
            Screen = screen,
            Screens = screens,
            Encoders = encoders,
        };
    }

    [Fact]
    public async Task MirrorsTheDisplayWithTheFittedSize()
    {
        using var r = Make(35700);
        var snapshot = await r.Computer.PairAsync(r.Core);
        r.Screen.Start(snapshot.Id);
        var start = await r.StartAsync();
        // A 2340 x 1080 display fits into 1072 x 496.
        Assert.Equal(1072, start.Int("width"));
        Assert.Equal(496, start.Int("height"));
        Assert.Equal("h264", start.String("codec"));
        Assert.InRange(start.Int("port") ?? 0, 35730, 35734);
        Assert.Equal(new StreamStatus(StreamPhase.Connecting, $"Waiting for {r.Computer.Name}…", snapshot.Id), r.Screen.Model.Status);

        await using var client = await StreamClient.ConnectAsync(r.Computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => r.Screens.Last?.Size is not null, "the capture start");
        var capture = r.Screens.Last!;
        Assert.Equal("DISPLAY1", capture.Display); // the main display
        Assert.Equal((1072, 496), capture.Size);
        Assert.Equal(new VideoEncoderSettings(1072, 496, 1072 * 496 * 8), r.Encoders.Last!.Settings);

        capture.Push();
        capture.Push(1920, 1080); // a frame of another size skips the encoder
        capture.Push();
        var bytes = await client.ReadUntilAsync(b => AnnexB.NalTypes(b).Count >= 4);
        Assert.Equal<byte>([7, 8, 5, 1], AnnexB.NalTypes(bytes).Take(4));
        Assert.Equal([1, 3], r.Encoders.Last!.Encoded.Select(e => e.Number).Take(2));

        r.Computer.Send(new Packet(PacketType.Screen, new JsonObject { ["state"] = "live", ["player"] = "mpv" }));
        await Wait.UntilAsync(() => r.Screen.Model.Status.Phase == StreamPhase.Live, "the live state");
        Assert.Equal($"Mirrors to {r.Computer.Name}", r.Screen.Model.Status.Message);

        // The user stops the mirror on this computer.
        r.Screen.Stop();
        await Wait.UntilAsync(() => r.Got("stop").Count == 1, "the stop");
        await Wait.UntilAsync(() => r.Screen.Model.Status.Phase == StreamPhase.Idle, "the idle state");
        Assert.Equal(new StreamStatus(StreamPhase.Idle, "Stopped on this computer", snapshot.Id), r.Screen.Model.Status);
        Assert.True(capture.Disposed);
        Assert.True(r.Encoders.Last!.Disposed);
        Assert.True(await client.EndsAsync());
    }

    [Fact]
    public async Task ANewDisplaySizeGivesANewEncoderOnTheSameStream()
    {
        using var r = Make(35735);
        var snapshot = await r.Computer.PairAsync(r.Core);
        r.Core.Core.Host.Post(() => r.Screen.Select("DISPLAY2"));
        await Wait.UntilAsync(() => r.Screen.Model.Display == "DISPLAY2", "the chosen display");
        Assert.Equal("DISPLAY2", r.Core.Core.Settings.String(ScreenPlugin.DisplayKey));
        r.Screen.Start(snapshot.Id);
        var start = await r.StartAsync();
        Assert.Equal(1072, start.Int("width"));
        Assert.Equal(592, start.Int("height"));
        await using var client = await StreamClient.ConnectAsync(r.Computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => r.Screens.Last?.Size is not null, "the capture start");
        var capture = r.Screens.Last!;
        Assert.Equal("DISPLAY2", capture.Display);
        capture.Push();
        await client.ReadUntilAsync(b => AnnexB.NalTypes(b).Contains(AnnexB.NalIdr));

        // The display turns to portrait. Within a second, a new encoder
        // starts on the same stream with a key frame.
        r.Screens.SetSize("DISPLAY2", 1080, 1920);
        await Wait.UntilAsync(() => r.Encoders.Made.Count == 2, "the second encoder");
        Assert.Equal(new VideoEncoderSettings(592, 1072, 592 * 1072 * 8), r.Encoders.Last!.Settings);
        await Wait.UntilAsync(() => r.Encoders.Made.First().Disposed, "the end of the first encoder");
        await Wait.UntilAsync(() => capture.Size == (592, 1072), "the resize of the capture");
        Assert.Equal([(592, 1072)], capture.Resizes);
        capture.Push();
        var bytes = await client.ReadUntilAsync(b => AnnexB.NalTypes(b).Count(t => t == AnnexB.NalIdr) >= 2);
        Assert.Equal(2, AnnexB.NalTypes(bytes).Count(t => t == AnnexB.NalSps));
        Assert.Single(r.Got("start")); // no new start packet
        Assert.Equal(StreamPhase.Connecting, r.Screen.CurrentStatus.Phase); // no live report yet

        // The computer closes the window.
        r.Computer.Send(new Packet(PacketType.Screen, new JsonObject { ["state"] = "stop" }));
        await Wait.UntilAsync(() => r.Screen.Model.Status.Phase == StreamPhase.Idle, "the stop");
        Assert.Equal($"Stopped on {r.Computer.Name}", r.Screen.Model.Status.Message);
        Assert.Empty(r.Got("stop"));
        Assert.True(capture.Disposed);
    }

    [Fact]
    public async Task ACaptureThatStopsEndsTheMirror()
    {
        using var r = Make(35770);
        var snapshot = await r.Computer.PairAsync(r.Core);
        r.Screen.Start(snapshot.Id);
        var start = await r.StartAsync();
        await using var client = await StreamClient.ConnectAsync(r.Computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => r.Screens.Last?.Size is not null, "the capture start");
        r.Screens.Last!.Frames.Failed("The screen capture stopped: the display went to sleep");
        await Wait.UntilAsync(() => r.Screen.Model.Status.Phase == StreamPhase.Error, "the error");
        Assert.Equal("The screen capture stopped: the display went to sleep", r.Screen.Model.Status.Message);
        await Wait.UntilAsync(() => r.Got("stop").Count == 1, "the stop");
        Assert.True(await client.EndsAsync());

        // The computer closes the connection of the next mirror.
        r.Screen.Start(snapshot.Id);
        var second = await r.StartAsync(2);
        var again = await StreamClient.ConnectAsync(r.Computer.Certificate, second.Int("port")!.Value);
        await Wait.UntilAsync(() => r.Screens.Prepared.Count == 2 && r.Screens.Last!.Size is not null, "the second capture");
        await again.DisposeAsync();
        await Wait.UntilAsync(() => r.Screen.Model.Status.Phase == StreamPhase.Error, "the error of the closed connection");
        Assert.Equal("The connection to the computer closed", r.Screen.Model.Status.Message);
        Assert.True(r.Screens.Last!.Disposed);
    }

    [Fact]
    public async Task ChecksBeforeTheStart()
    {
        using var r = Make(35805, computerTakesScreen: false);
        var snapshot = await r.Computer.PairAsync(r.Core);
        r.Screen.Start(snapshot.Id);
        await Wait.UntilAsync(() => r.Screen.Model.Status.Phase == StreamPhase.Error, "the update error");
        Assert.Equal($"Update Flux on {r.Computer.Name} to mirror this screen", r.Screen.Model.Status.Message);
        Assert.Empty(r.Computer.Got(PacketType.Screen));

        // The displays and the permission reach the model.
        r.Screens.HasAccess = false;
        r.Core.Core.Host.Post(r.Screen.Refresh);
        await Wait.UntilAsync(() => r.Screen.Model.Displays.Count == 2 && !r.Screen.Model.HasAccess, "the displays");
        Assert.Equal("DISPLAY1", r.Screen.Model.Display);
        Assert.Equal(new DisplayInfo("DISPLAY1", "Monitor 1", 2340, 1080), r.Screen.Model.Displays[0]);

        // Without an encoder, this computer does not list flux.screen.
        Assert.True(new ScreenPlugin(r.Screens, r.Encoders).Supported);
        Assert.Empty(new ScreenPlugin(r.Screens).Incoming);
    }

    [Fact]
    public async Task APermissionErrorStopsTheStart()
    {
        using var r = Make(35840);
        var snapshot = await r.Computer.PairAsync(r.Core);
        r.Screens.FailPrepare = "Flux cannot record the screen";
        r.Screen.Start(snapshot.Id);
        await Wait.UntilAsync(() => r.Screen.Model.Status.Phase == StreamPhase.Error, "the error");
        Assert.Equal("Flux cannot record the screen", r.Screen.Model.Status.Message);
        Assert.Empty(r.Computer.Got(PacketType.Screen));
    }
}
