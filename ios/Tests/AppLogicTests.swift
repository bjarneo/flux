import FluxKit
import UserNotifications
import XCTest
@testable import Flux

final class AppLogicTests: XCTestCase {
    func testNewlyPaired() {
        let old = [(id: "a", paired: false), (id: "b", paired: true), (id: "c", paired: false)]
        let new = [(id: "a", paired: true), (id: "b", paired: true), (id: "c", paired: false), (id: "d", paired: true)]
        XCTAssertEqual(AppModel.newlyPaired(old: old, new: new), ["a"], "a computer that was already paired or was not known does not count")
        XCTAssertEqual(AppModel.newlyPaired(old: new, new: new), [])
    }

    func testUnlockLastsFiveMinutes() {
        var window = UnlockWindow(validFor: 300)
        XCTAssertFalse(window.isUnlocked(at: 1000), "locked at start")
        window.unlock(at: 1000)
        XCTAssertTrue(window.isUnlocked(at: 1000))
        XCTAssertTrue(window.isUnlocked(at: 1299))
        XCTAssertFalse(window.isUnlocked(at: 1300), "the unlock ends after 5 minutes")
        window.unlock(at: 2000)
        XCTAssertTrue(window.isUnlocked(at: 2200), "a new unlock starts a new window")
    }

    func testAppearanceStyles() {
        XCTAssertEqual(AppAppearance.automatic.style, .unspecified)
        XCTAssertEqual(AppAppearance.light.style, .light)
        XCTAssertEqual(AppAppearance.dark.style, .dark)
        XCTAssertEqual(AppAppearance(rawValue: "dark"), .dark, "the stored value is the raw value")
    }

    func testBatteryTexts() {
        XCTAssertEqual(BatteryState(charge: 82, charging: false).text, "82%")
        XCTAssertEqual(BatteryState(charge: 82, charging: true).text, "82%, charging")
        XCTAssertEqual(BatteryState(charge: 82, charging: true).symbol, "battery.100percent.bolt")
        XCTAssertEqual(BatteryState(charge: 70, charging: false).symbol, "battery.75percent")
        XCTAssertEqual(BatteryState(charge: 5, charging: false).symbol, "battery.0percent")
    }

    @MainActor
    func testNotificationTexts() {
        XCTAssertEqual(NotificationAccess.text(.authorized), "On")
        XCTAssertEqual(NotificationAccess.text(.denied), "Off")
        XCTAssertEqual(NotificationAccess.text(.notDetermined), "Not set up")
        XCTAssertTrue(NotificationAccess.isOn(.provisional))
        XCTAssertFalse(NotificationAccess.isOn(.denied))
    }
}
