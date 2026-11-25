using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// DesktopTests.swift of the Mac app. The decoder tests of the Mac use a
// fake output here, because Media Foundation is a part of the Windows app.
public class DesktopTests
{
    static Packet RoundTrip(Packet p) => Packet.Parse(p.Serialize())!;

    internal static byte[] Frames(params (byte Flags, byte[] Data)[] list)
    {
        var output = new List<byte>();
        foreach (var (flags, data) in list)
        {
            var n = (uint)data.Length;
            output.AddRange([(byte)(n >> 24), (byte)(n >> 16 & 0xFF), (byte)(n >> 8 & 0xFF), (byte)(n & 0xFF), flags]);
            output.AddRange(data);
        }
        return output.ToArray();
    }

    internal static readonly byte[] Sps = [0, 0, 0, 1, 0x67, 0x64, 0x00, 0x32];
    internal static readonly byte[] Pps = [0, 0, 0, 1, 0x68, 0xEE, 0x3C];

    [Fact]
    public void AudioIsOptInAndFramesStaySeparate()
    {
        Assert.False(DesktopPackets.Start(1742).Has("audio"));
        Assert.True(DesktopPackets.Start(1742, audio: true).Bool("audio"));
        var reader = new DesktopFrameReader();
        var result = reader.Push(Frames((DesktopFrame.Audio, [1, 2, 3, 4]), (DesktopFrame.Key, [0, 0, 1, 0x65])));
        Assert.True(result[0].IsAudio);
        Assert.False(result[0].IsConfig || result[0].IsKey || result[0].IsFormat);
        Assert.True(result[1].IsKey);
    }

    [Fact]
    public void CapabilityIsInBothLists()
    {
        var plugin = new DesktopPlugin();
        Assert.Equal(["flux.desktop", "flux.shortcuts"], plugin.Incoming);
        Assert.Equal(["flux.desktop", "flux.shortcuts"], plugin.Outgoing);
    }

    [Fact]
    public void StartBody()
    {
        var p = RoundTrip(DesktopPackets.Start(1742));
        Assert.Equal(PacketType.Desktop, p.Type);
        Assert.Equal("start", p.String("state"));
        Assert.Equal(1742, p.Int("port"));
        Assert.Equal(1920, p.Int("maxSize"));
        Assert.False(p.Has("monitor"));
        Assert.Equal("DP-1", DesktopPackets.Start(1742, "DP-1", 3024).String("monitor"));
        Assert.Equal(3024, DesktopPackets.Start(1742, "DP-1", 3024).Int("maxSize"));
        Assert.False(DesktopPackets.Start(1742, "").Has("monitor"));
        Assert.Equal("stop", DesktopPackets.Stop().String("state"));
    }

    [Fact]
    public void MaxSizeStaysInTheLimitsOfFluxd()
    {
        Assert.Equal(3456, DesktopPackets.Size(3456));
        Assert.Equal(3840, DesktopPackets.Size(6016));
        Assert.Equal(640, DesktopPackets.Size(320));
        Assert.Equal(1920, DesktopPackets.Size(0));
    }

    [Fact]
    public void ParsesReplies()
    {
        var live = new Packet(PacketType.Desktop, new JsonObject
        {
            ["state"] = "live", ["monitor"] = "eDP-1", ["monitors"] = new JsonArray("eDP-1", "DP-1"), ["width"] = 1920, ["height"] = 1200,
        });
        Assert.Equal(new DesktopReply.Live("eDP-1", ["eDP-1", "DP-1"], 1920, 1200), DesktopReply.Parse(RoundTrip(live)));
        Assert.Equal(new DesktopReply.Failed("off"), DesktopReply.Parse(new Packet(PacketType.Desktop, new JsonObject { ["state"] = "error", ["message"] = "off" })));
        Assert.Equal(new DesktopReply.Failed("The computer could not stream its screen"),
            DesktopReply.Parse(new Packet(PacketType.Desktop, new JsonObject { ["state"] = "error" })));
        Assert.Equal(new DesktopReply.Stop(), DesktopReply.Parse(new Packet(PacketType.Desktop, new JsonObject { ["state"] = "stop" })));
        Assert.Null(DesktopReply.Parse(new Packet(PacketType.Desktop, new JsonObject { ["state"] = "start" })));
        Assert.Null(DesktopReply.Parse(new Packet(PacketType.Screen, new JsonObject { ["state"] = "stop" })));
    }

