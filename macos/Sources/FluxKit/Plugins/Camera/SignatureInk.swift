import CoreGraphics
import Foundation

/// The ink of a signature. `alpha` holds 1 byte for each pixel, row by row,
/// from 0 (paper) to 255 (ink). `original` is the mean color of the ink as
/// 0xRRGGBB.
public struct SignatureInk: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let alpha: [UInt8]
    public let original: Int

    public init(width: Int, height: Int, alpha: [UInt8], original: Int) {
        self.width = width
        self.height = height
        self.alpha = alpha
        self.original = original
    }

    /// Returns the ARGB pixels of the signature in `rgb`, on a transparent background.
    public func pixels(_ rgb: Int) -> [UInt32] {
        let color = UInt32(rgb & 0xFFFFFF)
        return alpha.map { UInt32($0) << 24 | color }
    }
}

/// The colors that the signature can have. `rgb` is nil for the color of the pen.
public enum InkColor: CaseIterable, Sendable {
    case black, blue, original

    public var label: String {
        switch self {
        case .black: "Black"
        case .blue: "Blue"
        case .original: "Original"
        }
    }

    public var rgb: Int? {
        switch self {
        case .black: 0x000000
        case .blue: 0x1A3DB0
        case .original: nil
        }
    }

    public func of(_ ink: SignatureInk) -> Int { rgb ?? ink.original }
}

/// A rectangle in image pixels.
public struct SignatureCrop: Equatable, Sendable {
    public var left: Int
    public var top: Int
    public var width: Int
    public var height: Int

    public init(_ left: Int, _ top: Int, _ width: Int, _ height: Int) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }
}

/// Cuts the ink of a signature out of a photo of paper, like Flux for
/// Android. The steps remove uneven light, find the split between paper and
/// ink, remove specks and dark areas at the border, and crop to the ink.
public enum SignatureCut {
    /// The largest image that `extract` reads.
    public static let maxPixels = 8_000_000

    /// The largest side of the image that the ink comes from.
    public static let maxSide = 1600

    /// Returns the ink in `argb`, an image of `width` by `height` pixels
    /// (0xAARRGGBB, row by row), or nil when the image has no ink.
    public static func extract(_ argb: [UInt32], width: Int, height: Int) -> SignatureInk? {
        precondition(width > 0 && height > 0 && argb.count == width * height, "The pixels do not match the size")
        precondition(width * height <= maxPixels, "The image is too large")
        let luma = argb.map { c -> Int in
            (77 * Int(c >> 16 & 0xFF) + 150 * Int(c >> 8 & 0xFF) + 29 * Int(c & 0xFF)) >> 8
        }
        let dark = darkness(luma, width, height)
        let split = min(max(otsu(dark), 0.08), 0.40)
        var alpha = ramp(dark, low: split * 0.6, high: min(split * 1.4, 0.95))
        keepStrokes(&alpha, width, height)
        guard let box = inkBounds(alpha, width, height) else { return nil }
        // The mean color of the pixels that are surely ink.
        var r = 0, g = 0, b = 0, core = 0
        for y in box.minY...box.maxY {
            for x in box.minX...box.maxX where alpha[y * width + x] >= 230 {
                let c = argb[y * width + x]
                r += Int(c >> 16 & 0xFF)
                g += Int(c >> 8 & 0xFF)
                b += Int(c & 0xFF)
                core += 1
            }
        }
        if core == 0 { return nil }
        return crop(alpha, width, height, box, original: (r / core) << 16 | (g / core) << 8 | b / core)
    }

    /// Crops alpha that is already clean, such as a drawn signature, to the
    /// ink with the same margin as `extract`. It returns nil without ink.
    public static func ink(alpha: [UInt8], width: Int, height: Int, original: Int) -> SignatureInk? {
        precondition(alpha.count == width * height, "The pixels do not match the size")
        let values = alpha.map(Int.init)
        guard let box = inkBounds(values, width, height) else { return nil }
        return crop(values, width, height, box, original: original)
    }

    /// Maps a frame in a view to the image that the view shows with aspect
    /// fill: the image fills the view and the overflow is cut off equally on
    /// both sides. `pad` enlarges the frame by that part of its size on each
    /// side. The result stays inside the image.
    public static func frameInImage(
        left: Float, top: Float, right: Float, bottom: Float,
        viewWidth: Int, viewHeight: Int, imageWidth: Int, imageHeight: Int,
        pad: Float = 0
    ) -> SignatureCrop {
        let scale = max(Float(viewWidth) / Float(imageWidth), Float(viewHeight) / Float(imageHeight))
        let offsetX = (Float(viewWidth) - Float(imageWidth) * scale) / 2
        let offsetY = (Float(viewHeight) - Float(imageHeight) * scale) / 2
        let padX = (right - left) * pad
        let padY = (bottom - top) * pad
        let x0 = clamp(round((left - padX - offsetX) / scale), 0, imageWidth - 1)
        let y0 = clamp(round((top - padY - offsetY) / scale), 0, imageHeight - 1)
        let x1 = clamp(round((right + padX - offsetX) / scale), x0 + 1, imageWidth)
        let y1 = clamp(round((bottom + padY - offsetY) / scale), y0 + 1, imageHeight)
        return SignatureCrop(x0, y0, x1 - x0, y1 - y0)
    }

