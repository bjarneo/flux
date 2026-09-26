import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// The 4 corners of a page in an image, in normalized coordinates with the
/// origin at the top left corner.
public struct DocumentQuad: Equatable, Sendable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }
}

/// What the live camera sees: outlines to draw over the preview, and the
/// codes with a value. Outlines are in normalized coordinates of the frame
/// with the origin at the top left corner.
public struct LiveScan: Sendable {
    public var outlines: [[CGPoint]] = []
    public var codes: [ScannedCode] = []
    /// The size of the frame in pixels.
    public var frameSize: CGSize = .zero
}

/// Reads codes, text, and pages with Vision. Each call runs Vision at once,
/// so callers run it off the main thread.
public enum VisionScan {
    /// What a live camera frame looks for.
    public enum Target: Sendable {
        case codes, text, document
    }

    /// Returns the codes with a value in an upright image.
    public static func codes(in image: CGImage) throws -> [ScannedCode] {
        try codes(VNImageRequestHandler(cgImage: image)).codes
    }

    /// Returns the text blocks of an upright image, in pixels.
    public static func text(in image: CGImage) throws -> [ScanBlock] {
        let lines = try textLines(VNImageRequestHandler(cgImage: image), fast: false)
        return TextAssembly.blocks(from: lines.map { line($0.0, $0.1, image.width, image.height) })
    }

    /// Returns the page in an upright image, or nil when there is none.
    public static func document(in image: CGImage) throws -> DocumentQuad? {
        try document(VNImageRequestHandler(cgImage: image))
    }

    /// Looks at 1 live camera frame.
    public static func live(_ target: Target, frame: CVPixelBuffer) throws -> LiveScan {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame)
        var scan = LiveScan(frameSize: CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame)))
        switch target {
        case .codes:
            let found = try codes(handler)
            scan.outlines = found.outlines
            scan.codes = found.codes
        case .text:
            scan.outlines = try textLines(handler, fast: true).map { corners($0.1) }
        case .document:
            scan.outlines = try document(handler).map { [$0.points] } ?? []
        }
        return scan
    }

    // MARK: Requests

    private static func codes(_ handler: VNImageRequestHandler) throws -> (codes: [ScannedCode], outlines: [[CGPoint]]) {
        let request = VNDetectBarcodesRequest()
        try handler.perform([request])
        let results = request.results ?? []
        let codes = results.compactMap { o -> ScannedCode? in
            guard let raw = o.payloadStringValue, !raw.isEmpty else { return nil }
            return code(o.symbology, raw)
        }
        let outlines = results.map { [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft].map(flip) }
        return (codes, outlines)
    }

    private static func textLines(_ handler: VNImageRequestHandler, fast: Bool) throws -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = !fast
        request.automaticallyDetectsLanguage = !fast
        try handler.perform([request])
        return (request.results ?? []).compactMap { o in
            guard let text = o.topCandidates(1).first?.string else { return nil }
            return (text, o.boundingBox)
        }
    }

    private static func document(_ handler: VNImageRequestHandler) throws -> DocumentQuad? {
        let segmentation = VNDetectDocumentSegmentationRequest()
        try handler.perform([segmentation])
        if let o = segmentation.results?.first, o.confidence >= 0.5 { return quad(o) }
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.3
        rectangles.minimumSize = 0.2
        rectangles.minimumConfidence = 0.6
        rectangles.maximumObservations = 1
        try handler.perform([rectangles])
        return rectangles.results?.first.map(quad)
    }

    // MARK: Conversions

    /// Converts a Vision barcode to the model that `Codes` classifies.
    static func code(_ symbology: VNBarcodeSymbology, _ raw: String) -> ScannedCode {
        var format = format(symbology)
        var value = raw
        // Vision reads UPC-A as EAN-13 with a leading 0, which ML Kit reports as UPC-A.
        if format == .ean13 && raw.count == 13 && raw.hasPrefix("0") {
            format = .upcA
            value = String(raw.dropFirst())
        }
        return CodeContent.parse(format, value)
    }

    static func format(_ s: VNBarcodeSymbology) -> CodeFormat {
        switch s {
        case .qr, .microQR: .qrCode
        case .dataMatrix: .dataMatrix
        case .pdf417, .microPDF417: .pdf417
        case .aztec: .aztec
        case .ean13: .ean13
        case .ean8: .ean8
        case .upce: .upcE
        case .code128: .code128
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: .code39
        case .code93, .code93i: .code93
        case .codabar: .codabar
        case .itf14, .i2of5, .i2of5Checksum: .itf
        default: .unknown
        }
    }

    private static func quad(_ o: VNRectangleObservation) -> DocumentQuad {
        DocumentQuad(topLeft: flip(o.topLeft), topRight: flip(o.topRight), bottomRight: flip(o.bottomRight), bottomLeft: flip(o.bottomLeft))
    }

    /// Vision has its origin at the bottom left corner.
    private static func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }

    private static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.minY)].map(flip)
    }

    private static func line(_ text: String, _ r: CGRect, _ w: Int, _ h: Int) -> ScanLine {
        let W = Double(w), H = Double(h)
        return ScanLine(text, ScanBox(Int((r.minX * W).rounded()), Int(((1 - r.maxY) * H).rounded()),
                                      Int((r.maxX * W).rounded()), Int(((1 - r.minY) * H).rounded())))
    }
}
