using System.Buffers.Binary;
using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// The microphone against a computer on loopback that speaks the wire of
// fluxd. A headless fluxd refuses the microphone, see StreamEndToEndTests,
// so the computer here takes the stream: it reads the start packet,
// connects to the payload listener with its certificate, and reads the PCM.
public class MicLoopbackTests
{
    // Each test uses its own block of 35 ports from first: the computer, the
    // core, and the payload listener.
    static (SystemTestComputer Computer, TestCore Core, MicPlugin Mic, FakeMicSource Source) Make(int first, bool computerTakesMic = true)
    {
        var computer = new SystemTestComputer(first, first + 1, computerTakesMic ? [PacketType.Mic] : [], [PacketType.Mic]);
        var source = new FakeMicSource();
        var mic = new MicPlugin(source) { PayloadPorts = (first + 30, first + 34) };
        var t = new TestCore(SystemTestComputer.CoreLan(first + 10), [mic]);
        return (computer, t, mic, source);
    }

    // The start packet that the computer got, after it arrived.
    static async Task<Packet> StartPacketAsync(SystemTestComputer computer, int count = 1)
    {
        await Wait.UntilAsync(() => computer.Got(PacketType.Mic).Count(p => p.String("state") == "start") >= count, "the start packet");
        return computer.Got(PacketType.Mic).Where(p => p.String("state") == "start").ElementAt(count - 1);
    }

