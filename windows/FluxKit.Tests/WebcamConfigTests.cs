using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// WebcamConfigTests of StreamTests.swift of the Mac app: the frame sizes,
// the bitrate, and the merge and the clamp of the settings.
public class WebcamConfigTests
{
    static JsonObject Obj(string json) => (JsonObject)JsonNode.Parse(json)!;

    static readonly WebcamCaps TestCaps = new()
    {
        ZoomMax = 8,
        ExposureMin = -2,
        ExposureMax = 2,
        ExposureStep = 1.0 / 3.0,
        WhiteBalance = new(["auto", "daylight", "cloudy"]),
        Cameras = new(["back", "front"]),
    };

    [Theory]
    [InlineData("16:9", 720, 1280, 720)]
    [InlineData("16:9", 1080, 1920, 1080)]
    [InlineData("4:3", 720, 960, 720)]
    [InlineData("4:3", 1080, 1440, 1080)]
    [InlineData("1:1", 720, 720, 720)]
    [InlineData("1:1", 1080, 1080, 1080)]
    [InlineData("9:16", 720, 720, 1280)]
    [InlineData("9:16", 1080, 1080, 1920)]
    [InlineData("wide", 720, 1280, 720)]
    [InlineData("0:9", 720, 1280, 720)]
    public void FrameSizePerAspect(string aspect, int @short, int width, int height)
    {
        Assert.Equal((width, height), WebcamConfig.FrameSize(aspect, @short));
    }

    [Fact]
    public void ConfigSizeFollowsAspectAndResolution()
    {
        var c = new WebcamConfig { Aspect = "9:16", Resolution = 1080 };
        Assert.Equal(1080, c.Width);
        Assert.Equal(1920, c.Height);
    }

    [Fact]
    public void BitrateScalesWithPixels()
    {
        Assert.Equal(4_000_000, WebcamConfig.BitrateFor(1280, 720));
        Assert.Equal(8_000_000, WebcamConfig.BitrateFor(1920, 1080));
        Assert.Equal(2_250_000, WebcamConfig.BitrateFor(720, 720));
        Assert.Equal(8_000_000, WebcamConfig.BitrateFor(1080, 1920));
        Assert.Equal(1_000_000, WebcamConfig.BitrateFor(16, 16));
        Assert.Equal(int.MaxValue, WebcamConfig.BitrateFor(1_000_000, 100_000));
        Assert.Equal(4_000_000, new WebcamConfig().Bitrate);
    }

    [Fact]
    public void PartialChangesOnlyItsFields()
    {
        var c = new WebcamConfig().Merged(Obj("""{"brightness": 0.3, "aspect": "1:1"}"""));
        Assert.Equal(new WebcamConfig { Brightness = 0.3, Aspect = "1:1" }, c);
        Assert.Same(c, c.Merged(null));
    }

    [Fact]
    public void PartialAcceptsNumbersAsTextAndIgnoresWrongTypes()
    {
        var c = new WebcamConfig().Merged(Obj("""{"zoom": "2.5", "resolution": 1080.0, "mirror": "true", "camera": "FRONT", "contrast": "x", "saturation": true, "warmth": "NaN"}"""));
        Assert.Equal(2.5, c.Zoom);
        Assert.Equal(1080, c.Resolution);
        Assert.True(c.Mirror);
        Assert.Equal("front", c.Camera);
        Assert.Equal(1, c.Contrast);
        Assert.Equal(1, c.Saturation);
        Assert.Equal(0, c.Warmth);
        // Spaces around a text go, and an empty text changes nothing.
        var t = new WebcamConfig().Merged(Obj("""{"aspect": " 4:3 ", "whiteBalance": " Daylight", "camera": "  ", "mirror": " FALSE "}"""));
        Assert.Equal("4:3", t.Aspect);
        Assert.Equal("daylight", t.WhiteBalance);
        Assert.Equal("back", t.Camera);
        Assert.False(t.Mirror);
    }

