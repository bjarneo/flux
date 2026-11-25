using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// WebcamProtocolTests and ScreenProtocolTests of StreamTests.swift of the
// Mac app: the packets, the replies, and the Annex-B framing.
public class StreamProtocolTests
{
    static readonly byte[] Sps = [0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1F];
    static readonly byte[] Pps = [0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80];
    static readonly byte[] Idr = [0, 0, 0, 1, 0x65, 0x11, 0x22];
    static readonly byte[] PFrame = [0, 0, 0, 1, 0x41, 0x33, 0x44];

    static byte[] Join(params byte[][] parts) => parts.SelectMany(p => p).ToArray();

    [Fact]
    public void WebcamStartBodyHasEveryField()
    {
        var p = WebcamPackets.Start(1742, 1920, 1080);
        Assert.Equal(PacketType.Webcam, p.Type);
        Assert.Equal("start", p.String("state"));
        Assert.Equal(1742, p.Int("port"));
        Assert.Equal(1920, p.Int("width"));
        Assert.Equal(1080, p.Int("height"));
        Assert.Equal(30, p.Int("fps"));
        Assert.Equal("h264", p.String("codec"));
        Assert.Equal(1742, Packet.Parse(p.Serialize())?.Int("port"));
    }

    [Fact]
    public void WebcamStopBody() => Assert.Equal("stop", WebcamPackets.Stop().String("state"));

    static Packet Webcam(JsonObject body) => new(PacketType.Webcam, body);

    [Fact]
    public void ParsesWebcamReplies()
    {
        Assert.Equal(new WebcamReply.Live("/dev/video42", "Flux Camera"),
            WebcamReply.Parse(Webcam(new JsonObject { ["state"] = "live", ["device"] = "/dev/video42", ["label"] = "Flux Camera" })));
        Assert.Equal(new WebcamReply.Failed("v4l2loopback is missing"),
            WebcamReply.Parse(Webcam(new JsonObject { ["state"] = "error", ["message"] = "v4l2loopback is missing" })));
        Assert.Equal(new WebcamReply.Stop(), WebcamReply.Parse(Webcam(new JsonObject { ["state"] = "stop" })));
        Assert.Null(WebcamReply.Parse(Webcam(new JsonObject { ["state"] = "start" })));
        Assert.Null(WebcamReply.Parse(new Packet(PacketType.Ping)));
    }

    [Fact]
    public void LiveWithoutLabelGetsTheDefaultName()
    {
        Assert.Equal(new WebcamReply.Live("/dev/video42", "Flux Camera"),
            WebcamReply.Parse(Webcam(new JsonObject { ["state"] = "live", ["device"] = "/dev/video42" })));
        Assert.Equal(new WebcamReply.Failed("The computer could not start the camera"),
            WebcamReply.Parse(Webcam(new JsonObject { ["state"] = "error", ["message"] = "" })));
    }

    [Fact]
    public void ParsesConfigFromTheComputer()
    {
        var partial = WebcamReply.Parse(Webcam(new JsonObject { ["state"] = "config", ["config"] = new JsonObject { ["brightness"] = 0.3 } }));
        var config = Assert.IsType<WebcamReply.Config>(partial);
        Assert.False(config.Reset);
        Assert.Equal(0.3, new WebcamConfig().Merged(config.Partial).Brightness, 6);

        var reset = Assert.IsType<WebcamReply.Config>(WebcamReply.Parse(Webcam(new JsonObject { ["state"] = "config", ["reset"] = true })));
        Assert.True(reset.Reset);
        Assert.Null(reset.Partial);
        // A config message with neither a config nor a reset means nothing.
        Assert.Null(WebcamReply.Parse(Webcam(new JsonObject { ["state"] = "config" })));
    }

