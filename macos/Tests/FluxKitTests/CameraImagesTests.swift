import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FluxKit

final class CameraImagesTests: XCTestCase {
    private func image(width: Int, height: Int) throws -> CGImage {
        let ctx = try XCTUnwrap(CameraImages.rgbaContext(width: width, height: height))
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func encode(_ image: CGImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func type(_ data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?
    }

    func testAJPEGPhotoStaysAsItIs() throws {
        let jpeg = try encode(image(width: 40, height: 30), as: .jpeg)
        XCTAssertEqual(try CameraImages.jpegFile(jpeg), jpeg, "a photo keeps its bytes and its metadata")
    }

    func testAnotherFormatBecomesAJPEGOfTheFullSize() throws {
        let png = try encode(image(width: 3000, height: 20), as: .png)
        let out = try CameraImages.jpegFile(png)
        XCTAssertEqual(type(out), UTType.jpeg.identifier)
        let decoded = try CameraImages.decode(out, maxSide: 10_000)
        XCTAssertEqual(decoded.width, 3000, "the photo keeps its size, larger than the size that Flux reads")
        XCTAssertEqual(decoded.height, 20)
    }

    func testDataThatIsNoImageFails() {
        XCTAssertThrowsError(try CameraImages.jpegFile(Data("not an image".utf8)))
    }
}