    [Fact]
    public void ClampKeepsValuesInsideTheCaps()
    {
        var c = new WebcamConfig
        {
            Aspect = "21:9",
            Resolution = 2160,
            Camera = "side",
            Zoom = 50,
            Exposure = 5,
            WhiteBalance = "shade",
            Brightness = 3,
            Contrast = -1,
            Saturation = 9,
            Warmth = -4,
        }.Clamped(TestCaps);
        Assert.Equal("16:9", c.Aspect);
        Assert.Equal(1080, c.Resolution);
        Assert.Equal("back", c.Camera);
        Assert.Equal(8, c.Zoom);
        Assert.Equal(2, c.Exposure, 3);
        Assert.Equal("auto", c.WhiteBalance);
        Assert.Equal(1, c.Brightness);
        Assert.Equal(0, c.Contrast);
        Assert.Equal(2, c.Saturation);
        Assert.Equal(-1, c.Warmth);
    }

    [Fact]
    public void ClampRoundsExposureToTheStepAndZoomUpToOne()
    {
        var c = new WebcamConfig { Exposure = 0.4, Zoom = 0.5 }.Clamped(TestCaps);
        Assert.Equal(0.333, c.Exposure, 9);
        Assert.Equal(1, c.Zoom);
        // Clamping again changes nothing.
        Assert.Equal(c, c.Clamped(TestCaps));
    }

    // A number that does not fit an int stops nothing. The resolution stays
    // as it was.
    [Theory]
    [InlineData("1e300")]
    [InlineData("-1e300")]
    [InlineData("1e21")]
    [InlineData("9223372036854775807")]
    [InlineData("-9223372036854775808")]
    [InlineData("\"1e300\"")]
    [InlineData("\"-9.2233720368547748e18\"")]
    [InlineData("0")]
    [InlineData("-5")]
    public void HugeResolutionDoesNotStopTheApp(string value)
    {
        var c = new WebcamConfig().Merged(Obj($$"""{"resolution": {{value}}}"""));
        Assert.Equal(720, c.Resolution);
        Assert.Equal(720, c.Clamped(TestCaps).Resolution);
    }

    [Fact]
    public void ExtremeResolutionsClampToTheCaps()
    {
        Assert.Equal(720, new WebcamConfig { Resolution = int.MinValue }.Clamped(TestCaps).Resolution);
        Assert.Equal(1080, new WebcamConfig { Resolution = int.MaxValue }.Clamped(TestCaps).Resolution);
        // A resolution between 2 caps takes the nearer one, and a tie the first.
        Assert.Equal(720, new WebcamConfig { Resolution = 900 }.Clamped(TestCaps).Resolution);
        Assert.Equal(1080, new WebcamConfig { Resolution = 901 }.Clamped(TestCaps).Resolution);
    }

    [Fact]
    public void RoundingSaturates()
    {
        Assert.Equal(long.MaxValue, Rounding.HalfUp(1e300));
        Assert.Equal(long.MinValue, Rounding.HalfUp(-1e300));
        Assert.Equal(0, Rounding.HalfUp(double.NaN));
        Assert.Equal(3, Rounding.HalfUp(2.5));
        Assert.Equal(-2, Rounding.HalfUp(-2.5));
        var size = WebcamConfig.FrameSize("9223372036854775807:1", 720);
        Assert.Equal(720, size.Height);
        Assert.Equal(0, size.Width % 2);
    }

    [Fact]
    public void ClampWithoutExposureSetsZero()
    {
        Assert.Equal(0, new WebcamConfig { Exposure = 1.5 }.Clamped(new WebcamCaps()).Exposure);
    }

