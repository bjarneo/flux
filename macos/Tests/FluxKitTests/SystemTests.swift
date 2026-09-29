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
