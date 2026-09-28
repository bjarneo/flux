import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image helpers of the camera modes: upright decoding, pixels, PNG, JPEG,
/// perspective correction, and PDF pages.
public enum CameraImages {
    /// The largest side of a still image that Flux reads. It keeps memory use low.
    public static let maxStillSide = 2048

    /// Decodes an image file upright, with its largest side at most `maxSide` pixels.
    public static func load(_ url: URL, maxSide: Int = maxStillSide) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw FluxError("Cannot open \(url.lastPathComponent)") }
        return try upright(source, maxSide: maxSide)
    }

    /// Decodes image data, such as a captured photo, upright, with its
    /// largest side at most `maxSide` pixels.
    public static func decode(_ data: Data, maxSide: Int = maxStillSide) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw FluxError("Cannot read the image") }
        return try upright(source, maxSide: maxSide)
    }

    /// Returns a picked photo as JPEG data for Photo mode, which sends JPEG
    /// files. A JPEG keeps its bytes and its metadata. Another format, such
    /// as HEIC or PNG, becomes an upright JPEG of the full size.
    public static func jpegFile(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) else {
            throw FluxError("Cannot read the image")
        }
        if UTType(type as String)?.conforms(to: .jpeg) == true { return data }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { throw FluxError("Cannot read the image") }
        guard let jpeg = jpeg(try upright(source, maxSide: max(width, height)), quality: 0.92) else {
            throw FluxError("Cannot save the photo as JPEG")
        }
        return jpeg
    }

    private static func upright(_ source: CGImageSource, maxSide: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw FluxError("Cannot read the image") }
        return image
    }

    /// Returns a part of the image scaled so that its largest side is at most `maxSide`.
    public static func crop(_ image: CGImage, to crop: SignatureCrop?, maxSide: Int) -> CGImage? {
        let part = crop.flatMap { image.cropping(to: CGRect(x: $0.left, y: $0.top, width: $0.width, height: $0.height)) } ?? image
        let side = max(part.width, part.height)
        guard side > maxSide else { return part }
        let s = Double(maxSide) / Double(side)
        return scaled(part, width: max(1, Int(Double(part.width) * s)), height: max(1, Int(Double(part.height) * s)))
    }

    static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = rgbaContext(width: width, height: height) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Returns the pixels as 0xAARRGGBB, row by row from the top.
    public static func argb(_ image: CGImage) -> [UInt32]? {
        let w = image.width, h = image.height
        // Little-endian 32-bit words with alpha first read as 0xAARRGGBB.
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        var px = [UInt32](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
            // Transparent parts count as white paper.
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }

    /// Returns the signature as a PNG in the color, on a transparent background.
    public static func png(_ ink: SignatureInk, rgb: Int) -> Data? {
        guard let image = image(ink, rgb: rgb) else { return nil }
        return encode(image, type: .png, properties: [:])
    }

    /// Returns the signature as an image with straight (not premultiplied) alpha.
    public static func image(_ ink: SignatureInk, rgb: Int) -> CGImage? {
        let r = UInt8(rgb >> 16 & 0xFF), g = UInt8(rgb >> 8 & 0xFF), b = UInt8(rgb & 0xFF)
        var bytes = [UInt8](repeating: 0, count: ink.width * ink.height * 4)
        for i in 0..<ink.alpha.count {
            bytes[i * 4] = r
            bytes[i * 4 + 1] = g
            bytes[i * 4 + 2] = b
            bytes[i * 4 + 3] = ink.alpha[i]
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: ink.width, height: ink.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ink.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Encodes an image as JPEG.
    public static func jpeg(_ image: CGImage, quality: Double = 0.9) -> Data? {
        encode(image, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: Documents

    /// Flattens the page inside `quad` into a rectangle. The corners are in
    /// normalized image coordinates with the origin at the top left corner.
    public static func flatten(_ image: CGImage, quad: DocumentQuad) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Core Image has its origin at the bottom left corner.
        func vector(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: (1 - p.y) * h) }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(vector(quad.topLeft), forKey: "inputTopLeft")
        filter.setValue(vector(quad.topRight), forKey: "inputTopRight")
        filter.setValue(vector(quad.bottomRight), forKey: "inputBottomRight")
        filter.setValue(vector(quad.bottomLeft), forKey: "inputBottomLeft")
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent.integral)
    }

    /// Returns a PDF with 1 page for each image. Each page has the aspect of
    /// its image, with the long side as long as A4 (842 points), and holds the
    /// image as a JPEG.
    public static func pdf(_ pages: [CGImage]) -> Data? {
        let data = NSMutableData()
        guard !pages.isEmpty, let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, [kCGPDFContextCreator: "Flux"] as CFDictionary)
        else { return nil }
        for page in pages {
            // A JPEG image keeps its compressed data in the PDF.
            guard let jpeg = jpeg(page, quality: 0.85), let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let s = 842 / CGFloat(max(image.width, image.height))
            var box = CGRect(x: 0, y: 0, width: (CGFloat(image.width) * s).rounded(), height: (CGFloat(image.height) * s).rounded())
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
        return data as Data
    }

    static func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static let context = CIContext()
}