    [Fact]
    public void ReadsFramesInAnyPieces()
    {
        var stream = Frames(
            (DesktopFrame.Format, [0x07, 0x80, 0x04, 0xB0]),
            (DesktopFrame.Config, [.. Sps, .. Pps]),
            (DesktopFrame.Key, [0, 0, 0, 1, 0x65, 1, 2]),
            (0, [0, 0, 0, 1, 0x41, 3]));
        var all = new DesktopFrameReader().Push(stream);
        Assert.Equal(4, all.Count);
        Assert.Equal((1920, 1200), all[0].Size);
        Assert.True(all[1].IsConfig);
        Assert.Null(all[1].Size);
        Assert.True(all[2].IsKey && !all[2].IsConfig);
        Assert.False(all[3].IsKey);
        Assert.Equal([0, 0, 0, 1, 0x41, 3], all[3].Data);

        // The network can cut the stream anywhere.
        var bytewise = new DesktopFrameReader();
        var pieces = new List<DesktopFrame>();
        foreach (var b in stream)
        {
            pieces.AddRange(bytewise.Push([b]));
        }
        Assert.Equal(all, pieces);
        var halves = new DesktopFrameReader();
        var cut = stream.Length / 2 + 1;
        var first = halves.Push(stream.AsSpan(0, cut));
        var rest = halves.Push(stream.AsSpan(cut));
        Assert.Equal(all, first.Concat(rest));
    }

    [Fact]
    public void ReadsLargeFramesAfterSmallOnes()
    {
        var big = Enumerable.Range(0, 300_000).Select(i => (byte)i).ToArray();
        var stream = Frames((0, [1, 2, 3]), (DesktopFrame.Key, big), (0, [4]));
        var reader = new DesktopFrameReader();
        var frames = new List<DesktopFrame>();
        for (var i = 0; i < stream.Length; i += 7000)
        {
            frames.AddRange(reader.Push(stream.AsSpan(i, Math.Min(7000, stream.Length - i))));
        }
        Assert.Equal(3, frames.Count);
        Assert.Equal(big, frames[1].Data);
        Assert.Equal([4], frames[2].Data);
    }

    [Fact]
    public void RefusesAHugeFrame()
    {
        var r = new DesktopFrameReader(maxFrame: 32);
        Assert.Throws<InvalidDataException>(() => r.Push(Frames((0, new byte[64]))));
    }

    [Fact]
    public void ParameterSetsNeedBothUnits()
    {
        var sets = DesktopH264.ParameterSets([.. Sps, .. Pps])!.Value;
        Assert.Equal([0x67, 0x64, 0x00, 0x32], sets.Sps);
        Assert.Equal([0x68, 0xEE, 0x3C], sets.Pps);
        Assert.Null(DesktopH264.ParameterSets(Sps));
        Assert.Null(DesktopH264.ParameterSets([]));
    }

    [Fact]
    public void AvccHasLengthsAndNoParameterSets()
    {
        // A 3-byte start code and an access unit delimiter too.
        byte[] frame = [.. Sps, .. Pps, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x65, 1, 2, 0, 0, 0, 1, 0x06, 5];
        Assert.Equal([0, 0, 0, 3, 0x65, 1, 2, 0, 0, 0, 2, 0x06, 5], DesktopH264.Avcc(frame));
        Assert.Equal([0, 0, 0, 2, 0x41, 3], DesktopH264.Avcc([0, 0, 0, 1, 0x41, 3]));
        Assert.Empty(DesktopH264.Avcc([]));
    }

    static byte[] Hex(string s) => Convert.FromHexString(s);

    internal sealed class FakeVideo : IDesktopVideoOutput
    {
        public List<(byte[] Sps, byte[] Pps)> Configured { get; } = [];
        public List<(byte[] Data, bool Key)> Decoded { get; } = [];
        public List<bool> Flushes { get; } = [];
        public bool IsReady { get; set; } = true;
        public bool NeedsFlush { get; set; }

        public bool Configure(byte[] sps, byte[] pps)
        {
            lock (this)
            {
                Configured.Add((sps, pps));
                return true;
            }
        }

        public void Decode(byte[] annexB, bool key)
        {
            lock (this)
            {
                Decoded.Add((annexB, key));
            }
        }

        public void Flush(bool clear)
        {
            lock (this)
            {
                Flushes.Add(clear);
                NeedsFlush = false;
            }
        }

        public int Count
        {
            get
            {
                lock (this)
                {
                    return Decoded.Count;
                }
            }
        }
    }

