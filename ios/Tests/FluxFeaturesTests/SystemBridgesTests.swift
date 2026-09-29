import XCTest
@testable import FluxFeatures
@testable import FluxProto
#if canImport(UserNotifications)
import UserNotifications
#endif

/// M2 system bridges: the pending-share queue (M3 fetch reads it) and the
/// desktop-notification content mapping. Packet parsing itself is covered
/// in `FluxProtoTests`; `FluxCoreTests` covers routing.
final class SystemBridgesTests: XCTestCase {
    func testPendingShareQueue() async {
        let store = PendingShareStore()
        let empty = await store.count
        XCTAssertEqual(0, empty)
        await store.put(ShareFile(filename: "a.jpg", payloadSize: 3))
        await store.put(ShareFile(filename: "b.jpg", payloadSize: 4))
        let count = await store.count
        XCTAssertEqual(2, count)
        let taken = await store.takeAll()
        XCTAssertEqual(["a.jpg", "b.jpg"], taken.map(\.filename))
        let drained = await store.count
        XCTAssertEqual(0, drained)
        let rest = await store.takeAll()
        XCTAssertTrue(rest.isEmpty)
    }

    func testBatteryBridgeWithoutUIKitIsNil() async {
#if !canImport(UIKit)
        let battery = await BatteryBridge.read()
        XCTAssertNil(battery)
#endif
    }

    func testBatteryCacheRoundTrip() {
        // Main-thread-fed cache for the link provider (no UIKit needed:
        // refresh() is the only UIKit touch, tested on device).
        let cache = BatteryCache()
        XCTAssertNil(cache.read())
        XCTAssertNil(cache.provider()())
        let full = BatteryState(level: 82, charging: true)
        cache.update(full)
        XCTAssertEqual(full, cache.read())
        XCTAssertEqual(full, cache.provider()())
        cache.update(nil)
        XCTAssertNil(cache.read())
    }

    func testNotificationContentMapping() throws {
#if canImport(UserNotifications)
        let n = ComputerNotification(
            key: "dev:flux-1", subText: "omarchy · omarchy-xps",
            title: "Build done", text: "OK", timeMs: 1,
            clearable: true, cancel: false
        )
        let content = try XCTUnwrap(DesktopNotificationBridge.content(for: n) as? UNMutableNotificationContent)
        XCTAssertEqual("Build done", content.title)
        XCTAssertEqual("OK", content.body)
        XCTAssertEqual("omarchy · omarchy-xps", content.subtitle)
        XCTAssertEqual(DesktopNotificationBridge.categoryId, content.categoryIdentifier)
#else
        XCTAssertNil(DesktopNotificationBridge.content(for: ComputerNotification(
            key: "k", subText: "s", title: "t", text: "b", timeMs: 1, clearable: true, cancel: false)))
#endif
    }
}

/// M4 system bridges: call aggregation (pure, device behavior is in
/// `CallTracker` vectors), Focus change-only gating, desktop-DND content,
/// and now-playing action routing. Packet shapes live in `FluxProtoTests`.
final class M4BridgesTests: XCTestCase {
    // MARK: - Calls

    func testAggregatePrefersOffHook() {
        XCTAssertEqual(.idle, CallBridge.aggregate([]))
        XCTAssertEqual(.idle, CallBridge.aggregate([ObservedCall(connected: false, ended: true, outgoing: false)]))
        XCTAssertEqual(.ringing, CallBridge.aggregate([ObservedCall(connected: false, ended: false, outgoing: false)]))
        // Dialing counts as talking (Android OffHook covers user-started calls).
        XCTAssertEqual(.offHook, CallBridge.aggregate([ObservedCall(connected: false, ended: false, outgoing: true)]))
        XCTAssertEqual(.offHook, CallBridge.aggregate([ObservedCall(connected: true, ended: false, outgoing: false)]))
        // A live call wins over a ringing second line.
        XCTAssertEqual(.offHook, CallBridge.aggregate([
            ObservedCall(connected: false, ended: false, outgoing: false),
            ObservedCall(connected: true, ended: false, outgoing: false),
        ]))
    }