    [Fact]
    public void CapsOfThisComputerKeepCamerasAndLimitDigitalControls()
    {
        var cameras = CameraNames.Name([
            new CameraDevice("usb#1", "Integrated Camera", true),
            new CameraDevice("usb#2", "Logitech BRIO", false),
        ]);
        var caps = WebcamPlugin.Caps(cameras);
        var saved = new WebcamConfig { Camera = "logitech brio", Zoom = 9, Exposure = -3, WhiteBalance = "daylight" }.Clamped(caps);
        Assert.Equal("logitech brio", saved.Camera);
        Assert.Equal(WebcamPlugin.ZoomMax, saved.Zoom);
        Assert.Equal(-WebcamPlugin.ExposureLimit, saved.Exposure);
        Assert.Equal("auto", saved.WhiteBalance);
        // A camera that is gone falls back to the first one.
        Assert.Equal("integrated camera", new WebcamConfig { Camera = "back" }.Clamped(caps).Camera);
    }

    [Fact]
    public void CamerasGetUniqueNamesBuiltInFirst()
    {
        var cameras = CameraNames.Name([
            new CameraDevice("usb#a", " USB Camera ", false),
            new CameraDevice("usb#b", "Integrated Camera", true),
            new CameraDevice("usb#c", "usb camera", false),
        ]);
        Assert.Equal(["integrated camera", "usb camera", "usb camera 2"], cameras.Select(c => c.Id));
        Assert.Equal(["Integrated Camera", "USB Camera", "usb camera 2"], cameras.Select(c => c.Name));
        Assert.Equal(["usb#b", "usb#a", "usb#c"], cameras.Select(c => c.Device.DeviceId));
    }

    [Fact]
    public void ResetKeepsShapeQualityAndCamera()
    {
        var c = new WebcamConfig
        {
            Aspect = "4:3",
            Resolution = 1080,
            Camera = "front",
            Mirror = true,
            Zoom = 3,
            Exposure = 1,
            WhiteBalance = "cloudy",
            Brightness = 0.5,
            Contrast = 1.5,
            Saturation = 0.2,
            Warmth = 0.7,
        }.Reset();
        Assert.Equal(new WebcamConfig { Aspect = "4:3", Resolution = 1080, Camera = "front" }, c);
    }

    [Fact]
    public void OnlyANewFrameSizeRestartsTheStream()
    {
        var c = new WebcamConfig();
        Assert.True(c.RestartsStream(new WebcamConfig { Aspect = "4:3" }));
        Assert.True(c.RestartsStream(new WebcamConfig { Resolution = 1080 }));
        Assert.False(c.RestartsStream(new WebcamConfig { Camera = "front" }));
        Assert.False(c.RestartsStream(new WebcamConfig { Brightness = 0.4, Zoom = 2 }));
    }

    [Fact]
    public void JsonRoundTrip()
    {
        var c = new WebcamConfig
        {
            Aspect = "9:16",
            Resolution = 1080,
            Camera = "front",
            Mirror = true,
            Zoom = 2,
            WhiteBalance = "daylight",
            Warmth = -0.25,
        };
        var text = c.Json().ToJsonString();
        Assert.Equal(c, new WebcamConfig().Merged(Obj(text)));
    }

    [Fact]
    public void SettingsSaveEachChangeAndClampIt()
    {
        var dir = CoreTests.TempDir();
        try
        {
            var path = Path.Combine(dir, "settings.json");
            var settings = new WebcamSettings(new FluxSettings(path), TestCaps);
            Assert.Equal(new WebcamConfig(), settings.Config);
            Assert.Null(settings.Update(c => c)); // no change
            var next = settings.Update(c => c with { Brightness = 3, Camera = "front" });
            Assert.Equal(1, next?.Brightness);
            Assert.Equal("front", next?.Camera);
            // The computer resets the image and sets 1 field.
            Assert.Equal(new WebcamConfig { Camera = "front", Warmth = 0.5 },
                settings.ApplyRemote(reset: true, Obj("""{"warmth": 0.5}""")));
            // A new start reads the saved settings.
            var again = new WebcamSettings(new FluxSettings(path), TestCaps);
            Assert.Equal(settings.Config, again.Config);
            // Caps without the front camera move to the first camera.
            Assert.Equal("back", again.SetCaps(new WebcamCaps())?.Camera);
            Assert.Equal(new WebcamCaps(), again.Caps);
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }
}