    // With VAAPI the key frames carry an SPS and a PPS that differ from the
    // config frame. These are the sets of the stream in issue 62.
    [Fact]
    public void AKeyFrameSetsItsOwnFormat()
    {
        var headerSps = Hex("67640c32ac2b4014005ad350101014000003000400000300f23c2010a8");
        var headerPps = Hex("68ee0462c0");
        var keySps = Hex("67640c32ac2b4014005ad350101014000003000400000300f23c2211a8");
        var keyPps = Hex("68ee3830");
        byte[] start = [0, 0, 0, 1];
        byte[] frame = [.. start, .. keySps, .. start, .. keyPps, .. start, 0x65, 0x88, 0x84];

        var video = new DesktopVideo();
        var output = new FakeVideo();
        video.Attach(output);
        Assert.True(video.Configure(headerSps, headerPps));
        video.Show(frame, key: false);
        Assert.Equal([headerSps, headerPps], video.ParameterSets);
        // The frames before the first key frame do not show.
        Assert.Empty(output.Decoded);
        video.Show(frame, key: true);
        Assert.Equal([keySps, keyPps], video.ParameterSets);
        Assert.Single(output.Decoded);
        Assert.Equal(2, output.Configured.Count);

        // A set that is not valid keeps the format.
        byte[] bad = [0x67, 0x00];
        Assert.False(DesktopVideo.Valid(bad, keyPps));
        byte[] badFrame = [.. start, .. bad, .. start, .. keyPps, .. start, 0x65, 0x88];
        video.Show(badFrame, key: true);
        Assert.Equal([keySps, keyPps], video.ParameterSets);
    }

    [Fact]
    public void ABehindDecoderSkipsToTheNextKeyFrame()
    {
        var video = new DesktopVideo();
        var output = new FakeVideo();
        video.Attach(output);
        Assert.True(video.Configure([0x67, 0x64, 0x00, 0x32], [0x68, 0xEE, 0x3C]));
        byte[] key = [0, 0, 0, 1, 0x65, 1];
        byte[] delta = [0, 0, 0, 1, 0x41, 2];
        video.Show(key, key: true);
        video.Show(delta, key: false);
        Assert.Equal(2, output.Decoded.Count);
        output.IsReady = false;
        video.Show(delta, key: false);
        output.IsReady = true;
        // The picture waits for a key frame after a drop.
        video.Show(delta, key: false);
        Assert.Equal(2, output.Decoded.Count);
        video.Show(key, key: true);
        Assert.Equal(3, output.Decoded.Count);
        // A failed decoder flushes and waits for a key frame.
        output.NeedsFlush = true;
        video.Show(delta, key: false);
        Assert.Equal(3, output.Decoded.Count);
        Assert.Contains(false, output.Flushes);
    }

    // A new view can take the video before the old view goes away. The old
    // view must not take the video from the new one.
    [Fact]
    public void AnOldOutputDoesNotDetachTheNewOne()
    {
        var video = new DesktopVideo();
        var old = new FakeVideo();
        var next = new FakeVideo();
        video.Attach(old);
        video.Attach(next);
        video.Detach(old);
        Assert.True(video.Shows(next));
        video.Detach(next);
        Assert.False(video.Shows(next));
    }

    [Fact]
    public void AnOutputGetsTheSetsOfTheStream()
    {
        var video = new DesktopVideo();
        Assert.True(video.Configure([0x67, 0x64, 0x00, 0x32], [0x68, 0xEE, 0x3C]));
        var output = new FakeVideo();
        video.Attach(output);
        Assert.Single(output.Configured);
        video.Reset();
        Assert.Empty(video.ParameterSets);
        Assert.Contains(true, output.Flushes);
    }

    sealed class FakeAudio(bool works = true) : IDesktopAudioOutput
    {
        public List<(float[] Samples, float Volume, Action Played)> Played { get; } = [];
        public int Stops { get; private set; }

        public bool Play(float[] samples, float volume, Action played)
        {
            if (!works)
            {
                return false;
            }
            Played.Add((samples, volume, played));
            return true;
        }

        public void Stop() => Stops++;
    }

