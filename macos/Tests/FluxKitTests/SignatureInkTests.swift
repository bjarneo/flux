import CoreGraphics
import XCTest
@testable import FluxKit

/// java.util.Random, so the images match the Android test.
private struct JavaRandom {
    private var seed: Int64

    init(_ seed: Int64) { self.seed = (seed ^ 0x5DEECE66D) & ((1 << 48) - 1) }

    private mutating func next(_ bits: Int) -> Int32 {
        seed = (seed &* 0x5DEECE66D &+ 0xB) & ((1 << 48) - 1)
        return Int32(truncatingIfNeeded: seed >> (48 - bits))
    }

    mutating func nextInt(_ bound: Int32) -> Int {
        if bound & -bound == bound { return Int((Int64(bound) &* Int64(next(31))) >> 31) }
        var bits: Int32, val: Int32
        repeat {
            bits = next(31)
            val = bits % bound
        } while bits &- val &+ (bound &- 1) < 0
        return Int(val)
    }
}

final class SignatureInkTests: XCTestCase {
    private let w = 800
    private let h = 320
    private let inkRgb: UInt32 = 0x283278

    /// Paper that goes from bright on the left to a shadow on the right, with noise.
    private func paper(_ seed: Int64 = 1) -> [UInt32] {
        var random = JavaRandom(seed)
        return (0..<(w * h)).map { i in
            let x = i % w
            let base = 235 - 80 * x / w
            let v = min(max(base + random.nextInt(13) - 6, 0), 255)
            return rgb(v, v, max(v - 8, 0))
        }
    }

    private func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 { 0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }

    /// Draws a filled disc of ink.
    private func dot(_ img: inout [UInt32], _ cx: Int, _ cy: Int, _ radius: Int) {
        for y in (cy - radius)...(cy + radius) {
            for x in (cx - radius)...(cx + radius) where (0..<w).contains(x) && (0..<h).contains(y) {
                let dx = x - cx, dy = y - cy
                if dx * dx + dy * dy <= radius * radius { img[y * w + x] = 0xFF00_0000 | inkRgb }
            }
        }
    }

    /// Draws a wave from x = 200 to 600 around y = 160, 3 pixels thick on each side. Returns its box.
    @discardableResult
    private func stroke(_ img: inout [UInt32]) -> [Int] {
        var minY = h, maxY = 0
        for x in 200...600 {
            let y = 160 + Int(40 * sin(Double(x) / 30.0))
            dot(&img, x, y, 3)
            minY = min(minY, y - 3)
            maxY = max(maxY, y + 3)
        }
        return [197, minY, 603, maxY]
    }

    private func margin(_ box: [Int]) -> Int { max(8, max(box[2] - box[0], box[3] - box[1]) / 40) }

    private func signature() -> SignatureInk {
        var img = paper()
        stroke(&img)
        return SignatureCut.extract(img, width: w, height: h)!
    }

    func testKeepsTheStrokeOnUnevenPaper() throws {
        var img = paper()
        let box = stroke(&img)
        let ink = try XCTUnwrap(SignatureCut.extract(img, width: w, height: h))
        let m = margin(box)
        XCTAssertEqual(ink.width, box[2] - box[0] + 1 + 2 * m)
        XCTAssertEqual(ink.height, box[3] - box[1] + 1 + 2 * m)
        // The stroke is opaque and the paper around it is transparent.
        let opaque = ink.alpha.filter { $0 == 255 }.count
        let visible = ink.alpha.filter { $0 != 0 }.count
        XCTAssertGreaterThan(opaque, 2000, "opaque pixels")
        XCTAssertLessThan(visible, ink.alpha.count / 3, "visible pixels of \(ink.alpha.count)")
        XCTAssertEqual(ink.alpha.first, 0)
        XCTAssertEqual(ink.alpha.last, 0)
    }

    func testFindsTheColorOfThePen() {
        let ink = signature()
        XCTAssertLessThanOrEqual(abs((ink.original >> 16 & 0xFF) - 0x28), 12)
        XCTAssertLessThanOrEqual(abs((ink.original >> 8 & 0xFF) - 0x32), 12)
        XCTAssertLessThanOrEqual(abs((ink.original & 0xFF) - 0x78), 12)
    }

    func testRemovesSpecks() throws {
        let expected = signature()
        // Specks away from the stroke. A kept speck would make the crop larger.
        var img = paper()
        let box = stroke(&img)
        var random = JavaRandom(7)
        var specks = 0
        while specks < 60 {
            let x = random.nextInt(Int32(w))
            let y = random.nextInt(Int32(h))
            if (box[0] - 10...box[2] + 10).contains(x) && (box[1] - 10...box[3] + 10).contains(y) { continue }
            img[y * w + x] = rgb(20, 20, 20)
            specks += 1
        }
        let ink = try XCTUnwrap(SignatureCut.extract(img, width: w, height: h))
        XCTAssertEqual(ink.width, expected.width)
        XCTAssertEqual(ink.height, expected.height)
    }