    // Float stereo audio at 48 kHz: frame i has the value i / 1000 on both
    // channels.
    static byte[] Ramp(int frames, int from)
    {
        var data = new byte[frames * 8];
        for (var i = 0; i < frames; i++)
        {
            var v = (from + i) / 1000f;
            BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(i * 8), v);
            BinaryPrimitives.WriteSingleLittleEndian(data.AsSpan(i * 8 + 4), v);
        }
        return data;
    }

    [Fact]
    public async Task StreamsS16leToTheComputer()
    {
        var (computer, t, mic, source) = Make(35105);
        using var _ = computer;
        using var __ = t;
        var snapshot = await computer.PairAsync(t);

        mic.Start(snapshot.Id);
        await Wait.UntilAsync(() => mic.Model.Status.Phase == StreamPhase.Connecting, "the wait for the computer");
        Assert.Equal($"Waiting for {computer.Name}…", mic.Model.Status.Message);
        var start = await StartPacketAsync(computer);
        Assert.Equal(48000, start.Int("rate"));
        Assert.Equal(1, start.Int("channels"));
        Assert.Equal("s16le", start.String("format"));
        Assert.InRange(start.Int("port") ?? 0, 35135, 35139);

        await using var client = await StreamClient.ConnectAsync(computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => mic.Model.Status.Phase == StreamPhase.Starting, "the start of the stream");
        Assert.Equal($"Starting Flux Microphone on {computer.Name}…", mic.Model.Status.Message);
        await Wait.UntilAsync(() => source.Last is not null, "the capture");
        var capture = source.Last!;
        Assert.Equal("", capture.Input); // the default input

        computer.Send(new Packet(PacketType.Mic, new JsonObject { ["state"] = "live", ["source"] = "Flux Microphone" }));
        await Wait.UntilAsync(() => mic.Model.Status.Phase == StreamPhase.Live, "the live state");
        Assert.Equal(new StreamStatus(StreamPhase.Live, $"Live on {computer.Name} as Flux Microphone", snapshot.Id), mic.Model.Status);

        // The capture gives stereo floats, and the computer gets mono s16le.
        capture.Feed.Write(Ramp(480, 0), new AudioFormat(48000, 2, AudioSampleType.Float32));
        capture.Feed.Write(Ramp(480, 480), new AudioFormat(48000, 2, AudioSampleType.Float32));
        var bytes = await client.ReadUntilAsync(b => b.Length >= 960 * 2);
        Assert.Equal(960 * 2, bytes.Length);
        for (var i = 0; i < 960; i++)
        {
            var expected = (short)Math.Round(Math.Clamp(i / 1000f, -1f, 1f) * 32767.0);
            Assert.Equal(expected, BinaryPrimitives.ReadInt16LittleEndian(bytes.AsSpan(2 * i)));
        }
        await Wait.UntilAsync(() => mic.Model.Level > 0.4, "the level");

        // The user stops the microphone on the computer.
        computer.Send(new Packet(PacketType.Mic, new JsonObject { ["state"] = "stop" }));
        await Wait.UntilAsync(() => mic.Model.Status.Phase == StreamPhase.Idle, "the stop");
        Assert.Equal($"Stopped on {computer.Name}", mic.Model.Status.Message);
        Assert.Equal(0, mic.Model.Level);
        await Wait.UntilAsync(() => capture.Disposed, "the end of the capture");
        Assert.True(await client.EndsAsync());
        // The stop came from the computer, so this side sends no stop.
        Assert.DoesNotContain(computer.Got(PacketType.Mic), p => p.String("state") == "stop");
    }

    [Fact]
    public async Task StopTellsTheComputerAndAStartReplacesTheStream()
    {
        var (computer, t, mic, source) = Make(35140);
        using var _ = computer;
        using var __ = t;
        var snapshot = await computer.PairAsync(t);
        t.Core.Plugin<MicPlugin>()!.SelectInput("mic-2");
        Assert.Equal("mic-2", t.Core.Settings.String(MicPlugin.InputKey));

        mic.Start(snapshot.Id);
        var start = await StartPacketAsync(computer);
        await using var client = await StreamClient.ConnectAsync(computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => source.Last is not null, "the capture");
        Assert.Equal("mic-2", source.Last!.Input);

        // A new input applies to the running capture.
        mic.SelectInput("");
        Assert.Equal([""], source.Last.Used);

        // A second start stops the first stream and tells the computer.
        mic.Start(snapshot.Id);
        await Wait.UntilAsync(() => computer.Got(PacketType.Mic).Any(p => p.String("state") == "stop"), "the stop of the first stream");
        await Wait.UntilAsync(() => source.Captures.First().Disposed, "the end of the capture");
        Assert.True(await client.EndsAsync());
        var second = await StartPacketAsync(computer, 2);
        await using var again = await StreamClient.ConnectAsync(computer.Certificate, second.Int("port")!.Value);
        await Wait.UntilAsync(() => source.Captures.Count == 2, "the second capture");

        mic.Stop();
        await Wait.UntilAsync(() => computer.Got(PacketType.Mic).Count(p => p.String("state") == "stop") == 2, "the stop of the second stream");
        await Wait.UntilAsync(() => mic.Model.Status == StreamStatus.None, "the idle state");
        await Wait.UntilAsync(() => source.Captures.Last().Disposed, "the end of the capture");
        Assert.True(await again.EndsAsync());
    }

    [Fact]
    public async Task AComputerThatDoesNotConnectEndsTheStream()
    {
        var (computer, t, mic, source) = Make(35175);
        using var _ = computer;
        using var __ = t;
        mic.ConnectTimeout = TimeSpan.FromMilliseconds(500);
        var snapshot = await computer.PairAsync(t);
        mic.Start(snapshot.Id);
        await StartPacketAsync(computer);
        await Wait.UntilAsync(() => mic.Model.Status.Phase == StreamPhase.Error, "the error");
        Assert.Equal($"{computer.Name} did not connect. Update Flux on the computer.", mic.Model.Status.Message);
        Assert.Equal(snapshot.Id, mic.Model.Status.DeviceId);
        // The computer got the start, so it gets the stop too.
        await Wait.UntilAsync(() => computer.Got(PacketType.Mic).Any(p => p.String("state") == "stop"), "the stop");
        Assert.Empty(source.Captures);
    }

    [Fact]
    public async Task AnErrorOfTheComputerEndsTheStream()
    {
        var (computer, t, mic, source) = Make(35210);
        using var _ = computer;
        using var __ = t;
        var snapshot = await computer.PairAsync(t);
        mic.Start(snapshot.Id);
        var start = await StartPacketAsync(computer);
        await using var client = await StreamClient.ConnectAsync(computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => source.Last is not null, "the capture");
        computer.Send(new Packet(PacketType.Mic, new JsonObject { ["state"] = "error", ["message"] = "pw-cat is not installed on the computer" }));
        await Wait.UntilAsync(() => mic.Model.Status.Phase == StreamPhase.Error, "the error");
        Assert.Equal("pw-cat is not installed on the computer", mic.Model.Status.Message);
        await Wait.UntilAsync(() => source.Last!.Disposed, "the end of the capture");
        Assert.True(await client.EndsAsync());
    }

    [Fact]
    public async Task TheComputerClosesTheConnection()
    {
        var (computer, t, mic, source) = Make(35245);
        using var _ = computer;
        using var __ = t;
        var snapshot = await computer.PairAsync(t);
        mic.Start(snapshot.Id);
        var start = await StartPacketAsync(computer);
        var client = await StreamClient.ConnectAsync(computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => source.Last is not null, "the capture");
        await client.DisposeAsync();
        await Wait.UntilAsync(() => mic.Model.Status.Phase == StreamPhase.Error, "the error");
        Assert.Equal($"The connection to {computer.Name} closed", mic.Model.Status.Message);
        await Wait.UntilAsync(() => source.Last!.Disposed, "the end of the capture");
        // A capture that fails later ends nothing more.
        source.Last!.Feed.Fail("the microphone was disconnected");
        await Task.Delay(100);
        Assert.Equal($"The connection to {computer.Name} closed", mic.Model.Status.Message);
    }

    [Fact]
    public async Task ACaptureThatFailsEndsTheStream()
    {
        var (computer, t, mic, source) = Make(35280);
        using var _ = computer;
        using var __ = t;
        var snapshot = await computer.PairAsync(t);
        mic.Start(snapshot.Id);
        var start = await StartPacketAsync(computer);
        await using var client = await StreamClient.ConnectAsync(computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => source.Last is not null, "the capture");
        source.Last!.Feed.Fail("The microphone stopped: the device was removed");
        await Wait.UntilAsync(() => mic.Model.Status.Phase == StreamPhase.Error, "the error");
        Assert.Equal("The microphone stopped: the device was removed", mic.Model.Status.Message);
        await Wait.UntilAsync(() => computer.Got(PacketType.Mic).Any(p => p.String("state") == "stop"), "the stop");
    }

    [Fact]
    public async Task TheLinkDropEndsTheStream()
    {
        var (computer, t, mic, source) = Make(35315);
        using var _ = computer;
        using var __ = t;
        var snapshot = await computer.PairAsync(t);
        mic.Start(snapshot.Id);
        var start = await StartPacketAsync(computer);
        await using var client = await StreamClient.ConnectAsync(computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => source.Last is not null, "the capture");
        computer.Disconnect();
        await Wait.UntilAsync(() => mic.Model.Status.Phase == StreamPhase.Error, "the error");
        Assert.Equal($"The connection to {computer.Name} closed", mic.Model.Status.Message);
        await Wait.UntilAsync(() => source.Last!.Disposed, "the end of the capture");
    }

    [Fact]
    public async Task ChecksBeforeTheStart()
    {
        // A computer whose Flux cannot take the microphone.
        var (computer, t, mic, source) = Make(35350, computerTakesMic: false);
        using var _ = computer;
        using var __ = t;
        var snapshot = await computer.PairAsync(t);
        mic.Start(snapshot.Id);
        await Wait.UntilAsync(() => mic.Model.Status.Phase == StreamPhase.Error, "the update error");
        Assert.Equal($"Update Flux on {computer.Name} to use this computer as a microphone", mic.Model.Status.Message);
        Assert.Empty(computer.Got(PacketType.Mic)); // no start and no stop

        // A denied permission names the Settings page.
        source.Permission = MicPermission.Denied;
        mic.Start(snapshot.Id);
        await Wait.UntilAsync(() => mic.Model.Status.Message == MicPlugin.DeniedText, "the permission error");
        await Wait.UntilAsync(() => mic.Model.Permission == MicPermission.Denied, "the permission in the model");

        // An unknown computer.
        source.Permission = MicPermission.Undetermined;
        mic.Start("nobody");
        await Wait.UntilAsync(() => mic.Model.Status.Message == "the computer is not known", "the unknown error");
        Assert.Equal(1, source.Asked); // Windows asked once and granted
    }

    [Fact]
    public async Task NoInputGivesTheNoMicrophoneError()
    {
        var (computer, t, mic, source) = Make(35385);
        using var _ = computer;
        using var __ = t;
        var snapshot = await computer.PairAsync(t);
        source.SetInputs();
        await Wait.UntilAsync(() => mic.Model.Inputs.Count == 0, "the empty input list");
        mic.Start(snapshot.Id);
        var start = await StartPacketAsync(computer);
        await using var client = await StreamClient.ConnectAsync(computer.Certificate, start.Int("port")!.Value);
        await Wait.UntilAsync(() => mic.Model.Status.Phase == StreamPhase.Error, "the error");
        Assert.Equal(MicPlugin.NoMicrophoneText, mic.Model.Status.Message);
        Assert.Empty(source.Captures);
        source.SetInputs(new MicInput("mic-9", "Studio Mic"));
        await Wait.UntilAsync(() => mic.Model.Inputs.Count == 1, "the new input");
    }
}
