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
        XCTAssertEqual(ClipboardPlugin.watch(platform: .phone, sync: true, paired: true, connected: true, active: true), .send)
        XCTAssertEqual(ClipboardPlugin.watch(platform: .phone, sync: true, paired: true, connected: true, active: false), .off, "no clipboard reads off the screen")
        XCTAssertEqual(ClipboardPlugin.watch(platform: .mac, sync: false, paired: true, connected: true, active: true), .off)
        XCTAssertEqual(ClipboardPlugin.watch(platform: .phone, sync: true, paired: true, connected: false, active: true), .off, "iOS suspends Flux, so the iPhone notes nothing")
    }

    func testTheMacNotesCopiesWhileNoComputerIsConnected() {
        XCTAssertEqual(ClipboardPlugin.watch(platform: .mac, sync: true, paired: true, connected: true, active: true), .send)
        XCTAssertEqual(ClipboardPlugin.watch(platform: .mac, sync: true, paired: true, connected: false, active: true), .note,
                       "a copy while the link is down keeps its time")
        XCTAssertEqual(ClipboardPlugin.watch(platform: .mac, sync: true, paired: false, connected: false, active: true), .off, "no timer without a paired computer")
        XCTAssertEqual(ClipboardPlugin.watch(platform: .mac, sync: false, paired: true, connected: false, active: true), .off)
    }

    func testAnUnseenCopyGoesOut() {
        func step(count: Int = 6, lastSeen: Int? = 5, sends: Bool = true, holdsPrivate: Bool = false, holdsContent: Bool = true) -> ClipboardPlugin.Unseen {
            ClipboardPlugin.unseenCopy(count: count, lastSeen: lastSeen, sends: sends, holdsPrivate: holdsPrivate, holdsContent: holdsContent)
        }
        XCTAssertEqual(step(), .send, "a copy from before a cold start or from the background goes out")
        XCTAssertEqual(step(lastSeen: nil), .note, "no read before the iPhone knows the clipboard")
        XCTAssertEqual(step(count: 5), .seen, "no read when nothing changed, so iOS asks no Allow Paste")
        XCTAssertEqual(step(sends: false), .note, "Send the clipboard when Flux opens is off")
        XCTAssertEqual(step(holdsPrivate: true), .note, "a password stays on the iPhone")
        XCTAssertEqual(step(holdsContent: false), .note, "no read of a copy without text or image")
    }

    @MainActor
    func testTheSeenCountStaysAcrossLaunches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "org.omarchy.flux.test." + UUID().uuidString
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let paths = FluxPaths(data: dir, suite: suite)
        var config = LanConfig()
        config.loopbackOnly = true
        let first = ClipboardPlugin()
        let core = try FluxCore(paths: paths, lanConfig: config, plugins: [first])
        XCTAssertNil(first.seenCount, "a new install does not know the clipboard")
        first.seenCount = 42
        let second = ClipboardPlugin()
        let next = try FluxCore(paths: paths, lanConfig: config, plugins: [second])
        XCTAssertEqual(second.seenCount, 42, "a copy from before a cold start counts as new")
        withExtendedLifetime((core, next)) {}
    }

    func testTextFromAComputerKeepsItsTime() {
        XCTAssertTrue(ClipboardPlugin.takes(nil, last: 1000), "flux.clipboard is a new copy")
        XCTAssertTrue(ClipboardPlugin.takes(0, last: 1000), "a packet without a time counts")
        XCTAssertFalse(ClipboardPlugin.takes(900, last: 1000), "an older copy of the computer loses")
        XCTAssertFalse(ClipboardPlugin.takes(1000, last: 1000), "the same copy after a reconnect changes nothing")
        XCTAssertTrue(ClipboardPlugin.takes(1100, last: 1000))
        XCTAssertEqual(ClipboardPlugin.time(of: 1100, now: 2000), 1100)
        XCTAssertEqual(ClipboardPlugin.time(of: nil, now: 2000), 2000, "flux.clipboard gets the time that it arrived")
        XCTAssertEqual(ClipboardPlugin.time(of: 0, now: 2000), 2000)
    }

    func testTheSameTextIsUnchanged() {
        let key = Data(repeating: 7, count: 32)
        let a = ClipboardPlugin.digest("a", key: key)
        XCTAssertEqual(a, ClipboardPlugin.digest("a", key: key))
        XCTAssertNotEqual(a, ClipboardPlugin.digest("b", key: key))
        XCTAssertNotEqual(a, ClipboardPlugin.digest("a", key: Data(repeating: 8, count: 32)),
                          "without the key of this install, a digest in a backup does not give away the text")
        XCTAssertTrue(ClipboardPlugin.isUnchanged(a, sent: a, remote: nil), "the text that Flux sent last")
        XCTAssertTrue(ClipboardPlugin.isUnchanged(a, sent: nil, remote: a), "the text from a computer does not echo back")
        XCTAssertFalse(ClipboardPlugin.isUnchanged(a, sent: ClipboardPlugin.digest("b", key: key), remote: nil))
        XCTAssertFalse(ClipboardPlugin.isUnchanged(a, sent: nil, remote: nil))
    }

    func testACopyBeforeTheLinkDropsKeepsItsTime() {
        XCTAssertTrue(ClipboardPlugin.notesOnChange(from: .send, to: .note), "the last poll did not see the copy, so it did not go out")
        XCTAssertTrue(ClipboardPlugin.notesOnChange(from: .note, to: .send), "a copy from the last seconds before the link")
        XCTAssertTrue(ClipboardPlugin.notesOnChange(from: .note, to: .off))
        XCTAssertFalse(ClipboardPlugin.notesOnChange(from: .off, to: .note), "a launch does not make the old clipboard new")
        XCTAssertFalse(ClipboardPlugin.notesOnChange(from: .off, to: .send))
        XCTAssertFalse(ClipboardPlugin.notesOnChange(from: .send, to: .off), "with sync off, no copy goes out")
    }

    func testTextFromAComputerDoesNotGoBackOnConnect() {
        let remote = ClipboardPlugin.RemoteCopy(device: "desk", count: 5)
        XCTAssertTrue(ClipboardPlugin.sendsOnConnect(to: "desk", count: 5, remote: nil))
        XCTAssertFalse(ClipboardPlugin.sendsOnConnect(to: "desk", count: 5, remote: remote), "the computer has this text already")
        XCTAssertTrue(ClipboardPlugin.sendsOnConnect(to: "laptop", count: 5, remote: remote), "another computer gets the text")
        XCTAssertTrue(ClipboardPlugin.sendsOnConnect(to: "desk", count: 6, remote: remote), "a new copy on the Mac goes out")
    }

    func testTheWaitForLinksEnds() {
        func ends(connected: Int, paired: Int, waited: Duration, sinceFirst: Duration?) -> Bool {
            FluxCore.linkWaitEnds(connected: connected, paired: paired, waited: waited, sinceFirst: sinceFirst,
                                  timeout: .seconds(20), settle: .seconds(2))
        }
        XCTAssertFalse(ends(connected: 0, paired: 1, waited: .seconds(5), sinceFirst: nil))
        XCTAssertTrue(ends(connected: 1, paired: 1, waited: .seconds(1), sinceFirst: .zero), "each paired computer is connected")
        XCTAssertFalse(ends(connected: 1, paired: 2, waited: .seconds(1), sinceFirst: .seconds(1)), "the other computer can still connect")
        XCTAssertTrue(ends(connected: 1, paired: 2, waited: .seconds(3), sinceFirst: .seconds(2)), "a computer that is off does not hold the send")
        XCTAssertTrue(ends(connected: 0, paired: 1, waited: .seconds(20), sinceFirst: nil), "the wait ends after the timeout")
        XCTAssertTrue(ends(connected: 0, paired: 0, waited: .zero, sinceFirst: nil), "with no paired computer, no link can come")
        XCTAssertTrue(ends(connected: 0, paired: 0, waited: .seconds(20), sinceFirst: nil))
    }

    @MainActor
    func testClipboardActiveState() throws {
        let clipboard = ClipboardPlugin()
        _ = try makeCore(plugins: [clipboard])
        XCTAssertEqual(clipboard.isActive, FluxPlatform.current == .mac, "the Mac app is always active, and the iOS app waits for its scene")
        clipboard.setActive(false)
        XCTAssertFalse(clipboard.isActive)
        XCTAssertFalse(clipboard.isPolling)
        clipboard.setActive(true)
        XCTAssertTrue(clipboard.isActive)
        XCTAssertFalse(clipboard.isPolling, "no computer is connected")
    }
}
