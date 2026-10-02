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
        try ScreenRender.render(NavigationStack { InboxView() }.modifier(ThemeRoot()).environment(app), name: "demo-01-inbox")
        try ScreenRender.render(NavigationStack { SendView() }.modifier(ThemeRoot()).environment(app), name: "demo-02-send")
        try ScreenRender.render(NavigationStack { ControlView() }.modifier(ThemeRoot()).environment(app), name: "demo-03-control")
        try ScreenRender.render(NavigationStack { ComputersView() }.modifier(ThemeRoot()).environment(app), name: "demo-04-computers")
        XCTAssertFalse(app.core.isRunning)
    }

    func testTheDemoInboxHasTheSampleItems() throws {
        let items = DemoMode.inboxItems(now: Date())
        XCTAssertEqual(items.map(\.kind), [.agentInput, .approval, .media, .clipboard, .transfer, .agentDone])
        XCTAssertEqual(Inbox.needsYou(items), 2)
        XCTAssertEqual(DemoMode.inboxItems(now: Date()).map(\.key), items.map(\.key), "the keys stay the same")
        XCTAssertEqual(DemoMode.output.choices.map(\.key), ["1", "2", "3"])
        XCTAssertEqual(Inbox.agentPrompt(DemoMode.output.lines.map(\.text)),
                       "Bash command\nbin/migrate --apply\nApply the pending migration\nDo you want to proceed?")
    }

    func testTheDemoThemeIsOnTheLaptop() throws {
        DemoMode.themeName = "neon"
        defer { DemoMode.themeName = nil }
        let app = try TestApp.model(demo: true)
        XCTAssertEqual(app.computerTheme?.name, "neon")
        app.themeMode = .computer
        XCTAssertEqual(app.nightMode, .dark, "the windows take the dark mode of neon")
        app.setScope(DemoMode.computers[1].id)
        XCTAssertNil(app.computerTheme, "the desktop sent no theme")
        app.setScope(nil)
        DemoMode.themeName = nil
        XCTAssertNil(app.computerTheme)
    }
}
