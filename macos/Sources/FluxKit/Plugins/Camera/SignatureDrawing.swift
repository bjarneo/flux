import CoreGraphics
import Foundation

/// A signature that the user draws with a trackpad, a mouse, or a tablet.
/// It becomes the same transparent ink as a signature on paper: the strokes
/// are smoothed, drawn with soft edges, and cropped to the ink with the
/// margin of `SignatureCut`.
public struct SignatureDrawing: Equatable, Sendable {
    /// The strokes in canvas points. The origin is the top left corner.
    public private(set) var strokes: [[CGPoint]] = []

    /// The width of a stroke in canvas points.
    public static let lineWidth: CGFloat = 3

    public init() {}

    public var isEmpty: Bool { strokes.isEmpty }

    /// Starts a new stroke at a point.
    public mutating func begin(_ p: CGPoint) { strokes.append([p]) }

    /// Adds a point to the current stroke. Points closer than half a point
    /// to the last one add nothing.
    public mutating func extend(_ p: CGPoint) {
        guard let last = strokes.last?.last else { return begin(p) }
        if hypot(p.x - last.x, p.y - last.y) < 0.5 { return }
        strokes[strokes.count - 1].append(p)
    }

    public mutating func undo() { if !strokes.isEmpty { strokes.removeLast() } }

    public mutating func clear() { strokes.removeAll() }

    /// Returns the smoothed path of 1 stroke: quadratic curves through the
    /// midpoints of the points, with the points as controls. A single point
    /// becomes a dot.
    public static func path(_ stroke: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = stroke.first else { return path }
        path.move(to: first)
        if stroke.count == 1 {
            path.addLine(to: first)
            return path
        }
        for i in 1..<stroke.count {
            let a = stroke[i - 1], b = stroke[i]
            path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        path.addLine(to: stroke[stroke.count - 1])
        return path
    }

    /// Draws the strokes at `scale` pixels per point and cuts out the ink.
    /// The ink color is the pen color, black. It returns nil without strokes.
    public func ink(canvas: CGSize, scale: CGFloat = 2) -> SignatureInk? {
        let w = max(1, Int((canvas.width * scale).rounded(.up)))
        let h = max(1, Int((canvas.height * scale).rounded(.up)))
        guard !strokes.isEmpty, w * h <= SignatureCut.maxPixels,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        // Black is paper and white is ink, so each gray value is the alpha.
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // The canvas has its origin at the top left corner.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineWidth(Self.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes {
            ctx.addPath(Self.path(stroke))
            ctx.strokePath()
        }
        guard let data = ctx.data else { return nil }
        let rows = data.assumingMemoryBound(to: UInt8.self)
        var alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { alpha[y * w + x] = rows[y * ctx.bytesPerRow + x] }
        }
        return SignatureCut.ink(alpha: alpha, width: w, height: h, original: 0x000000)
    }
}
