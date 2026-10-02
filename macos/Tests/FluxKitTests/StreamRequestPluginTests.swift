import UserNotifications
import XCTest
@testable import FluxKit

/// The plugin of flux.stream.request: the capability, the prompt, and the
/// rule that only a tap on start starts a stream.
@MainActor
final class StreamRequestPluginTests: XCTestCase {
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

    /// A plugin with the webcam and the microphone, and the requests that it opens.
    private func makePlugin(lifetime: Duration = StreamRequest.lifetime) throws -> (StreamRequestPlugin, Opened) {
        let plugin = StreamRequestPlugin(lifetime: lifetime)
        _ = try makeCore(plugins: [plugin, WebcamPlugin(), MicPlugin()])
        let opened = Opened()
        plugin.model.open = { opened.requests.append($0) }
        return (plugin, opened)
    }

    private final class Opened {
        var requests: [StreamRequest] = []
    }

    func testListsTheTypeOnlyWithBothStreams() throws {
        let both = StreamRequestPlugin()
        let core = try makeCore(plugins: [both, WebcamPlugin(), MicPlugin()])
        XCTAssertEqual(both.incoming, [PacketType.fluxStreamRequest])
        XCTAssertTrue(core.incomingCapabilities.contains(PacketType.fluxStreamRequest))
        XCTAssertEqual(both.outgoing, [], "the device only takes the request")

        let micOnly = StreamRequestPlugin()
        let other = try makeCore(plugins: [micOnly, MicPlugin()])
        XCTAssertEqual(micOnly.incoming, [], "a device that cannot stream both kinds does not list the type")
        XCTAssertFalse(other.incomingCapabilities.contains(PacketType.fluxStreamRequest))
        XCTAssertEqual(micOnly.handledTypes, [PacketType.fluxStreamRequest])
    }

    func testTheRequestOnlyAsks() throws {
        let (plugin, opened) = try makePlugin()
        plugin.receive(.webcam, computerId: "pc1", computerName: "omarchy")
        XCTAssertEqual(plugin.model.current?.title, "omarchy asks for the webcam")
        XCTAssertTrue(opened.requests.isEmpty, "the packet starts nothing")

        plugin.start("stream.webcam.pc1")
        XCTAssertEqual(opened.requests.map(\.id), ["stream.webcam.pc1"], "the tap on start opens the stream")
        XCTAssertTrue(plugin.model.requests.isEmpty, "the request ends")

        plugin.start("stream.webcam.pc1")
        XCTAssertEqual(opened.requests.count, 1, "a request starts once")
    }

    func testNotNowStartsNothing() throws {
        let (plugin, opened) = try makePlugin()
        plugin.receive(.mic, computerId: "pc1", computerName: "omarchy")
        plugin.dismiss("stream.mic.pc1")
        XCTAssertTrue(plugin.model.requests.isEmpty)
        plugin.start("stream.mic.pc1")
        XCTAssertTrue(opened.requests.isEmpty, "a request that ended starts nothing")
    }

    func testAnOldRequestStartsNothing() throws {
        let (plugin, opened) = try makePlugin()
        let t0 = ContinuousClock.now
        plugin.receive(.webcam, computerId: "pc1", computerName: "omarchy", at: t0)
        plugin.start("stream.webcam.pc1", at: t0 + .seconds(61))
        XCTAssertTrue(opened.requests.isEmpty, "a tap on an old notification starts nothing")
        XCTAssertTrue(plugin.model.requests.isEmpty)
    }

    func testAFreshTapOnTheNotificationStartsTheStream() throws {
        let (plugin, opened) = try makePlugin()
        var pages = 0
        plugin.model.openPage = { _, _ in pages += 1 }
        plugin.receive(.mic, computerId: "pc1", computerName: "omarchy")
        plugin.startFromNotification("stream.mic.pc1", kind: .mic, computerId: "pc1")
        XCTAssertEqual(opened.requests.map(\.id), ["stream.mic.pc1"])
        XCTAssertEqual(pages, 0, "open opens the page and starts the stream")
    }

    func testALateTapOnTheNotificationOpensOnlyThePage() throws {
        let (plugin, opened) = try makePlugin()
        var pages: [String] = []
        plugin.model.openPage = { computerId, kind in pages.append("\(kind.rawValue) \(computerId)") }
        let t0 = ContinuousClock.now
        plugin.receive(.webcam, computerId: "pc1", computerName: "omarchy", at: t0)
        plugin.startFromNotification("stream.webcam.pc1", kind: .webcam, computerId: "pc1", at: t0 + .seconds(63))
        XCTAssertTrue(opened.requests.isEmpty, "a tap after the 60 seconds starts no stream")
        XCTAssertEqual(pages, ["webcam pc1"], "the page opens, and the user starts the stream there")
        XCTAssertTrue(plugin.model.requests.isEmpty)

        plugin.startFromNotification("stream.mic.pc1", kind: .mic, computerId: "pc1")
        XCTAssertEqual(pages, ["webcam pc1", "mic pc1"], "a request that ended also opens only the page")
        plugin.startFromNotification("stream.mic.pc1", kind: .mic, computerId: nil)
        XCTAssertEqual(pages.count, 2, "a notification that does not name the computer opens nothing")
        XCTAssertTrue(opened.requests.isEmpty)
    }