    [Fact]
    public void ConfigPacketCarriesConfigAndCaps()
    {
        var caps = new WebcamCaps { ZoomMax = 8, WhiteBalance = new(["auto", "daylight", "cloudy"]) };
        var p = Packet.Parse(WebcamPackets.Config(new WebcamConfig { Brightness = 0.3 }, caps).Serialize())!;
        Assert.Equal(PacketType.Webcam, p.Type);
        Assert.Equal("config", p.String("state"));
        Assert.Equal(0.3, Json.Double(p.Object("config")?["brightness"]) ?? 0, 6);
        var c = p.Object("caps")!;
        Assert.Equal(8, Json.Double(c["zoomMax"]));
        Assert.Equal(["auto", "daylight", "cloudy"], Json.Strings(c["whiteBalance"]));
        Assert.Equal([720, 1080], c["resolutions"]!.AsArray().Select(n => Json.Int(n) ?? 0));
    }

    [Fact]
    public void FindsNalTypes()
    {
        Assert.Equal([7, 8, 5], AnnexB.NalTypes(Join(Sps, Pps, Idr)));
        // A 3-byte start code works too.
        Assert.Equal([1], AnnexB.NalTypes([0, 0, 1, 0x41, 0x01]));
    }

    [Fact]
    public void AddsMissingStartCode()
    {
        Assert.Equal(Idr, AnnexB.WithStartCode([0x65, 0x11, 0x22]));
        Assert.Equal(Idr, AnnexB.WithStartCode(Idr));
    }

    [Fact]
    public void FramerPutsConfigBeforeEachIdr()
    {
        var f = new AnnexBFramer();
        f.OnConfig(Join(Sps, Pps));
        Assert.Equal(Join(Sps, Pps, Idr), f.OnFrame(Idr, keyFrame: true));
        Assert.Equal(PFrame, f.OnFrame(PFrame, keyFrame: false));
        Assert.Equal(Join(Sps, Pps, Idr), f.OnFrame(Idr, keyFrame: true));
    }

    [Fact]
    public void FramerDropsFramesBeforeTheFirstIdr()
    {
        var f = new AnnexBFramer();
        f.OnConfig(Join(Sps, Pps));
        Assert.Null(f.OnFrame(PFrame, keyFrame: false));
        Assert.Equal(Join(Sps, Pps, Idr), f.OnFrame(Idr, keyFrame: true));
    }

    [Fact]
    public void FramerDoesNotRepeatConfigThatTheFrameHas()
    {
        var f = new AnnexBFramer();
        f.OnConfig(Join(Sps, Pps));
        Assert.Equal(Join(Sps, Pps, Idr), f.OnFrame(Join(Sps, Pps, Idr), keyFrame: true));
    }

    [Fact]
    public void FramerFindsIdrWithoutTheKeyFlag()
    {
        var f = new AnnexBFramer();
        f.OnConfig(Join(Sps, Pps));
        Assert.Equal(Join(Sps, Pps, Idr), f.OnFrame(Idr, keyFrame: false));
    }

    [Fact]
    public void ConvertsLengthPrefixedUnits()
    {
        // An SEI of 2 bytes and an IDR slice of 3 bytes, in the MP4 form.
        byte[] four = [0, 0, 0, 2, 0x06, 0x05, 0, 0, 0, 3, 0x65, 0x11, 0x22];
        Assert.True(AnnexB.ConvertLengthPrefixed(ref four, 4));
        Assert.Equal(Join([0, 0, 0, 1, 0x06, 0x05], Idr), four);
        Assert.Equal([6, 5], AnnexB.NalTypes(four));

        byte[] two = [0, 2, 0x06, 0x05, 0, 3, 0x65, 0x11, 0x22];
        Assert.True(AnnexB.ConvertLengthPrefixed(ref two, 2));
        Assert.Equal(Join([0, 0, 0, 1, 0x06, 0x05], Idr), two);
    }

    [Fact]
    public void RejectsLengthsPastTheEnd()
    {
        byte[] truncated = [0, 0, 0, 9, 0x65, 0x11];
        Assert.False(AnnexB.ConvertLengthPrefixed(ref truncated, 4));
        byte[] partialHeader = [0, 0, 0, 1, 0x65, 0, 0];
        Assert.False(AnnexB.ConvertLengthPrefixed(ref partialHeader, 4));
        byte[] any = [1, 2];
        Assert.False(AnnexB.ConvertLengthPrefixed(ref any, 5));
    }

