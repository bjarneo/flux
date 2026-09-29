import Foundation

/// The mapping from an output frame to the camera image. Port of Android
/// `webcam/FrameGeometry.kt` (`FrameGeometry`).
///
/// The output is always 16:9 and upright for the viewer. The camera image
/// is rotated clockwise by a multiple of 90 degrees, cropped in the center
/// to the output shape, and mirrored for the phone preview of the front
/// camera.
///
/// Coordinates run from 0 to 1, with y up, as in OpenGL texture space.
public enum FrameGeometry {
    /// Returns a column-major 4x4 matrix mapping an output coordinate to a
    /// coordinate in the camera image, before the SurfaceTexture transform.
    ///
    /// `rotation` is the clockwise rotation in degrees making the camera
    /// image upright. `contentAspect` is width/height of the camera image;
    /// `outputAspect` the same for the output frame.
    public static func matrix(rotation: Int, contentAspect: Float, outputAspect: Float, mirror: Bool) -> [Float] {
        let r = ((rotation % 360) + 360) % 360
        let rotatedAspect: Float = (r == 90 || r == 270) ? 1 / contentAspect : contentAspect
        var sx: Float = 1
        var sy: Float = 1
        if rotatedAspect > outputAspect {
            sx = outputAspect / rotatedAspect
        } else {
            sy = rotatedAspect / outputAspect
        }
        // Step 1, the preview mirror: x -> 1 - x.
        var a = Affine(mirror ? -1 : 1, 0, 0, 1, mirror ? 1 : 0, 0)
        // Step 2, the center crop in the rotated image.
        a = Affine(sx, 0, 0, sy, 0.5 - 0.5 * sx, 0.5 - 0.5 * sy).after(a)
        // Step 3, from the rotated image back to the camera image.
        let back: Affine =
            switch r {
            case 90: Affine(0, 1, -1, 0, 1, 0)
            case 180: Affine(-1, 0, 0, -1, 1, 1)
            case 270: Affine(0, -1, 1, 0, 0, 1)
            default: Affine(1, 0, 0, 1, 0, 0)
            }
        return back.after(a).toMatrix()
    }

    /// Applies a matrix from `matrix` to a point. Tests use it.
    public static func apply(_ m: [Float], x: Float, y: Float) -> (Float, Float) {
        (m[0] * x + m[4] * y + m[12], m[1] * x + m[5] * y + m[13])
    }

    /// Reports whether a SurfaceTexture transform swaps the axes. The camera
    /// framework rotates preview outputs to the natural orientation of the
    /// device, and that rotation swaps the axes of the sensor image.
    public static func swapsAxes(_ transform: [Float]) -> Bool {
        abs(transform[0]) < 0.5 && abs(transform[5]) < 0.5
    }

    /// Returns the clockwise rotation making the camera image upright, from
    /// the device orientation in degrees (0 in the natural orientation, 90
    /// when the left side of the device is at the top).
    ///
    /// When the framework already rotated the image to the natural
    /// orientation (`naturalContent`), only the device orientation counts.
    /// Otherwise the sensor orientation counts too.
    public static func uprightRotation(deviceOrientation: Int, sensorOrientation: Int, front: Bool, naturalContent: Bool) -> Int {
        let d = snap(deviceOrientation)
        let signed = front ? -d : d
        let base = naturalContent ? 0 : sensorOrientation
        return ((base + signed) % 360 + 360) % 360
    }

    /// Rounds an orientation to the nearest multiple of 90 degrees.
    public static func snap(_ degrees: Int) -> Int {
        ((((degrees % 360) + 360) % 360 + 45) / 90 * 90) % 360
    }

    /// A 2D affine map: x' = a*x + c*y + tx, y' = b*x + d*y + ty.
    private struct Affine {
        var a, b, c, d, tx, ty: Float

        init(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ tx: Float, _ ty: Float) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.tx = tx
            self.ty = ty
        }

        /// Returns this map applied after `first`.
        func after(_ first: Affine) -> Affine {
            Affine(
                a * first.a + c * first.b,
                b * first.a + d * first.b,
                a * first.c + c * first.d,
                b * first.c + d * first.d,
                a * first.tx + c * first.ty + tx,
                b * first.tx + d * first.ty + ty
            )
        }

        func toMatrix() -> [Float] {
            [a, b, 0, 0, c, d, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1]
        }
    }
}