    func testTheNewestRequestShowsFirst() throws {
        let (plugin, _) = try makePlugin()
        plugin.receive(.webcam, computerId: "pc1", computerName: "omarchy")
        plugin.receive(.mic, computerId: "pc2", computerName: "studio")
        XCTAssertEqual(plugin.model.current?.id, "stream.mic.pc2")
        plugin.dismiss("stream.mic.pc2")
        XCTAssertEqual(plugin.model.current?.id, "stream.webcam.pc1", "the next request shows after Not now")
    }

    func testThePromptShowsOnlyWhileTheAppIsActive() throws {
        let (plugin, _) = try makePlugin()
        var presented = 0
        plugin.model.present = { presented += 1 }
        plugin.model.isAppActive = { false }
        plugin.receive(.webcam, computerId: "pc1", computerName: "omarchy")
        XCTAssertEqual(presented, 0, "a notification shows the request")
        plugin.model.isAppActive = { true }
        plugin.receive(.mic, computerId: "pc1", computerName: "omarchy")
        XCTAssertEqual(presented, 1)
        plugin.receive(.mic, computerId: "pc1", computerName: "omarchy")
        XCTAssertEqual(presented, 1, "a request within 3 seconds shows nothing")
    }

    func testARequestEndsByItself() async throws {
        let (plugin, opened) = try makePlugin(lifetime: .milliseconds(50))
        plugin.receive(.webcam, computerId: "pc1", computerName: "omarchy")
        XCTAssertEqual(plugin.model.requests.count, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(plugin.model.requests.isEmpty, "the request and its notification end after the lifetime")
        plugin.start("stream.webcam.pc1")
        XCTAssertTrue(opened.requests.isEmpty)
    }

    func testAnUnpairEndsTheRequestsOfTheComputer() throws {
        let (plugin, _) = try makePlugin()
        plugin.receive(.webcam, computerId: "pc1", computerName: "omarchy")
        plugin.receive(.mic, computerId: "pc2", computerName: "studio")
        plugin.forget("pc1")
        XCTAssertEqual(plugin.model.requests.map(\.id), ["stream.mic.pc2"])
    }

    func testARunningStreamOfTheKindIgnoresTheRequest() {
        let live = StreamStatus(.live, "Live on omarchy as Flux Camera", deviceId: "pc1")
        XCTAssertTrue(StreamRequestPlugin.streams(webcam: live, to: "pc1"))
        XCTAssertFalse(StreamRequestPlugin.streams(webcam: live, to: "pc2"), "a stream to another computer does not count")
        XCTAssertTrue(StreamRequestPlugin.streams(webcam: StreamStatus(.connecting, deviceId: "pc1"), to: "pc1"))
        XCTAssertFalse(StreamRequestPlugin.streams(webcam: StreamStatus(.error, "closed", deviceId: "pc1"), to: "pc1"))
        XCTAssertFalse(StreamRequestPlugin.streams(webcam: nil, to: "pc1"))

        XCTAssertTrue(StreamRequestPlugin.streams(mic: MicModel.Status(.starting, deviceId: "pc1"), to: "pc1"))
        XCTAssertFalse(StreamRequestPlugin.streams(mic: MicModel.Status(.live, deviceId: "pc2"), to: "pc1"))
        XCTAssertFalse(StreamRequestPlugin.streams(mic: MicModel.Status(.idle, deviceId: "pc1"), to: "pc1"))
        XCTAssertFalse(StreamRequestPlugin.streams(mic: nil, to: "pc1"))
    }

    func testTheNotificationStartsOnlyWithATap() {
        XCTAssertTrue(StreamRequestPlugin.startsStream(StreamRequestPlugin.startAction))
        XCTAssertTrue(StreamRequestPlugin.startsStream(UNNotificationDefaultActionIdentifier), "the text asks for a tap or a click")
        XCTAssertFalse(StreamRequestPlugin.startsStream(UNNotificationDismissActionIdentifier))
        XCTAssertFalse(StreamRequestPlugin.startsStream("other"))

        let phone = StreamRequestPlugin.notificationActions(.webcam, platform: .phone)
        XCTAssertEqual(phone.map(\.identifier), ["start"])
        XCTAssertEqual(phone.map(\.title), ["Start webcam"])
        XCTAssertTrue(phone[0].options.contains(.foreground), "the camera of an iPhone needs Flux on the screen")
        XCTAssertTrue(phone[0].options.contains(.authenticationRequired), "a locked iPhone starts nothing")
        let mac = StreamRequestPlugin.notificationActions(.mic, platform: .mac)
        XCTAssertEqual(mac.map(\.title), ["Start the mic"])
        XCTAssertEqual(mac[0].options, [.foreground])
    }
}