    [Fact]
    public void AudioPlaysABoundedQueue()
    {
        var output = new FakeAudio();
        var audio = new DesktopAudio(output);
        audio.SetVolume(0.5f);
        // 2 frames of stereo: left 0x4000, right -0x8000, then 0 and 0x7FFF.
        audio.Feed([0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0xFF, 0x7F]);
        Assert.Single(output.Played);
        Assert.Equal([0.5f, -1f, 0f, 32767 / 32768f], output.Played[0].Samples);
        Assert.Equal(0.5f, output.Played[0].Volume);
        // Frames of a wrong size go away.
        audio.Feed([1, 2, 3]);
        audio.Feed([]);
        audio.Feed(new byte[DesktopAudio.MaxFrameBytes + 4]);
        Assert.Single(output.Played);
        // A full queue drops the frame, so that audio never delays the video.
        for (var i = 0; i < 20; i++)
        {
            audio.Feed(new byte[8]);
        }
        Assert.Equal(DesktopAudio.MaxPending, output.Played.Count);
        output.Played[0].Played();
        audio.Feed(new byte[8]);
        Assert.Equal(DesktopAudio.MaxPending + 1, output.Played.Count);
        // A stop forgets the queue, and late callbacks do nothing.
        audio.Stop();
        Assert.Equal(1, output.Stops);
        Assert.Equal(0, audio.Pending);
        output.Played[1].Played();
        Assert.Equal(0, audio.Pending);
        audio.SetVolume(float.NaN);
        audio.SetVolume(7);
        audio.Feed(new byte[4]);
        Assert.Equal(1f, output.Played[^1].Volume);
    }

    [Fact]
    public void AudioStopsAfterAFailureUntilTheNextStream()
    {
        var output = new FakeAudio(works: false);
        var audio = new DesktopAudio(output);
        audio.Feed(new byte[4]);
        audio.Feed(new byte[4]);
        Assert.Equal(0, audio.Pending);
        new DesktopAudio(null).Feed(new byte[4]);
    }

    [Fact]
    public void TheVideoFitsTheView()
    {
        // A 16:10 video in a wide view: bars at the left and the right.
        var g = new DesktopGeometry(new RemoteSize(2000, 1000), new RemoteSize(1920, 1200));
        Assert.Equal(new RemoteRect(200, 0, 1600, 1000), g.Fit);
        Assert.Equal(1000.0 / 1200, g.Scale, 4);
        Assert.Equal(new DesktopPoint(0, 0), g.Position(new RemotePoint(200, 0)));
        Assert.Equal(new DesktopPoint(0.5, 0.5), g.Position(new RemotePoint(1000, 500)));
        Assert.Equal(new DesktopPoint(1, 1), g.Position(new RemotePoint(1800, 1000)));
        Assert.Null(g.Position(new RemotePoint(100, 500)));
        Assert.Equal(new DesktopPoint(0, 0.5), g.Position(new RemotePoint(100, 500), clamp: true));

        // A tall view: bars at the top and the bottom.
        var tall = new DesktopGeometry(new RemoteSize(960, 1000), new RemoteSize(1920, 1200));
        Assert.Equal(new RemoteRect(0, 200, 960, 600), tall.Fit);
        Assert.Null(tall.Position(new RemotePoint(480, 100)));
        var p = tall.Position(new RemotePoint(240, 350))!.Value;
        Assert.Equal(0.25, p.X, 4);
        Assert.Equal(0.25, p.Y, 4);

        // Without a video size, nothing is on the video.
        Assert.Null(new DesktopGeometry(new RemoteSize(100, 100), RemoteSize.Zero).Position(new RemotePoint(50, 50)));
    }

    [Fact]
    public void PositionPackets()
    {
        var at = RoundTrip(RemoteInput.At(0.123456, 2));
        Assert.Equal(0.1235, at.Double("x"));
        Assert.Equal(1, at.Double("y"));
        Assert.False(at.Has("dx"));

        var click = RoundTrip(RemoteInput.ClickAt(RemoteClick.Right, 0.5, 0.25));
        Assert.True(click.Bool("rightclick"));
        Assert.Equal(0.5, click.Double("x"));
        Assert.Equal(0.25, click.Double("y"));

        Assert.True(RemoteInput.HoldAt(true, 0, 0).Bool("singlehold"));
        Assert.True(RemoteInput.HoldAt(false, 0, 0).Bool("singlerelease"));
        Assert.Equal(0, RemoteInput.At(-1, double.NaN).Double("x"));
        Assert.Equal(0, RemoteInput.At(-1, double.NaN).Double("y"));

        var scroll = RoundTrip(RemoteInput.ScrollAt(0, -3, 0.5, 0.5));
        Assert.True(scroll.Bool("scroll"));
        Assert.Equal(-3, scroll.Double("dy"));
        Assert.Equal(0.5, scroll.Double("x"));
    }