    /// The guide frame, 5 by 2, centered in a view. It is 88 % of the width
    /// when the height allows it.
    public static func guideFrame(width: CGFloat, height: CGFloat) -> CGRect {
        var w = width * 0.88
        var h = w * 0.4
        if h > height * 0.6 {
            h = height * 0.6
            w = h * 2.5
        }
        return CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
    }

    /// Rounds half up, like Kotlin's roundToInt.
    private static func round(_ v: Float) -> Int { Int((v + 0.5).rounded(.down)) }

    private static func clamp(_ v: Int, _ low: Int, _ high: Int) -> Int { min(max(v, low), high) }

    /// Returns how much darker each pixel is than the paper around it, from
    /// 0 to 1. The paper is the mean of a large window. A second pass leaves
    /// out the pixels that look like ink, so dense strokes do not darken the
    /// paper.
    private static func darkness(_ luma: [Int], _ w: Int, _ h: Int) -> [Float] {
        let radius = max(12, max(w, h) / 20)
        let first = boxMean(luma, [Int](repeating: 1, count: luma.count), w, h, radius, fallback: nil)
        let paper = (0..<luma.count).map { i in Float(luma[i] * 100) >= first[i] * 85 ? 1 : 0 }
        let paperLuma = (0..<luma.count).map { luma[$0] * paper[$0] }
        let second = boxMean(paperLuma, paper, w, h, radius, fallback: first)
        return (0..<luma.count).map { i in
            let bg = max(second[i], 1)
            return min(max(1 - Float(luma[i]) / bg, 0), 1)
        }
    }

    /// Returns the sum of `values` divided by the sum of `weights` in a
    /// square window around each pixel. Where the window has no weight, the
    /// result comes from `fallback`.
    private static func boxMean(_ values: [Int], _ weights: [Int], _ w: Int, _ h: Int, _ r: Int, fallback: [Float]?) -> [Float] {
        let sv = integral(values, w, h)
        let sw = integral(weights, w, h)
        let stride = w + 1
        var out = [Float](repeating: 0, count: w * h)
        sv.withUnsafeBufferPointer { sv in
            sw.withUnsafeBufferPointer { sw in
                out.withUnsafeMutableBufferPointer { out in
                    for y in 0..<h {
                        let y0 = max(0, y - r), y1 = min(h, y + r + 1)
                        for x in 0..<w {
                            let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                            let v = sv[y1 * stride + x1] - sv[y0 * stride + x1] - sv[y1 * stride + x0] + sv[y0 * stride + x0]
                            let c = sw[y1 * stride + x1] - sw[y0 * stride + x1] - sw[y1 * stride + x0] + sw[y0 * stride + x0]
                            out[y * w + x] = c > 0 ? Float(v) / Float(c) : fallback?[y * w + x] ?? 255
                        }
                    }
                }
            }
        }
        return out
    }

    /// Returns the summed-area table of `a`, with 1 extra row and column of zeros.
    private static func integral(_ a: [Int], _ w: Int, _ h: Int) -> [Int] {
        let stride = w + 1
        var s = [Int](repeating: 0, count: stride * (h + 1))
        a.withUnsafeBufferPointer { a in
            s.withUnsafeMutableBufferPointer { s in
                for y in 0..<h {
                    var row = 0
                    for x in 0..<w {
                        row += a[y * w + x]
                        s[(y + 1) * stride + x + 1] = s[y * stride + x + 1] + row
                    }
                }
            }
        }
        return s
    }

    /// Returns the split between paper and ink with Otsu's method, from 0 to 1.
    private static func otsu(_ dark: [Float]) -> Float {
        let bins = 256
        var hist = [Int](repeating: 0, count: bins)
        for v in dark { hist[round(v * Float(bins - 1))] += 1 }
        let total = Double(dark.count)
        var sumAll = 0.0
        for i in 0..<bins { sumAll += Double(i) * Double(hist[i]) }
        var sumBack = 0.0, countBack = 0.0, best = 0.0
        var split = 0
        for i in 0..<bins {
            countBack += Double(hist[i])
            if countBack == 0 { continue }
            let countFore = total - countBack
            if countFore == 0 { break }
            sumBack += Double(i) * Double(hist[i])
            let meanBack = sumBack / countBack
            let meanFore = (sumAll - sumBack) / countFore
            let between = countBack * countFore * (meanBack - meanFore) * (meanBack - meanFore)
            if between > best {
                best = between
                split = i
            }
        }
        return Float(split) / Float(bins - 1)
    }

