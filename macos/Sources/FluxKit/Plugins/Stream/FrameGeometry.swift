import CoreGraphics

/// The mapping from an output frame to the camera image, as in the Android
/// app. The camera image is rotated clockwise by a multiple of 90 degrees,
/// cropped in the center to the output shape, and mirrored when the user
/// asks. This Mac zooms digitally with a smaller center crop.
///
/// Normalized coordinates run from 0 to 1 with y up, as in Core Image.
enum FrameGeometry {
    /// Returns the map from a normalized output coordinate to a normalized
    /// coordinate in the camera image.
    ///
    /// rotation is the clockwise rotation in degrees that makes the camera
    /// image upright. contentAspect is the width divided by the height of the
    /// camera image. outputAspect is the same for the output frame.
    static func map(rotation: Int, contentAspect: Double, outputAspect: Double, mirror: Bool) -> CGAffineTransform {
        let r = ((rotation % 360) + 360) % 360
        // The shape of the camera image after the rotation.
        let rotatedAspect = r == 90 || r == 270 ? 1 / contentAspect : contentAspect
        var sx = 1.0
        var sy = 1.0
        if rotatedAspect > outputAspect { sx = outputAspect / rotatedAspect } else { sy = rotatedAspect / outputAspect }

        // Step 1, the mirror: x -> 1 - x.
        let flip = CGAffineTransform(a: mirror ? -1 : 1, b: 0, c: 0, d: 1, tx: mirror ? 1 : 0, ty: 0)
        // Step 2, the center crop in the rotated image.
        let crop = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: 0.5 - 0.5 * sx, ty: 0.5 - 0.5 * sy)
        // Step 3, from the rotated image back to the camera image.
        let back: CGAffineTransform
        switch r {
        case 90: back = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0) // s = (1 - y, x)
        case 180: back = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1) // s = (1 - x, 1 - y)
        case 270: back = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1) // s = (y, 1 - x)
        default: back = .identity
        }
        return flip.concatenating(crop).concatenating(back)
    }

    /// Returns the transform that draws a camera image of source pixels into
    /// an output frame of output pixels. zoom 2 shows the center half of the
    /// camera image on each axis.
    static func transform(rotation: Int, source: CGSize, output: CGSize, mirror: Bool, zoom: Double) -> CGAffineTransform {
        let toCamera = map(rotation: rotation, contentAspect: source.width / source.height, outputAspect: output.width / output.height, mirror: mirror)
        let z = max(1, zoom)
        let magnify = CGAffineTransform(translationX: -0.5, y: -0.5)
            .concatenating(CGAffineTransform(scaleX: 1 / z, y: 1 / z))
            .concatenating(CGAffineTransform(translationX: 0.5, y: 0.5))
        return CGAffineTransform(scaleX: 1 / source.width, y: 1 / source.height)
            .concatenating(toCamera.concatenating(magnify).inverted())
            .concatenating(CGAffineTransform(scaleX: output.width, y: output.height))
    }

    /// Rounds an orientation to the nearest multiple of 90 degrees.
    static func snap(_ degrees: Int) -> Int { ((((degrees % 360) + 360) % 360 + 45) / 90 * 90) % 360 }
}
