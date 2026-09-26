/// The color adjustments of the webcam, with the formula of the Android GL
/// shader on the encoded RGB values:
///
///     c += brightness * 0.5
///     c = (c - 0.5) * contrast + 0.5
///     c = mix(luma(c), c, saturation)   // Rec. 709 luma
///     c += (0.08, 0, -0.08) * warmth
///
/// Each step is affine, so one 3x3 matrix and a bias do all of them at once.
/// The neutral values (0, 1, 1, 0) leave the image as it is.
struct ColorAdjust: Equatable {
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var warmth = 0.0

    static let luma = [0.2126, 0.7152, 0.0722]

    var isNeutral: Bool { self == ColorAdjust() }

    /// The rows of the matrix: output channel i is rows[i] · rgb + bias[i].
    var rows: [[Double]] {
        // The luma weights add up to 1, so the saturation step keeps gray and
        // the offsets of the first 2 steps pass through it unchanged.
        (0..<3).map { i in
            (0..<3).map { j in contrast * ((i == j ? saturation : 0) + (1 - saturation) * Self.luma[j]) }
        }
    }

    var bias: [Double] {
        let gray = contrast * (brightness * 0.5 - 0.5) + 0.5
        return [gray + 0.08 * warmth, gray, gray - 0.08 * warmth]
    }
}