    /// Maps darkness to alpha with a smooth step from `low` to `high`, so edges stay soft.
    private static func ramp(_ dark: [Float], low: Float, high: Float) -> [Int] {
        dark.map { d in
            let s = min(max((d - low) / (high - low), 0), 1)
            return round(s * s * (3 - 2 * s) * 255)
        }
    }

    /// Keeps the strokes and removes the rest. A stroke is a connected area
    /// of pixels with alpha of 128 or more. The step removes specks, and
    /// solid areas that touch the border, such as a table, a shadow, or the
    /// edge of the paper. Thin strokes fill only a small part of their box.
    /// Soft edge pixels stay only next to a stroke that stays.
    private static func keepStrokes(_ alpha: inout [Int], _ w: Int, _ h: Int) {
        let n = w * h
        var label = [Int](repeating: 0, count: n)
        var stack = [Int](repeating: 0, count: n)
        let minSize = max(4, n / 60_000)
        // keepLabel[k - 1] tells whether the stroke with label k stays.
        var keepLabel: [Bool] = []
        var next = 0
        alpha.withUnsafeBufferPointer { alpha in
            label.withUnsafeMutableBufferPointer { label in
                stack.withUnsafeMutableBufferPointer { stack in
                    for start in 0..<n where alpha[start] >= 128 && label[start] == 0 {
                        next += 1
                        var top = 0
                        stack[top] = start
                        top += 1
                        label[start] = next
                        var size = 0
                        var minX = w, minY = h, maxX = -1, maxY = -1
                        var border = false
                        while top > 0 {
                            top -= 1
                            let p = stack[top]
                            size += 1
                            let x = p % w, y = p / w
                            minX = min(minX, x)
                            maxX = max(maxX, x)
                            minY = min(minY, y)
                            maxY = max(maxY, y)
                            if x == 0 || y == 0 || x == w - 1 || y == h - 1 { border = true }
                            for ny in max(0, y - 1)...min(h - 1, y + 1) {
                                for nx in max(0, x - 1)...min(w - 1, x + 1) {
                                    let q = ny * w + nx
                                    if alpha[q] >= 128 && label[q] == 0 {
                                        label[q] = next
                                        stack[top] = q
                                        top += 1
                                    }
                                }
                            }
                        }
                        let boxArea = (maxX - minX + 1) * (maxY - minY + 1)
                        let solid = border && size * 100 > boxArea * 35
                        keepLabel.append(size >= minSize && !solid)
                    }
                }
            }
        }
        let keep = label.map { $0 != 0 && keepLabel[$0 - 1] }
        // Soft pixels stay within 2 pixels of a stroke that stays.
        let near = grow(grow(keep, w, h), w, h)
        for i in 0..<n where !near[i] { alpha[i] = 0 }
    }

    /// Returns `mask` grown by 1 pixel in the 8 directions.
    private static func grow(_ mask: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: mask.count)
        mask.withUnsafeBufferPointer { mask in
            out.withUnsafeMutableBufferPointer { out in
                for y in 0..<h {
                    for x in 0..<w where mask[y * w + x] {
                        for ny in max(0, y - 1)...min(h - 1, y + 1) {
                            for nx in max(0, x - 1)...min(w - 1, x + 1) { out[ny * w + nx] = true }
                        }
                    }
                }
            }
        }
        return out
    }

    private struct Bounds {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
    }

    /// The box of the pixels with some alpha, or nil when there are none.
    private static func inkBounds(_ alpha: [Int], _ w: Int, _ h: Int) -> Bounds? {
        var b = Bounds(minX: w, minY: h, maxX: -1, maxY: -1)
        for y in 0..<h {
            for x in 0..<w where alpha[y * w + x] != 0 {
                b.minX = min(b.minX, x)
                b.maxX = max(b.maxX, x)
                b.minY = min(b.minY, y)
                b.maxY = max(b.maxY, y)
            }
        }
        return b.maxX < 0 ? nil : b
    }

    /// Crops to the ink with a margin.
    private static func crop(_ alpha: [Int], _ w: Int, _ h: Int, _ box: Bounds, original: Int) -> SignatureInk {
        let margin = max(8, max(box.maxX - box.minX, box.maxY - box.minY) / 40)
        let left = box.minX - margin
        let top = box.minY - margin
        let cw = box.maxX - box.minX + 1 + 2 * margin
        let ch = box.maxY - box.minY + 1 + 2 * margin
        var out = [UInt8](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            let sy = top + y
            if sy < 0 || sy >= h { continue }
            for x in 0..<cw {
                let sx = left + x
                if sx < 0 || sx >= w { continue }
                out[y * cw + x] = UInt8(alpha[sy * w + sx])
            }
        }
        return SignatureInk(width: cw, height: ch, alpha: out, original: original)
    }
}
