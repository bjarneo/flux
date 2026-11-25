namespace FluxKit;

// The color adjustments of the webcam, with the formula of the Android GL
// shader on the encoded RGB values:
//
//     c += brightness * 0.5
//     c = (c - 0.5) * contrast + 0.5
//     c = mix(luma(c), c, saturation)   // Rec. 709 luma
//     c += (0.08, 0, -0.08) * warmth
//
// Each step is affine, so one 3x3 matrix and a bias do all of them at once.
// The neutral values 0, 1, 1, and 0 keep the image as it is. ColorAdjust.swift
// of the Mac app has the same math.
public sealed record ColorAdjust(double Brightness = 0, double Contrast = 1, double Saturation = 1, double Warmth = 0)
{
    public static readonly IReadOnlyList<double> Luma = [0.2126, 0.7152, 0.0722];

    public bool IsNeutral => this == new ColorAdjust();

    // The rows of the matrix: output channel i is Rows[i] · rgb + Bias[i].
    public double[][] Rows
    {
        get
        {
            // The luma weights add up to 1, so the saturation step keeps gray
            // and the offsets of the first 2 steps pass through it unchanged.
            var rows = new double[3][];
            for (var i = 0; i < 3; i++)
            {
                rows[i] = new double[3];
                for (var j = 0; j < 3; j++)
                {
                    rows[i][j] = Contrast * ((i == j ? Saturation : 0) + (1 - Saturation) * Luma[j]);
                }
            }
            return rows;
        }
    }

    public double[] Bias
    {
        get
        {
            var gray = Contrast * (Brightness * 0.5 - 0.5) + 0.5;
            return [gray + 0.08 * Warmth, gray, gray - 0.08 * Warmth];
        }
    }
}

// How a webcam frame looks: the input of the renderer of the app.
public sealed record WebcamLook(bool Mirror = false, double Zoom = 1, double Exposure = 0, ColorAdjust? Color = null)
{
    // The color adjustments. Null means the neutral values.
    public ColorAdjust Colors => Color ?? new ColorAdjust();

    // Exposure compensation in EV. The exposure is digital, as on the Mac,
    // because cameras on Windows differ in their controls. The renderer
    // converts the encoded values to linear light, multiplies them by this
    // gain, and converts them back, before the color adjustments.
    public double ExposureGain => Math.Pow(2, Exposure);

    public static WebcamLook From(WebcamConfig c) =>
        new(c.Mirror, c.Zoom, c.Exposure, new ColorAdjust(c.Brightness, c.Contrast, c.Saturation, c.Warmth));
}
