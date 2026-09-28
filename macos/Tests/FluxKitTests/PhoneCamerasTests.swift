import AVFoundation
import XCTest
@testable import FluxKit

final class PhoneCamerasTests: XCTestCase {
    private func found(_ id: String, _ name: String, _ position: AVCaptureDevice.Position, wide: Bool = true) -> PhoneCameras.Found {
        PhoneCameras.Found(uniqueID: id, name: name, position: position, wide: wide)
    }

    func testBackAndFrontLikeAndroid() {
        let picked = PhoneCameras.pick([
            found("ultra", "Back Ultra Wide Camera", .back, wide: false),
            found("depth", "Front TrueDepth Camera", .front, wide: false),
            found("wide", "Back Camera", .back),
            found("front", "Front Camera", .front),
            found("tele", "Back Telephoto Camera", .back, wide: false),
        ])
        XCTAssertEqual(picked.map(\.id), ["back", "front"], "1 back and 1 front camera, with the ids of Flux for Android")
        XCTAssertEqual(picked.map(\.uniqueID), ["wide", "front"], "the wide-angle camera of each side")
        XCTAssertEqual(picked.map(\.name), ["Back Camera", "Front Camera"])
    }

    func testAnotherLensWhenASideHasNoWideAngleCamera() {
        let picked = PhoneCameras.pick([found("depth", "Front TrueDepth Camera", .front, wide: false)])
        XCTAssertEqual(picked.map(\.id), ["front"])
        XCTAssertEqual(picked.first?.uniqueID, "depth")
    }

    func testExternalCamerasFollowWithTheirNames() {
        let picked = PhoneCameras.pick([
            found("usb1", "USB Camera ", .unspecified),
            found("wide", "Back Camera", .back),
            found("usb2", "USB Camera", .unspecified),
        ])
        XCTAssertEqual(picked.map(\.id), ["back", "usb camera", "usb camera 2"], "an external camera is named like on the Mac")
        XCTAssertEqual(picked.map(\.name), ["Back Camera", "USB Camera", "USB Camera 2"])
    }

    func testNoCameras() {
        XCTAssertEqual(PhoneCameras.pick([]), [])
    }
}
