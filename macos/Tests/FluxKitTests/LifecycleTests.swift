import XCTest
@testable import FluxKit

final class LifecycleTests: XCTestCase {
    private func makeCore(plugins: [FluxPlugin] = []) throws -> FluxCore {
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

    private func waitForPort(_ core: FluxCore) {
        let deadline = Date().addingTimeInterval(5)
        while core.state.tcpPort == 0, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testResumeStartsAStoppedCore() throws {
        let core = try makeCore()
        XCTAssertFalse(core.isRunning)
        core.resume()
        XCTAssertTrue(core.isRunning)
        waitForPort(core)
        XCTAssertGreaterThan(core.state.tcpPort, 0)
        core.stop()
        XCTAssertFalse(core.isRunning)
        core.resume()
        XCTAssertTrue(core.isRunning, "the app starts the network again when it returns")
    }

    func testResumeKeepsARunningCore() throws {
        let core = try makeCore()
        core.start()
        waitForPort(core)
        let port = core.state.tcpPort
        core.resume()
        XCTAssertTrue(core.isRunning)
        XCTAssertEqual(core.state.tcpPort, port, "a running network keeps its listener and links")
        XCTAssertTrue(core.state.searching, "it searches again, so that computers connect at once")
    }

    func testResumeLeavesFluxOff() throws {
        let core = try makeCore()
        core.enabled = false
        core.resume()
        XCTAssertFalse(core.isRunning)
    }

    func testClipboardPollsOnlyWhileActive() {
        XCTAssertTrue(ClipboardPlugin.shouldPoll(sync: true, connected: true, active: true))
        XCTAssertFalse(ClipboardPlugin.shouldPoll(sync: true, connected: true, active: false), "no clipboard reads off the screen")
        XCTAssertFalse(ClipboardPlugin.shouldPoll(sync: false, connected: true, active: true))
        XCTAssertFalse(ClipboardPlugin.shouldPoll(sync: true, connected: false, active: true))
    }

    func testClipboardReadsOnConnect() {
        XCTAssertTrue(ClipboardPlugin.readsOnConnect(platform: .mac, count: 5, lastSeen: nil), "the Mac reads at each link")
        XCTAssertTrue(ClipboardPlugin.readsOnConnect(platform: .mac, count: 5, lastSeen: 5))
        XCTAssertFalse(ClipboardPlugin.readsOnConnect(platform: .phone, count: 5, lastSeen: nil), "no read before the iPhone knows the clipboard")
        XCTAssertFalse(ClipboardPlugin.readsOnConnect(platform: .phone, count: 5, lastSeen: 5), "no read when nothing changed, so iOS asks no Allow Paste")
        XCTAssertTrue(ClipboardPlugin.readsOnConnect(platform: .phone, count: 6, lastSeen: 5), "a new copy goes out")
    }

    @MainActor
    func testClipboardActiveState() throws {
        let clipboard = ClipboardPlugin()
        _ = try makeCore(plugins: [clipboard])
        XCTAssertTrue(clipboard.isActive, "the Mac app is always active")
        clipboard.setActive(false)
        XCTAssertFalse(clipboard.isActive)
        XCTAssertFalse(clipboard.isPolling)
        clipboard.setActive(true)
        XCTAssertTrue(clipboard.isActive)
        XCTAssertFalse(clipboard.isPolling, "no computer is connected")
    }
}
