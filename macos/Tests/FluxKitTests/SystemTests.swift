import XCTest
@testable import FluxKit

final class DndGuardTests: XCTestCase {
    func testLocalChangesGoOutOnce() {
        let g = DndGuard()
        XCTAssertFalse(g.local(false, now: 0), "the first state is the start value")
        XCTAssertFalse(g.local(false, now: 10), "the same state is not a change")
        XCTAssertTrue(g.local(true, now: 20), "a new state goes to the computers")
        XCTAssertFalse(g.local(true, now: 30), "a change goes out once")
    }

    func testRemoteChangeDoesNotEcho() {
        let g = DndGuard()
        _ = g.local(false, now: 0)
        XCTAssertTrue(g.remote(true, now: 100), "a new state from a computer applies")
        XCTAssertFalse(g.local(false, now: 500), "the old state during the wait is not a change")
        XCTAssertFalse(g.local(true, now: 800), "the applied state does not go back")
        XCTAssertFalse(g.remote(true, now: 900), "the same state from a computer does not apply again")
        XCTAssertTrue(g.local(false, now: 10_000), "a later local change goes out")
    }

    func testFailedApplyGivesTheMacState() {
        let g = DndGuard(settleMs: 3_000)
        _ = g.local(false, now: 0)
        _ = g.remote(true, now: 0)
        XCTAssertFalse(g.local(false, now: 2_000))
        XCTAssertTrue(g.local(false, now: 4_000), "after the wait, the Mac state goes out")
    }

    func testRemoteBeforeTheFirstLocalState() {
        let g = DndGuard()
        XCTAssertTrue(g.remote(true, now: 0))
        XCTAssertFalse(g.local(true, now: 10))
    }
}

final class ComputerNotificationTests: XCTestCase {
    private func packet(_ body: [String: Any?]) -> Packet {
        Packet.parse(Packet(PacketType.notification, body).serialize())!
    }

    func testNotificationFromFluxd() {
        let n = ComputerNotification(
            packet(["id": "flux-1", "appName": "omarchy-xps", "title": "Build done", "text": "make · 42s", "time": "1790000000000", "isClearable": true]),
            deviceId: "pc1", computer: "omarchy-xps"
        )!
        XCTAssertEqual(n.subtitle, "omarchy-xps")
        XCTAssertEqual(n.title, "Build done")
        XCTAssertEqual(n.text, "make · 42s")
        XCTAssertEqual(n.key, "pc1:flux-1")
    }

    func testNotificationFromAnotherApp() {
        // Another app name shows next to the computer name.
        let n = ComputerNotification(packet(["id": "7", "appName": "Firefox", "title": "Download done"]), deviceId: "pc1", computer: "omarchy-xps")!
        XCTAssertEqual(n.subtitle, "Firefox · omarchy-xps")
        XCTAssertEqual(n.title, "Download done")
        XCTAssertEqual(n.text, "")
    }

    func testNotificationWithoutTitleOrID() {
        XCTAssertNil(ComputerNotification(packet(["id": "x"]), deviceId: "pc1", computer: "omarchy-xps"))
        XCTAssertNil(ComputerNotification(packet(["id": "8", "text": "only text"]), deviceId: "pc1", computer: "pc"), "the text is not a title")
        XCTAssertNil(ComputerNotification(packet(["id": "9", "ticker": "Download done"]), deviceId: "pc1", computer: "pc"), "the ticker is not a title")
        XCTAssertNil(ComputerNotification(packet(["id": "10", "title": "  "]), deviceId: "pc1", computer: "pc"), "a blank title")
        XCTAssertNil(ComputerNotification(packet(["title": "no id"]), deviceId: "pc1", computer: "omarchy-xps"))
    }

    /// A computer that sends many notifications cannot bury the others.
    func testNotificationLimitPerComputer() {
        var limit = NotificationLimit()
        let burst = Int(NotificationLimit.burst)
        for i in 0..<burst { XCTAssertTrue(limit.allow("pc1", now: 100), "\(i)") }
        XCTAssertFalse(limit.allow("pc1", now: 100), "the burst is used up")
        XCTAssertTrue(limit.allow("pc2", now: 100), "another computer has its own limit")
        XCTAssertFalse(limit.allow("pc1", now: 100.5))
        XCTAssertTrue(limit.allow("pc1", now: 101.1), "1 more each second")
        XCTAssertFalse(limit.allow("pc1", now: 101.2))
        for _ in 0..<burst { XCTAssertTrue(limit.allow("pc1", now: 1000)) }
        XCTAssertFalse(limit.allow("pc1", now: 1000), "a long pause gives the burst again, not more")
    }

    /// Only a notification that finds the full burst makes a sound.
    func testABurstMakesOneSound() {
        var limit = NotificationLimit()
        XCTAssertEqual(limit.take("pc1", now: 100), .sound)
        XCTAssertEqual(limit.take("pc1", now: 100), .quiet)
        XCTAssertEqual(limit.take("pc1", now: 100.5), .quiet)
        XCTAssertEqual(limit.take("pc2", now: 100.5), .sound, "another computer has its own burst")
        XCTAssertEqual(limit.take("pc1", now: 200), .sound, "a pause fills the burst again")
    }

