import CoreImage
import CoreVideo

/// Draws camera frames into encoder frames with Core Image on the GPU: the
/// geometry of FrameGeometry, a digital exposure, and the colors of
/// ColorAdjust. Color management is off, so the color adjustments act on the
/// encoded values, as in the Android shader, and the preview shows what the
/// computer gets.
final class FrameRenderer {
    /// How a frame looks.
    struct Look: Equatable {
        var mirror = false
        var zoom = 1.0
        /// Exposure compensation in EV. macOS gives apps no exposure control
        /// of the camera, so the renderer scales the light: 2^EV in linear
        /// light.
        var exposure = 0.0
        var color = ColorAdjust()
    }

    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
        .name: "org.omarchy.flux.webcam",
    ])
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// Returns the frame for an output of width x height pixels.
    func image(_ source: CVPixelBuffer, width: Int, height: Int, rotation: Int, look: Look) -> CIImage {
        let input = CIImage(cvPixelBuffer: source)
        let output = CGRect(x: 0, y: 0, width: width, height: height)
        let place = FrameGeometry.transform(rotation: rotation, source: input.extent.size, output: output.size, mirror: look.mirror, zoom: look.zoom)
        var image = input.clampedToExtent().transformed(by: place).cropped(to: output)
        if look.exposure != 0 {
            image = image.applyingFilter("CISRGBToneCurveToLinear")
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: look.exposure])
                .applyingFilter("CILinearToSRGBToneCurve")
        }
        if !look.color.isNeutral {
            let rows = look.color.rows
            let bias = look.color.bias
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: rows[0][0], y: rows[0][1], z: rows[0][2], w: 0),
                "inputGVector": CIVector(x: rows[1][0], y: rows[1][1], z: rows[1][2], w: 0),
                "inputBVector": CIVector(x: rows[2][0], y: rows[2][1], z: rows[2][2], w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias[0], y: bias[1], z: bias[2], w: 0),
            ])
        }
        return image.applyingFilter("CIColorClamp").cropped(to: output)
    }

    /// Renders image into a new frame of width x height pixels for the encoder.
    func render(_ image: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolWidth != width || poolHeight != height {
            pool = Self.makePool(width: width, height: height)
            poolWidth = width
            poolHeight = height
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return buffer
    }

    /// Returns a small copy of image, maxWidth pixels wide at most, for the
    /// preview on this Mac.
    func preview(_ image: CIImage, maxWidth: Double) -> CGImage? {
        let scale = min(1, maxWidth / image.extent.width)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(small, from: small.extent.integral, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        // The frames are sRGB, which has the primaries of BT.709. The tags
        // match the encoder, so it only converts RGB to YUV.
        let attachments: [CFString: Any] = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVBufferPropagatedAttachmentsKey: attachments,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return pool
    }
}