    func testCallLifecycleEmitsTelephony() {
        let bridge = CallBridge()
        let sent = PacketBox()
        bridge.onPacket = { sent.packets.append($0) }
        bridge.emit([ObservedCall(connected: false, ended: false, outgoing: false)])
        bridge.emit([ObservedCall(connected: true, ended: false, outgoing: false)])
        bridge.emit([])
        XCTAssertEqual(["ringing", "talking", "talking"], sent.packets.map { $0.string("event") })
        XCTAssertEqual([nil, nil, true], sent.packets.map { $0.bool("isCancel") })
        for p in sent.packets {
            XCTAssertEqual(PacketType.telephony, p.type)
            // iOS exposes no number: every call shows the fallback.
            XCTAssertEqual("Unknown caller", p.string("contactName"))
        }
        // Missed call: ringing straight to idle.
        sent.packets.removeAll()
        bridge.emit([ObservedCall(connected: false, ended: false, outgoing: false)])
        bridge.emit([])
        XCTAssertEqual(["ringing", "missedCall", "ringing"], sent.packets.map { $0.string("event") })
        XCTAssertEqual(true, sent.packets.last?.bool("isCancel"))
    }

    // MARK: - Focus

    func testFocusRefreshWithoutAccessNeverEmits() {
        let bridge = FocusBridge()
        let emitted = BoolBox()
        bridge.onChange = { emitted.values.append($0) }
        // No requestAccess on this process: denied/restricted/not-determined
        // all stay silent (the app asks once at setup, on device).
        bridge.refresh()
        XCTAssertTrue(emitted.values.isEmpty)
    }

    func testDesktopDndContent() throws {
        #if canImport(UserNotifications)
        let on = try XCTUnwrap(DesktopDndBridge.content(computer: "omarchy-xps", on: true) as? UNMutableNotificationContent)
        XCTAssertEqual("Do Not Disturb on omarchy-xps", on.title)
        XCTAssertEqual(DesktopDndBridge.categoryId, on.categoryIdentifier)
        let off = try XCTUnwrap(DesktopDndBridge.content(computer: "omarchy-xps", on: false) as? UNMutableNotificationContent)
        XCTAssertEqual("Do Not Disturb off omarchy-xps", off.title)
        #else
        XCTAssertNil(DesktopDndBridge.content(computer: "pc", on: true))
        #endif
    }

    // MARK: - Now playing

    func testNowPlayingHandleRoutes() {
        let bridge = NowPlayingBridge(playerName: "Music")
        var played = 0
        var sought: [Int64] = []
        bridge.onPause = {}
        bridge.onPlay = { played += 1 }
        bridge.onSeek = { sought.append($0) }
        XCTAssertTrue(bridge.handle(player: "Music", action: "Play"))
        XCTAssertEqual(1, played)
        XCTAssertTrue(bridge.handleSeek(player: "Music", positionMs: 9_000))
        XCTAssertEqual([9_000], sought)
        // Another player's packets and unknown verbs are refused.
        XCTAssertFalse(bridge.handle(player: "spotify", action: "Play"))
        XCTAssertFalse(bridge.handle(player: "Music", action: "Dance"))
        XCTAssertFalse(bridge.handleSeek(player: "spotify", positionMs: 1))
        XCTAssertEqual(1, played)
    }

    func testNowPlayingCurrentIsOurs() {
        // Reads back published state; nil when nothing plays. Never crashes
        // on a machine with unrelated players (their state is not ours).
        if let c = NowPlayingBridge(playerName: "Music").current() {
            XCTAssertEqual("Music", c.player)
        }
    }
}

/// Unchecked boxes for `@Sendable` bridge callbacks in tests (the test
/// thread is the only writer).
private final class PacketBox: @unchecked Sendable {
    var packets: [Packet] = []
}

private final class BoolBox: @unchecked Sendable {
    var values: [Bool] = []
}
