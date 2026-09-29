import FluxKit
import SwiftUI
import XCTest
@testable import Flux

/// The demo for App Review and screenshots: sample computers and no
/// network. The renders go to TEST_RUNNER_FLUX_SCREENS, see `ScreenRender`.
@MainActor
final class DemoModeTests: XCTestCase {
    func testShowsTheSampleComputers() throws {
        let app = try TestApp.model(demo: true)
        XCTAssertEqual(app.paired.map(\.name), ["omarchy", "workstation"])
        XCTAssertTrue(app.available.isEmpty)
        XCTAssertTrue(app.state.enabled, "the demo shows Flux as on")
        let laptop = try XCTUnwrap(app.device(DemoMode.computers[0].id))
        XCTAssertTrue(laptop.online, "the connected computer shows its features")
        XCTAssertTrue(laptop.isFlux)
        XCTAssertTrue(laptop.accepts(PacketType.share))
        XCTAssertTrue(RemoteInputPlugin.supported(laptop))
        XCTAssertTrue(DesktopPlugin.supported(laptop))
        XCTAssertFalse(try XCTUnwrap(app.device(DemoMode.computers[1].id)).online)
    }

    func testStartsNoNetwork() throws {
        let app = try TestApp.model(demo: true)
        app.scenePhaseChanged(.active)
        app.core.search()
        XCTAssertFalse(app.core.isRunning, "the demo starts no discovery, listener, or link")
        // A new state of the core keeps the sample computers.
        app.core.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(app.state.devices, DemoMode.computers)
        XCTAssertFalse(app.core.isRunning)
    }

    func testRendersTheDemoScreens() throws {
        let app = try TestApp.model(demo: true, plugins: PluginRegistry.make())
        try ScreenRender.render(NavigationStack { ComputersView() }.environment(app), name: "demo-01-computers")
        try ScreenRender.render(NavigationStack { DeviceView(deviceId: DemoMode.computers[0].id) }.environment(app),
                                name: "demo-02-computer")
        XCTAssertFalse(app.core.isRunning)
    }
}