    /// A computer keeps at most 20 delivered notifications. A new one
    /// removes the oldest.
    func testAComputerKeepsAtMost20Notifications() {
        var delivered = DeliveredNotifications()
        var removed: [String] = []
        for i in 0..<30 { removed += delivered.add("n\(i)", deviceId: "pc1") }
        XCTAssertEqual(delivered.delivered("pc1").count, 20)
        XCTAssertEqual(delivered.delivered("pc1").first, "n10")
        XCTAssertEqual(removed, (0..<10).map { "n\($0)" }, "the oldest go first")
        XCTAssertEqual(delivered.add("n15", deviceId: "pc1"), [], "a post with the same ID replaces that notification")
        XCTAssertEqual(delivered.delivered("pc1").count, 20)
        XCTAssertEqual(delivered.delivered("pc1").last, "n15")
        XCTAssertEqual(delivered.add("x", deviceId: "pc2"), [], "another computer has its own list")
    }

    /// The notification IDs of a computer name its device ID, so that a
    /// restart finds the notifications of each computer.
    func testNotificationIdsNameTheComputer() {
        let pc = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(DeliveredNotifications.deviceId(of: "computer-\(pc):build:done"), pc)
        XCTAssertEqual(DeliveredNotifications.deviceId(of: DeliveredNotifications.linkId(deviceId: pc)), pc)
        XCTAssertNil(DeliveredNotifications.deviceId(of: "share-\(UUID().uuidString)"), "a received file has no computer")
        XCTAssertNil(DeliveredNotifications.deviceId(of: "pair-\(pc)"))
        XCTAssertNil(DeliveredNotifications.deviceId(of: "computer-\(pc)"), "the ID needs a colon after the device ID")
        XCTAssertNil(DeliveredNotifications.deviceId(of: "computer-bad id:x"))
    }

    /// The notifications of an earlier run count toward the limit. They are
    /// older than the notifications of this run.
    func testASeedKeepsTheLimit() {
        let pc1 = "0123456789abcdef0123456789abcdef"
        let pc2 = "fedcba9876543210fedcba9876543210"
        var delivered = DeliveredNotifications()
        XCTAssertEqual(delivered.add("computer-\(pc1):new", deviceId: pc1), [])
        let found = (0..<25).map { "computer-\(pc1):\($0)" } + ["computer-\(pc1):new", "computer-\(pc2):a", "share-file", "pair-\(pc1)"]
        let removed = delivered.seed(found)
        XCTAssertEqual(removed, (0..<6).map { "computer-\(pc1):\($0)" }, "the oldest go first")
        XCTAssertEqual(delivered.delivered(pc1).count, 20)
        XCTAssertEqual(delivered.delivered(pc1).first, "computer-\(pc1):6")
        XCTAssertEqual(delivered.delivered(pc1).last, "computer-\(pc1):new", "a notification of this run stays the newest")
        XCTAssertEqual(delivered.delivered(pc2), ["computer-\(pc2):a"])
        let shown = found.filter { !removed.contains($0) }
        XCTAssertEqual(delivered.seed(shown), [], "a second seed of the shown notifications adds nothing")
        XCTAssertEqual(delivered.delivered(pc1).count, 20)
    }

    /// Notifications and received links of a computer take tokens from 1 shared limit.
    func testSharedLimitPerComputer() {
        let pc = UUID().uuidString
        for i in 0..<Int(NotificationLimit.burst) { XCTAssertTrue(NotificationLimit.allowsNow(pc), "\(i)") }
        XCTAssertFalse(NotificationLimit.allowsNow(pc), "the burst is used up")
        XCTAssertTrue(NotificationLimit.allowsNow(UUID().uuidString), "another computer has its own limit")
    }
}

final class BatteryStateTests: XCTestCase {
    func testPacketReportsLowOnlyWhenNotCharging() {
        let low = BatteryState(charge: 15, charging: false).packet
        XCTAssertEqual(low.type, PacketType.battery)
        XCTAssertEqual(low.int("currentCharge"), 15)
        XCTAssertEqual(low.bool("isCharging"), false)
        XCTAssertEqual(low.int("thresholdEvent"), 1)
        XCTAssertEqual(BatteryState(charge: 15, charging: true).packet.int("thresholdEvent"), 0)
        XCTAssertEqual(BatteryState(charge: 16, charging: false).packet.int("thresholdEvent"), 0)
    }

    func testComputerBatteryWithoutChargeIsNone() {
        XCTAssertNil(BatteryState(packet: Packet(PacketType.battery, ["currentCharge": -1, "isCharging": false])))
        XCTAssertNil(BatteryState(packet: Packet(PacketType.battery, [:])))
        XCTAssertEqual(BatteryState(packet: Packet(PacketType.battery, ["currentCharge": 80, "isCharging": true])), BatteryState(charge: 80, charging: true))
    }

    func testPacketRoundTrips() {
        for state in [BatteryState(charge: 0, charging: false), BatteryState(charge: 57, charging: true), BatteryState(charge: 100, charging: false)] {
            XCTAssertEqual(BatteryState(packet: state.packet), state)
        }
    }

    func testLevelMapping() {
        XCTAssertNil(BatteryState(level: -1, charging: false), "the simulator reports -1: no battery")
        XCTAssertEqual(BatteryState(level: 0, charging: false), BatteryState(charge: 0, charging: false))
        XCTAssertEqual(BatteryState(level: 0.574, charging: true), BatteryState(charge: 57, charging: true))
        XCTAssertEqual(BatteryState(level: 0.576, charging: false), BatteryState(charge: 58, charging: false), "the level rounds")
        XCTAssertEqual(BatteryState(level: 1, charging: true), BatteryState(charge: 100, charging: true))
        XCTAssertEqual(BatteryState(level: 1.2, charging: false), BatteryState(charge: 100, charging: false), "the charge stays at most 100")
    }
}
