import XCTest
@testable import FluxCamera

/// Placeholder until M5 ports FrameGeometry + H.264 Annex B with golden-frame
/// tests from Android `H264Encoder`.
final class FluxCameraTests: XCTestCase {
    func testCameraModesCoverPlan() {
        XCTAssertEqual(["text", "qr", "photo", "document", "webcam"], CameraMode.allCases.map(\.rawValue))
    }
}
