namespace FluxKit;

// An affine map of the plane, with the fields and the order of
// CGAffineTransform: x' = A x + C y + Tx and y' = B x + D y + Ty.
public readonly record struct Affine(double A, double B, double C, double D, double Tx, double Ty)
{
    public static readonly Affine Identity = new(1, 0, 0, 1, 0, 0);

    public static Affine Translation(double x, double y) => new(1, 0, 0, 1, x, y);

    public static Affine Scale(double x, double y) => new(x, 0, 0, y, 0, 0);

    public (double X, double Y) Apply(double x, double y) => (A * x + C * y + Tx, B * x + D * y + Ty);

    // The map that applies this map first and next after it, as concatenating
    // of CGAffineTransform.
    public Affine Then(Affine next) => new(
        A * next.A + B * next.C,
        A * next.B + B * next.D,
        C * next.A + D * next.C,
        C * next.B + D * next.D,
        Tx * next.A + Ty * next.C + next.Tx,
        Tx * next.B + Ty * next.D + next.Ty);

    // The inverse map. A map without an inverse stays as it is, as in
    // CGAffineTransform.
    public Affine Inverted()
    {
        var det = A * D - B * C;
        if (det == 0)
        {
            return this;
        }
        return new Affine(D / det, -B / det, -C / det, A / det, (C * Ty - D * Tx) / det, (B * Tx - A * Ty) / det);
    }
}

// The mapping from an output frame to the camera image, as in the Android
// app. The camera image is rotated clockwise by a multiple of 90 degrees,
// cropped in the center to the output shape, and mirrored when the user
// asks. This computer zooms digitally with a smaller center crop. The
// renderer of the app uses it. FrameGeometry.swift of the Mac app has the
// same math.
//
// Normalized coordinates run from 0 to 1 with y up, as in Core Image. A
// renderer with y down, such as Direct3D, flips y before and after the map.
public static class FrameGeometry
{
    // Returns the map from a normalized output coordinate to a normalized
    // coordinate in the camera image.
    //
    // rotation is the clockwise rotation in degrees that makes the camera
    // image upright. contentAspect is the width divided by the height of the
    // camera image. outputAspect is the same for the output frame.
    public static Affine Map(int rotation, double contentAspect, double outputAspect, bool mirror)
    {
        var r = ((rotation % 360) + 360) % 360;
        // The shape of the camera image after the rotation.
        var rotatedAspect = r is 90 or 270 ? 1 / contentAspect : contentAspect;
        var sx = 1.0;
        var sy = 1.0;
        if (rotatedAspect > outputAspect)
        {
            sx = outputAspect / rotatedAspect;
        }
        else
        {
            sy = rotatedAspect / outputAspect;
        }
        // Step 1, the mirror: x -> 1 - x.
        var flip = new Affine(mirror ? -1 : 1, 0, 0, 1, mirror ? 1 : 0, 0);
        // Step 2, the center crop in the rotated image.
        var crop = new Affine(sx, 0, 0, sy, 0.5 - 0.5 * sx, 0.5 - 0.5 * sy);
        // Step 3, from the rotated image back to the camera image.
        var back = r switch
        {
            90 => new Affine(0, 1, -1, 0, 1, 0), // s = (1 - y, x)
            180 => new Affine(-1, 0, 0, -1, 1, 1), // s = (1 - x, 1 - y)
            270 => new Affine(0, -1, 1, 0, 0, 1), // s = (y, 1 - x)
            _ => Affine.Identity,
        };
        return flip.Then(crop).Then(back);
    }

    // Returns the map that draws a camera image of source pixels into an
    // output frame of output pixels. zoom 2 shows the center half of the
    // camera image on each axis.
    public static Affine Transform(int rotation, double sourceWidth, double sourceHeight, double outputWidth, double outputHeight, bool mirror, double zoom)
    {
        var toCamera = Map(rotation, sourceWidth / sourceHeight, outputWidth / outputHeight, mirror);
        var z = Math.Max(1, zoom);
        var magnify = Affine.Translation(-0.5, -0.5).Then(Affine.Scale(1 / z, 1 / z)).Then(Affine.Translation(0.5, 0.5));
        return Affine.Scale(1 / sourceWidth, 1 / sourceHeight)
            .Then(toCamera.Then(magnify).Inverted())
            .Then(Affine.Scale(outputWidth, outputHeight));
    }

    // Rounds an orientation to the nearest multiple of 90 degrees.
    public static int Snap(int degrees) => ((((degrees % 360) + 360) % 360 + 45) / 90 * 90) % 360;
}
