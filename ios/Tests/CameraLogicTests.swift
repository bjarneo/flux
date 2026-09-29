import FluxKit
import XCTest
@testable import Flux

final class CameraLogicTests: XCTestCase {
    func testModesFollowTheCameraScreenOfAndroid() {
        XCTAssertEqual(CameraMode.allCases.map(\.label), ["Text", "QR", "Photo", "Document", "Signature", "Webcam"])
        XCTAssertEqual(CameraMode.webcam.hint, "Use this iPhone as a webcam")
    }

    @MainActor
    func testPageLabels() {
        XCTAssertEqual(DocumentPages.label(1), "1 page")
        XCTAssertEqual(DocumentPages.label(3), "3 pages")
    }

    @MainActor
    func testTheWebcamModeLeavesTheCameraToTheWebcam() throws {
        let model = CameraScreenModel(deviceId: "computer", app: try TestApp.model(), mode: .webcam)
        defer { model.close() }
        XCTAssertEqual(model.cameraUse, .off, "the webcam runs its own camera")
        model.mode = .photo
        XCTAssertEqual(model.cameraUse, .preview)
        model.mode = .qr
        XCTAssertEqual(model.cameraUse, .scan(.codes))
    }

    @MainActor
    func testDictationWaitsForTheMicrophoneStream() throws {
        let app = try TestApp.model()
        XCTAssertNil(MicFeature.dictationProblem(app.core), "no stream, so the dictation may start")
    }
}

/// An app model over a core that does not start the network. `demo` shows
/// the sample computers of `DemoMode`, and `plugins` replaces the 3 plugins.
@MainActor
enum TestApp {
    static func model(demo: Bool = false, plugins: [FluxPlugin]? = nil) throws -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var config = LanConfig()
        config.loopbackOnly = true
        config.udpPort = 0
        config.tcpPorts = 0...0
        let core = try FluxCore(paths: FluxPaths(data: dir, suite: "org.omarchy.flux.test." + UUID().uuidString), lanConfig: config,
                                plugins: plugins ?? [SharePlugin(), MicPlugin(), WebcamPlugin()])
        return AppModel(core: core, demo: demo)
    }
}
