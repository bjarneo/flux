import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import FluxKit

final class VisionScanTests: XCTestCase {
    func testReadsAQRCodeFromAnImage() throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("https://example.com/flux-ios".utf8)
        let code = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let padded = code.composited(over: CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -60, dy: -60)))
        let image = try XCTUnwrap(CIContext().createCGImage(padded, from: padded.extent))
        let codes = try VisionScan.codes(in: image)
        XCTAssertEqual(codes.map(\.raw), ["https://example.com/flux-ios"], "also in the iOS simulator, which has no Neural Engine")
        XCTAssertEqual(codes.first?.format, .qrCode)
    }
}
