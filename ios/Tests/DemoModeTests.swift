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
        let laptop = DemoMode.computers[0].id
        try ScreenRender.render(NavigationStack { ChatsView() }.modifier(ThemeRoot()).environment(app), name: "demo-01-chats")
        try ScreenRender.render(NavigationStack { ControlView() }.modifier(ThemeRoot()).environment(app), name: "demo-02-control")
        try ScreenRender.render(NavigationStack { ComputersView() }.modifier(ThemeRoot()).environment(app), name: "demo-03-computers")
        try ScreenRender.render(NavigationStack { ComputerChatView(deviceId: laptop) }.modifier(ThemeRoot()).environment(app),
                                name: "demo-04-chat")
        try ScreenRender.render(NavigationStack { AgentScreen(deviceId: laptop, pane: "w2:p1") }.modifier(ThemeRoot()).environment(app),
                                name: "demo-05-agent")
        XCTAssertFalse(app.core.isRunning)
    }

    func testTheDemoListHasTheSampleChats() throws {
        let app = try TestApp.model(demo: true)
        let laptop = DemoMode.computers[0].id
        let desktop = DemoMode.computers[1].id
        let list = app.chatList(query: "")
        XCTAssertEqual(list.needs.map(\.id), ["approve|\(laptop)|demo1", "agent|\(laptop)|w2:p1"],
                       "the approval is newer than the agent that waits")
        XCTAssertEqual(list.agents.map(\.id), ["agent|\(laptop)|w1:p1", "agent|\(laptop)|w3:p1", "agent|\(laptop)|w3:p2"],
                       "the agent that works, the agent that is done, then the idle agent")
        XCTAssertEqual(list.computers.map(\.id), ["computer|\(laptop)", "computer|\(desktop)"], "the online computer first")
        guard case .computer(_, let last)? = list.computers.first else { return XCTFail("the first computer row is not a computer") }
        XCTAssertEqual(last?.preview, "You: Dinner at 7, bring the kids")
        XCTAssertNotNil(app.lastSeen(desktop), "the desktop shows when it went offline")
        XCTAssertNil(app.lastSeen(laptop))
        XCTAssertEqual(app.chatList(query: "").needs.map(\.id), list.needs.map(\.id), "each row keeps its place")

        let found = app.chatList(query: "invoice")
        XCTAssertTrue(found.needs.isEmpty && found.agents.isEmpty)
        XCTAssertEqual(found.computers.map(\.id), ["computer|\(laptop)"], "a computer stays when an entry of its chat holds the text")
        guard case .computer(_, let match)? = found.computers.first else { return XCTFail("the row is not a computer") }
        XCTAssertEqual(match?.preview, "Receiving invoice-2026-09.pdf")
    }

    func testTheDemoChatHasTheSampleEntries() throws {
        let app = try TestApp.model(demo: true)
        let laptop = DemoMode.computers[0].id
        let items = DemoMode.inboxItems()
        XCTAssertEqual(items.map(\.kind), [.agentInput, .agentWorking, .agentDone, .approval])
        XCTAssertEqual(Inbox.needsYou(items), 2)
        XCTAssertEqual(DemoMode.inboxItems().map(\.key), items.map(\.key), "the keys stay the same")
        let entries = app.chatEntries(of: laptop, all: items)
        XCTAssertEqual(entries.map(Self.entryName), ["link", "photo", "clip", "file", "text", "approval"],
                       "the order of the chat design, without agents")
        XCTAssertEqual(app.chatEntries(of: laptop, all: items).map(\.id), entries.map(\.id), "each entry keeps its place")
        XCTAssertTrue(app.chatEntries(of: DemoMode.computers[1].id, all: items).isEmpty, "the desktop has no entries")
        XCTAssertEqual(DemoMode.output(pane: "w2:p1", review: false)?.choices.last.map(Chat.isTellChoice), true,
                       "the last choice of the sample agent opens a reply")
        XCTAssertEqual(DemoMode.output.choices.map(\.key), ["1", "2", "3"])
        XCTAssertEqual(DemoMode.output(pane: "w2:p1", review: false)?.choices.map(\.key), ["1", "2", "3"])
        XCTAssertEqual(DemoMode.output(pane: "w1:p1", review: false).map { AgentThread.parse($0.lines.map(\.text)).step }, "Running tests")
        XCTAssertEqual(DemoMode.output(pane: "w2:p1", review: true).map { DiffFile.parse($0.lines.map(\.text)).map(\.path) },
                       ["app/models/invoice.rb", "db/migrate/0042_add_invoice_status.sql"])
        XCTAssertEqual(Inbox.agentPrompt(DemoMode.output.lines.map(\.text)),
                       "Bash command\nbin/migrate --apply\nApply the pending migration\nDo you want to proceed?")
    }

    /// A short name of a chat entry of the demo.
    private static func entryName(_ e: ChatEntry) -> String {
        switch e {
        case .sent(let s): return s.kind == .text ? "text" : "link"
        case .file(let t): return t.incoming ? "file" : "photo"
        case .clip: return "clip"
        case .answer: return "answer"
        case .event(let item, _):
            switch item.kind {
            case .agentInput: return "blocked"
            case .agentWorking: return "working"
            case .agentDone: return "done"
            case .approval: return "approval"
            case .pairRequest: return "pair"
            }
        }
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
