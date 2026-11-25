using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// MicTests.swift of the Mac app: the packets, the replies, and the PCM
// helpers. The queue and the feed are new on Windows.
public class MicTests
{
    [Fact]
    public void CapabilityIsInBothLists()
    {
        var plugin = new MicPlugin(new FakeMicSource());
        Assert.Contains(PacketType.Mic, plugin.Incoming);
        Assert.Contains(PacketType.Mic, plugin.Outgoing);
        // Without a microphone source, this computer does not list the type.
        var none = new MicPlugin();
        Assert.Empty(none.Incoming);
        Assert.Empty(none.Outgoing);
        Assert.False(none.Supported);
        Assert.Equal([PacketType.Mic], ((IFluxPlugin)none).HandledTypes);
    }

    [Fact]
    public void StartBodyHasTheFormat()
    {
        var p = MicPackets.Start(1745);
        Assert.Equal(PacketType.Mic, p.Type);
        Assert.Equal("start", p.String("state"));
        Assert.Equal(1745, p.Int("port"));
        Assert.Equal(48000, p.Int("rate"));
        Assert.Equal(1, p.Int("channels"));
        Assert.Equal("s16le", p.String("format"));
        Assert.Equal(1745, Packet.Parse(p.Serialize())?.Int("port"));
        Assert.Equal("stop", MicPackets.Stop().String("state"));
    }

    static Packet Mic(JsonObject body) => new(PacketType.Mic, body);

    [Fact]
    public void ParsesReplies()
    {
        Assert.Equal(new MicReply.Live("Flux Microphone"), MicReply.Parse(Mic(new JsonObject { ["state"] = "live", ["source"] = "Flux Microphone" })));
        Assert.Equal(new MicReply.Live("Flux Microphone"), MicReply.Parse(Mic(new JsonObject { ["state"] = "live" })));
        Assert.Equal(new MicReply.Failed("no pw-cat"), MicReply.Parse(Mic(new JsonObject { ["state"] = "error", ["message"] = "no pw-cat" })));
        Assert.Equal(new MicReply.Failed("The computer could not start the microphone"),
            MicReply.Parse(Mic(new JsonObject { ["state"] = "error", ["message"] = "" })));
        Assert.Equal(new MicReply.Stop(), MicReply.Parse(Mic(new JsonObject { ["state"] = "stop" })));
        Assert.Null(MicReply.Parse(Mic(new JsonObject { ["state"] = "start" })));
        Assert.Null(MicReply.Parse(new Packet(PacketType.Webcam, new JsonObject { ["state"] = "live" })));
    }

    [Fact]
    public void WritesLittleEndianSamples()
    {
        short[] samples = [0x0102, -1, short.MinValue, short.MaxValue];
        var output = new byte[8];
        Pcm.ToLittleEndian(samples, output);
        Assert.Equal([0x02, 0x01, 0xff, 0xff, 0x00, 0x80, 0xff, 0x7f], output);
        Assert.Equal(output, Pcm.ToLittleEndian(samples));
        Assert.Throws<ArgumentException>(() => Pcm.ToLittleEndian(samples, new byte[7]));
    }

    [Fact]
    public void PeakGoesFromSilenceToFullScale()
    {
        Assert.Equal(0, Pcm.Peak(new short[10]));
        Assert.Equal(0.5, Pcm.Peak([100, -16384, 20]), 3);
        Assert.Equal(1, Pcm.Peak([short.MinValue]));
        // Only the samples in the span count.
        short[] samples = [0, short.MaxValue];
        Assert.Equal(0, Pcm.Peak(samples.AsSpan(0, 1)));
    }

    [Fact]
    public async Task QueueDropsTheOldestChunks()
    {
        var queue = new MicQueue();
        for (var i = 0; i < MicQueue.MaxChunks; i++)
        {
            var chunk = new byte[960]; // 10 ms of audio
            chunk[0] = (byte)i;
            Assert.False(queue.Push(chunk));
        }
        var newest = new byte[960];
        newest[0] = 200;
        Assert.True(queue.Push(newest)); // the 101st chunk drops the oldest
        Assert.Equal(1, queue.Dropped);
        Assert.Equal(MicQueue.MaxChunks, queue.Count);
        Assert.Equal(1, (await queue.TakeAsync(default))![0]); // chunk 0 is gone

        // Large chunks drop by their size: at most 3.5 seconds wait.
        var large = new MicQueue();
        for (var i = 0; i < 10; i++)
        {
            large.Push(new byte[48000 * 2]); // 1 second each
        }
        Assert.Equal(3, large.Count);
        Assert.Equal(7, large.Dropped);
    }

    [Fact]
    public async Task QueueWaitsForAChunkAndEnds()
    {
        var queue = new MicQueue();
        var take = queue.TakeAsync(default);
        await Task.Delay(50);
        Assert.False(take.IsCompleted);
        queue.Push([1, 2]);
        Assert.Equal([1, 2], await take.WaitAsync(TimeSpan.FromSeconds(5)));
        var end = queue.TakeAsync(default);
        queue.Complete();
        Assert.Null(await end.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.False(queue.Push([3])); // a queue that ended takes nothing
    }

    [Fact]
    public void FeedConvertsAndReportsAFormatThatDoesNotConvert()
    {
        var samples = new List<short[]>();
        var errors = new List<string>();
        var feed = new MicFeed(samples.Add, errors.Add);
        // 2 frames of stereo float at 48 kHz: the channels mix into 1.
        var data = new byte[16];
        BitConverter.TryWriteBytes(data.AsSpan(0), 0.5f);
        BitConverter.TryWriteBytes(data.AsSpan(4), 0.5f);
        BitConverter.TryWriteBytes(data.AsSpan(8), -1f);
        BitConverter.TryWriteBytes(data.AsSpan(12), 0f);
        feed.Write(data, new AudioFormat(48000, 2, AudioSampleType.Float32));
        Assert.Equal([16384, -16384], Assert.Single(samples));

        feed.Write(data, new AudioFormat(0, 2, AudioSampleType.Float32));
        Assert.Equal("The microphone gave audio that Flux cannot send. Flux cannot convert 0 Hz audio with 2 channels", Assert.Single(errors));
        // After a failure, the feed takes no more audio.
        feed.Write(data, new AudioFormat(48000, 2, AudioSampleType.Float32));
        Assert.Single(samples);
    }

    [Fact]
    public void TextsNameThisComputer()
    {
        Assert.Equal("Update Flux on omarchy to use this computer as a microphone", MicPlugin.UpdateText("omarchy"));
        Assert.Equal("This computer has no microphone", MicPlugin.NoMicrophoneText);
        Assert.Equal("Allow the microphone for Flux in Settings > Privacy & security > Microphone", MicPlugin.DeniedText);
    }
}
