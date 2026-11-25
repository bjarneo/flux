using FluxKit;

namespace FluxKit.Tests;

// FrameGeometryTests and ColorAdjustTests of StreamTests.swift of the Mac
// app: the place of the camera image in the frame, and the colors.
public class StreamGeometryTests
{
    const double Wide = 16.0 / 9.0;
    const double Tall = 9.0 / 16.0;

    static void AssertPoint((double X, double Y) expected, (double X, double Y) actual)
    {
        Assert.Equal(expected.X, actual.X, 4);
        Assert.Equal(expected.Y, actual.Y, 4);
    }

    [Fact]
    public void LandscapeContentWithoutRotationIsIdentity()
    {
        var m = FrameGeometry.Map(0, Wide, Wide, mirror: false);
        AssertPoint((0, 0), m.Apply(0, 0));
        AssertPoint((1, 1), m.Apply(1, 1));
    }

    [Fact]
    public void Rotation90MapsCornersClockwise()
    {
        // Portrait content rotated clockwise by 90 degrees becomes landscape,
        // so no crop is needed. The top left of the output comes from the
        // bottom left of the content.
        var m = FrameGeometry.Map(90, Tall, Wide, mirror: false);
        AssertPoint((0, 0), m.Apply(0, 1));
        AssertPoint((1, 1), m.Apply(1, 0));
        AssertPoint((0.5, 0.5), m.Apply(0.5, 0.5));
    }

    [Fact]
    public void Rotation180FlipsBothAxes()
    {
        var m = FrameGeometry.Map(180, Wide, Wide, mirror: false);
        AssertPoint((1, 1), m.Apply(0, 0));
        AssertPoint((0, 0), m.Apply(1, 1));
    }

    [Fact]
    public void Rotation270MapsCornersCounterClockwise()
    {
        var m = FrameGeometry.Map(270, Tall, Wide, mirror: false);
        AssertPoint((1, 1), m.Apply(0, 1));
        AssertPoint((0, 0), m.Apply(1, 0));
        // -90 degrees is the same turn.
        Assert.Equal(m, FrameGeometry.Map(-90, Tall, Wide, mirror: false));
    }

    [Fact]
    public void PortraitContentWithoutRotationIsCroppedToACenterBand()
    {
        // Upright portrait content in a 16:9 frame: the full width, and a
        // center band of the height.
        var m = FrameGeometry.Map(0, Tall, Wide, mirror: false);
        var band = Tall / Wide;
        AssertPoint((0, 0.5 - band / 2), m.Apply(0, 0));
        AssertPoint((1, 0.5 + band / 2), m.Apply(1, 1));
    }

    [Fact]
    public void MirrorFlipsTheOutputHorizontally()
    {
        var m = FrameGeometry.Map(0, Wide, Wide, mirror: true);
        AssertPoint((1, 0), m.Apply(0, 0));
        AssertPoint((0, 1), m.Apply(1, 1));
    }

    [Fact]
    public void SnapRoundsToQuarterTurns()
    {
        Assert.Equal(0, FrameGeometry.Snap(20));
        Assert.Equal(90, FrameGeometry.Snap(80));
        Assert.Equal(0, FrameGeometry.Snap(350));
        Assert.Equal(270, FrameGeometry.Snap(-80));
    }

    [Fact]
    public void TransformScalesTheCameraImageToTheFrame()
    {
        var t = FrameGeometry.Transform(0, 1920, 1080, 1280, 720, mirror: false, zoom: 1);
        AssertPoint((0, 0), t.Apply(0, 0));
        AssertPoint((1280, 720), t.Apply(1920, 1080));
    }

    [Fact]
    public void TransformCropsAPortraitCameraToACenterBand()
    {
        var t = FrameGeometry.Transform(0, 1080, 1920, 1280, 720, mirror: false, zoom: 1);
        var band = Tall / Wide;
        AssertPoint((0, 0), t.Apply(0, (0.5 - band / 2) * 1920));
        AssertPoint((1280, 720), t.Apply(1080, (0.5 + band / 2) * 1920));
    }

    [Fact]
    public void ZoomShowsTheCenterOfTheCamera()
    {
        var t = FrameGeometry.Transform(0, 1920, 1080, 1280, 720, mirror: true, zoom: 2);
        AssertPoint((640, 360), t.Apply(960, 540));
        // With the mirror, the left of the center half lands on the right edge.
        AssertPoint((1280, 0), t.Apply(480, 270));
        AssertPoint((0, 720), t.Apply(1440, 810));
    }

    [Fact]
    public void AffineMapsComposeAndInvert()
    {
        var a = Affine.Translation(2, 3).Then(Affine.Scale(4, 5));
        AssertPoint((12, 20), a.Apply(1, 1)); // (1 + 2) * 4, (1 + 3) * 5
        AssertPoint((1, 1), a.Inverted().Apply(12, 20));
        var flat = Affine.Scale(0, 1);
        Assert.Equal(flat, flat.Inverted()); // no inverse: the map stays
    }

    // The fragment shader of the Android app, step by step.
    static double[] Shader(double[] c, ColorAdjust a)
    {
        c = c.Select(v => v + a.Brightness * 0.5).ToArray();
        c = c.Select(v => (v - 0.5) * a.Contrast + 0.5).ToArray();
        var l = c.Zip(ColorAdjust.Luma).Sum(p => p.First * p.Second);
        c = c.Select(v => l + (v - l) * a.Saturation).ToArray();
        return [c[0] + 0.08 * a.Warmth, c[1], c[2] - 0.08 * a.Warmth];
    }

    static double[] Matrix(double[] c, ColorAdjust a)
    {
        var rows = a.Rows;
        var bias = a.Bias;
        return Enumerable.Range(0, 3).Select(i => rows[i].Zip(c).Sum(p => p.First * p.Second) + bias[i]).ToArray();
    }

    [Fact]
    public void NeutralValuesKeepTheImage()
    {
        var a = new ColorAdjust();
        Assert.True(a.IsNeutral);
        Assert.Equal([0.1, 0.5, 0.9], Matrix([0.1, 0.5, 0.9], a));
        Assert.False(new ColorAdjust(Warmth: 0.1).IsNeutral);
    }

    [Fact]
    public void MatrixMatchesTheAndroidShader()
    {
        ColorAdjust[] looks =
        [
            new(0.3, 1, 1, 0),
            new(0, 1.6, 1, 0),
            new(0, 1, 0, 0),
            new(-0.4, 0.7, 1.8, 0.9),
        ];
        double[][] colors = [[0.1, 0.5, 0.9], [0.8, 0.2, 0.3], [0.5, 0.5, 0.5]];
        foreach (var look in looks)
        {
            foreach (var color in colors)
            {
                var expected = Shader(color, look);
                var actual = Matrix(color, look);
                for (var i = 0; i < 3; i++)
                {
                    Assert.Equal(expected[i], actual[i], 12);
                }
            }
        }
    }

    [Fact]
    public void LookTakesTheImageSettings()
    {
        var look = WebcamLook.From(new WebcamConfig { Mirror = true, Zoom = 2, Exposure = 1, Brightness = 0.2, Contrast = 1.1, Saturation = 0.9, Warmth = -0.3 });
        Assert.Equal(new WebcamLook(true, 2, 1, new ColorAdjust(0.2, 1.1, 0.9, -0.3)), look);
        Assert.Equal(2, look.ExposureGain, 12); // 1 EV doubles the light
        Assert.True(new WebcamLook().Colors.IsNeutral);
    }
}
