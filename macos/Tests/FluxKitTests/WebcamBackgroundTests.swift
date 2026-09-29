#if os(iOS)
import AVFoundation
import XCTest
@testable import FluxKit

@MainActor
final class WebcamBackgroundTests: XCTestCase {
    private func makeCore(plugins: [FluxPlugin]) throws -> FluxCore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "org.omarchy.flux.test." + UUID().uuidString
        var config = LanConfig()
        config.loopbackOnly = true
        config.udpPort = 0
        config.tcpPorts = 0...0
        let core = try FluxCore(paths: FluxPaths(data: dir, suite: suite), lanConfig: config, plugins: plugins)
        addTeardownBlock {
            core.stop()
            try? FileManager.default.removeItem(at: dir)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        return core
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    func testLeavingTheScreenStopsTheStreamWithANotice() throws {
        let webcam = WebcamPlugin()
        _ = try makeCore(plugins: [webcam])
        webcam.start("computer")
        webcam.stopInBackground()
        settle()
        XCTAssertEqual(webcam.model.status.phase, .idle)
        XCTAssertEqual(webcam.model.status.deviceId, "computer")
        XCTAssertEqual(webcam.model.status.message, WebcamPlugin.backgroundText, "the screen tells why the webcam stopped")
    }

    func testLeavingTheScreenWithoutAStreamChangesNothing() throws {
        let webcam = WebcamPlugin()
        _ = try makeCore(plugins: [webcam])
        webcam.stopInBackground()
        settle()
        XCTAssertEqual(webcam.model.status, StreamStatus())
    }

    func testAnInterruptionTellsWhyTheCameraPaused() {
        XCTAssertEqual(CameraSource.interruptionText(.videoDeviceInUseByAnotherClient), "The camera paused because another app uses it")
        XCTAssertEqual(CameraSource.interruptionText(.videoDeviceNotAvailableInBackground), "The camera paused because Flux left the screen")
        XCTAssertEqual(CameraSource.interruptionText(.videoDeviceNotAvailableDueToSystemPressure), "The camera paused because the iPhone is too hot or busy")
        XCTAssertEqual(CameraSource.interruptionText(nil), "The camera paused because iOS took it")
    }
}
#endif
