import FluxKit
import SwiftUI
import XCTest
@testable import Flux

/// Renders the demo Inbox in each sample theme. The renders go to
/// TEST_RUNNER_FLUX_SCREENS, see `ScreenRender`.
@MainActor
final class InboxRenderTests: XCTestCase {
    func testEachSampleTheme() throws {
        defer { DemoMode.themeName = nil }
        let app = try TestApp.model(demo: true, plugins: PluginRegistry.make())
        app.themeMode = .computer
        for theme in SampleThemes.all {
            DemoMode.themeName = theme.name
            XCTAssertEqual(app.computerTheme?.name, theme.name)
            let scheme: ColorScheme = app.computerTheme?.palette.dark == false ? .light : .dark
            try ScreenRender.render(NavigationStack { InboxView() }.modifier(ThemeRoot()).environment(app),
                                    name: "demo-inbox-\(theme.name)", scheme: scheme)
        }
        XCTAssertFalse(app.core.isRunning)
    }
}