    func testRemovesADarkAreaAtTheBorder() throws {
        let expected = signature()
        // A table at the bottom of the photo.
        var img = paper()
        stroke(&img)
        for y in (h - 40)..<h { for x in 0..<w { img[y * w + x] = rgb(50, 40, 30) } }
        let ink = try XCTUnwrap(SignatureCut.extract(img, width: w, height: h))
        XCTAssertEqual(ink.width, expected.width)
        XCTAssertEqual(ink.height, expected.height)
    }

    func testRemovesTheEdgeOfThePaper() throws {
        let expected = signature()
        // A thin dark sliver of the table next to the right edge of the paper.
        var img = paper()
        stroke(&img)
        for y in 0..<h { for x in (w - 6)..<w { img[y * w + x] = rgb(60, 55, 50) } }
        let ink = try XCTUnwrap(SignatureCut.extract(img, width: w, height: h))
        XCTAssertEqual(ink.width, expected.width)
        XCTAssertEqual(ink.height, expected.height)
    }

    func testBlankPaperHasNoInk() {
        XCTAssertNil(SignatureCut.extract(paper(3), width: w, height: h))
    }

    func testPixelsUseTheColor() {
        let ink = signature()
        let px = ink.pixels(InkColor.blue.of(ink))
        XCTAssertEqual(px.count, ink.width * ink.height)
        for i in px.indices {
            XCTAssertEqual(px[i] & 0xFFFFFF, 0x1A3DB0)
            XCTAssertEqual(px[i] >> 24, UInt32(ink.alpha[i]))
        }
        XCTAssertEqual(InkColor.original.of(ink), ink.original)
        XCTAssertEqual(InkColor.black.of(ink), 0x000000)
    }

    func testFrameInAPortraitImage() {
        // The image is wider than the view, so aspect fill cuts off its sides.
        let crop = SignatureCut.frameInImage(left: 60, top: 555, right: 940, bottom: 907, viewWidth: 1000, viewHeight: 1500, imageWidth: 3000, imageHeight: 4000)
        XCTAssertEqual(crop, SignatureCrop(327, 1480, 2346, 939))
    }

    func testFrameInALandscapeImage() {
        // The image is taller than the view, so aspect fill cuts off its top and bottom.
        let crop = SignatureCut.frameInImage(left: 100, top: 100, right: 1500, bottom: 500, viewWidth: 1600, viewHeight: 900, imageWidth: 1600, imageHeight: 1200)
        XCTAssertEqual(crop, SignatureCrop(100, 250, 1400, 400))
    }

    func testFramePadsAndStaysInTheImage() {
        XCTAssertEqual(SignatureCut.frameInImage(left: 100, top: 100, right: 300, bottom: 200, viewWidth: 800, viewHeight: 600, imageWidth: 800, imageHeight: 600, pad: 0.1),
                       SignatureCrop(80, 90, 240, 120))
        XCTAssertEqual(SignatureCut.frameInImage(left: -50, top: -50, right: 900, bottom: 700, viewWidth: 800, viewHeight: 600, imageWidth: 800, imageHeight: 600),
                       SignatureCrop(0, 0, 800, 600))
    }

    // MARK: Drawn signatures

    func testADrawnStrokeIsCroppedWithTheMargin() throws {
        var drawing = SignatureDrawing()
        drawing.begin(CGPoint(x: 100, y: 50))
        drawing.extend(CGPoint(x: 200, y: 60))
        drawing.extend(CGPoint(x: 300, y: 50))
        let ink = try XCTUnwrap(drawing.ink(canvas: CGSize(width: 400, height: 200), scale: 2))
        // The stroke spans x 200...600 and y about 100...120 in pixels, 6 pixels wide.
        let spanX = 400 + 6, margin = max(8, spanX / 40)
        XCTAssertEqual(Double(ink.width), Double(spanX + 2 * margin), accuracy: 3)
        XCTAssertLessThan(ink.height, 60, "the crop follows the ink, not the canvas")
        XCTAssertEqual(ink.original, 0)
        XCTAssertGreaterThan(ink.alpha.filter { $0 == 255 }.count, 1000)
        // The stroke dips in the middle: a canvas drawn upside down would put ink at the top there.
        let mid = ink.width / 2
        let rows = (0..<ink.height).filter { ink.alpha[$0 * ink.width + mid] > 128 }
        XCTAssertGreaterThan(try XCTUnwrap(rows.first), ink.height / 3)
    }

    func testAnEmptyDrawingHasNoInk() {
        XCTAssertNil(SignatureDrawing().ink(canvas: CGSize(width: 400, height: 200)))
    }
}
