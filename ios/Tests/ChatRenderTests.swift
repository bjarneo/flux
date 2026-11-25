import FluxKit
import SwiftUI
import XCTest
@testable import Flux

/// Renders the demo list of chats and the demo chat of the laptop in each
/// sample theme. The renders go to TEST_RUNNER_FLUX_SCREENS, see `ScreenRender`.
@MainActor
final class ChatRenderTests: XCTestCase {
    func testEachSampleTheme() throws {
        defer { DemoMode.themeName = nil }
        let app = try TestApp.model(demo: true, plugins: PluginRegistry.make())
        app.themeMode = .computer
        for theme in SampleThemes.all {
            DemoMode.themeName = theme.name
            XCTAssertEqual(app.computerTheme?.name, theme.name)
            let scheme: ColorScheme = app.computerTheme?.palette.dark == false ? .light : .dark
            try ScreenRender.render(NavigationStack { ChatsView() }.modifier(ThemeRoot()).environment(app),
                                    name: "demo-chats-\(theme.name)", scheme: scheme)
            try ScreenRender.render(NavigationStack { ComputerChatView(deviceId: DemoMode.computers[0].id) }.modifier(ThemeRoot()).environment(app),
                                    name: "demo-chat-\(theme.name)", scheme: scheme)
        }
        XCTAssertFalse(app.core.isRunning)
    }
}