    [Fact]
    public void EncodedVideoFramesTheOutputOfAnEncoder()
    {
        var output = new List<byte[]>();
        var errors = new List<string>();
        var video = new EncodedVideo(output.Add, errors.Add);
        video.ParameterSets(Join(Sps, Pps));
        video.AccessUnit(PFrame, keyFrame: false); // before the first IDR frame: dropped
        video.LengthPrefixed([0, 0, 0, 3, 0x65, 0x11, 0x22], 4, keyFrame: true);
        video.AccessUnit([0x41, 0x33, 0x44], keyFrame: false); // gets its start code
        video.LengthPrefixed([0, 0, 0, 9, 0x41], 4, keyFrame: false); // a length past the end: dropped
        Assert.Equal([Join(Sps, Pps, Idr), PFrame], output);
        video.Fail("the encoder stopped");
        Assert.Equal(["the encoder stopped"], errors);
    }

    [Fact]
    public void ScreenStartBodyHasTheSize()
    {
        var p = ScreenPackets.Start(1750, 496, 1072);
        Assert.Equal(PacketType.Screen, p.Type);
        Assert.Equal("start", p.String("state"));
        Assert.Equal(1750, p.Int("port"));
        Assert.Equal(496, p.Int("width"));
        Assert.Equal(1072, p.Int("height"));
        Assert.Equal("h264", p.String("codec"));
        Assert.Equal("stop", ScreenPackets.Stop().String("state"));
    }

    static Packet Screen(JsonObject body) => new(PacketType.Screen, body);

    [Fact]
    public void ParsesScreenReplies()
    {
        Assert.Equal(new ScreenReply.Live("mpv"), ScreenReply.Parse(Screen(new JsonObject { ["state"] = "live", ["player"] = "mpv" })));
        Assert.Equal(new ScreenReply.Failed("no mpv"), ScreenReply.Parse(Screen(new JsonObject { ["state"] = "error", ["message"] = "no mpv" })));
        Assert.Equal(new ScreenReply.Failed("The computer could not show the screen"), ScreenReply.Parse(Screen(new JsonObject { ["state"] = "error" })));
        Assert.Equal(new ScreenReply.Stop(), ScreenReply.Parse(Screen(new JsonObject { ["state"] = "stop" })));
        Assert.Null(ScreenReply.Parse(Screen(new JsonObject { ["state"] = "start" })));
        Assert.Null(ScreenReply.Parse(new Packet(PacketType.Mic, new JsonObject { ["state"] = "stop" })));
    }

    static void AssertFit(int w, int h, int ew, int eh)
    {
        var size = MirrorSize.Fit(w, h);
        Assert.Equal((ew, eh), size);
    }

    [Fact]
    public void FitKeepsTheShapeUnder1080()
    {
        // A portrait screen: the long side is at most 1080 px, both sides a
        // multiple of 16.
        AssertFit(1080, 2340, 496, 1072);
        // The same screen in landscape swaps the sides.
        AssertFit(2340, 1080, 1072, 496);
        // 720 x 1280 scales by 1080 / 1280, then aligns down to 16 px.
        AssertFit(720, 1280, 592, 1072);
        // A screen under 1080 px keeps its size.
        AssertFit(480, 800, 480, 800);
        // A Retina MacBook display.
        AssertFit(3456, 2234, 1072, 688);
        // Full HD and 4K monitors.
        AssertFit(1920, 1080, 1072, 592);
        AssertFit(3840, 2160, 1072, 592);
        Assert.Null(MirrorSize.Fit(0, 900));
        Assert.Null(MirrorSize.Fit(1920, -1));
    }

    [Fact]
    public void BitrateHasAFloor()
    {
        Assert.Equal(2_000_000, MirrorSize.Bitrate(160, 160));
        Assert.Equal(496 * 1072 * 8, MirrorSize.Bitrate(496, 1072));
        Assert.Equal(int.MaxValue, MirrorSize.Bitrate(100_000, 100_000));
    }
}