    [Fact]
    public void MotionThrottle()
    {
        var t = new DesktopMotionThrottle(0.016);
        var a = new DesktopPoint(0.1, 0.1);
        var b = new DesktopPoint(0.2, 0.2);
        var c = new DesktopPoint(0.3, 0.3);
        Assert.Equal(a, t.Move(a, 1));
        // A fast motion waits, and only its last position goes out.
        Assert.Null(t.Move(b, 1.005));
        Assert.Null(t.Move(c, 1.008));
        Assert.Null(t.Flush(1.01));
        Assert.Equal(c, t.Flush(1.017));
        Assert.Null(t.Flush(1.05));
        // The same position does not go again.
        Assert.Null(t.Move(c, 2));
        Assert.Equal(a, t.Move(a, 2));
        t.Reset(b, 3);
        Assert.Null(t.Move(b, 4));
    }

    [Fact]
    public void ClickDragAndDoubleClick()
    {
        var p = new DesktopPointer();
        var start = new DesktopPoint(0.5, 0.5);
        // A press that does not move clicks at the press.
        p.LeftDown(new RemotePoint(100, 100), start);
        Assert.Empty(p.LeftDragged(new RemotePoint(101, 101), new DesktopPoint(0.51, 0.51)));
        var click = p.LeftUp(new RemotePoint(101, 101), new DesktopPoint(0.51, 0.51), 1);
        Assert.Single(click);
        Assert.True(click[0].Bool("singleclick"));
        Assert.Equal(0.5, click[0].Double("x"));

        // The second click of a double click goes to the first position.
        p.LeftDown(new RemotePoint(102, 100), new DesktopPoint(0.52, 0.5));
        var second = p.LeftUp(new RemotePoint(102, 100), new DesktopPoint(0.52, 0.5), 2);
        Assert.Equal(0.5, second[0].Double("x"));

        // A press that moves drags: the press at the start, the motion, and the release at the end.
        p.LeftDown(new RemotePoint(10, 10), new DesktopPoint(0.1, 0.1));
        var begin = p.LeftDragged(new RemotePoint(20, 10), new DesktopPoint(0.2, 0.1));
        Assert.True(p.Dragging);
        Assert.Equal(2, begin.Count);
        Assert.True(begin[0].Bool("singlehold"));
        Assert.Equal(0.1, begin[0].Double("x"));
        Assert.Equal(0.2, begin[1].Double("x"));
        Assert.False(begin[1].Has("singlehold"));
        Assert.Single(p.LeftDragged(new RemotePoint(30, 10), new DesktopPoint(0.3, 0.1)));
        var end = p.LeftUp(new RemotePoint(30, 10), new DesktopPoint(0.3, 0.1), 1);
        Assert.Single(end);
        Assert.True(end[0].Bool("singlerelease"));
        Assert.Equal(0.3, end[0].Double("x"));
        Assert.False(p.Pressed);
        Assert.Empty(p.LeftUp(new RemotePoint(30, 10), start, 1));
    }

    [Fact]
    public void CancelReleasesADrag()
    {
        var p = new DesktopPointer();
        p.LeftDown(RemotePoint.Zero, new DesktopPoint(0, 0));
        Assert.Empty(p.Cancel(null));
        p.LeftDown(RemotePoint.Zero, new DesktopPoint(0, 0));
        p.LeftDragged(new RemotePoint(50, 0), new DesktopPoint(0.4, 0));
        var end = p.Cancel(null);
        Assert.Single(end);
        Assert.True(end[0].Bool("singlerelease"));
    }

    [Fact]
    public void InputStateHasTheDesktop()
    {
        var model = new RemoteInputModel();
        Assert.False(model.IsDesktopOn("a"));
        model.Set("a", true, desktop: true);
        Assert.True(model.IsOn("a"));
        Assert.True(model.IsDesktopOn("a"));
        // An older fluxd does not send the field.
        model.Set("a", true);
        Assert.False(model.IsDesktopOn("a"));
    }

    [Fact]
    public void StatusIsActiveWhileItConnectsOrShows()
    {
        Assert.False(new DesktopStatus().Active);
        Assert.True(new DesktopStatus(DesktopPhase.Connecting).Active);
        Assert.True(new DesktopStatus(DesktopPhase.Live).Active);
        Assert.False(new DesktopStatus(DesktopPhase.Error, "no").Active);
    }
}
