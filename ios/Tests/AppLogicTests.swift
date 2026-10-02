import AVFoundation
import FluxKit
import UIKit
import UserNotifications
import XCTest
@testable import Flux

final class AppLogicTests: XCTestCase {
    /// Before the first unlock after a restart, the identity does not read.
    /// The core starts again when iOS unlocks the files, and the features
    /// start once.
    @MainActor
    func testTheCoreStartsAgainAfterTheUnlock() throws {
        let center = NotificationCenter()
        let app = try TestApp.model()
        var makes = 0
        var launches = 0
        let starter = CoreStarter(center: center, make: {
            makes += 1
            if makes == 1 { return (.failed("locked"), true) }
            return (.ready(app), false)
        }, didLaunch: { _ in launches += 1 })
        XCTAssertEqual(starter.observers.count, 2, "the unlock and the activation start the core again")
        starter.didFinishLaunching()
        XCTAssertEqual(launches, 0, "no core, so no features")
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.protectedDataDidBecomeAvailableNotification,
                     UIApplication.didBecomeActiveNotification] {
            center.post(name: name, object: nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(makes, 2, "the core starts again once")
        guard case .ready(let model) = starter.launch else { return XCTFail("the core did not start") }
        XCTAssertTrue(model === app)
        XCTAssertEqual(launches, 1, "the features start once")
        XCTAssertTrue(starter.observers.isEmpty)
    }

    /// A core that starts before launch ends starts its features at the end of launch.
    @MainActor
    func testTheFeaturesStartAfterLaunch() throws {
        let app = try TestApp.model()
        var launches = 0
        let starter = CoreStarter(center: NotificationCenter(), make: { (.ready(app), false) }, didLaunch: { _ in launches += 1 })
        XCTAssertTrue(starter.observers.isEmpty)
        XCTAssertEqual(launches, 0, "the features wait for the end of launch")
        starter.didFinishLaunching()
        XCTAssertEqual(launches, 1)
        starter.didFinishLaunching()
        XCTAssertEqual(launches, 1, "the features start once")
    }

    /// An identity that reads but does not parse does not become readable
    /// later, so the core does not start again.
    @MainActor
    func testADamagedIdentityDoesNotStartAgain() {
        let center = NotificationCenter()
        var makes = 0
        let starter = CoreStarter(center: center, make: {
            makes += 1
            return (.failed(makes == 1 ? "locked" : "damaged"), makes == 1)
        }, didLaunch: { _ in XCTFail("no core, so no features") })
        starter.didFinishLaunching()
        for _ in 0..<3 {
            center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(makes, 2, "a start that fails for another reason ends the tries")
        XCTAssertTrue(starter.observers.isEmpty)
        guard case .failed(let message) = starter.launch else { return XCTFail("the core started") }
        XCTAssertEqual(message, "damaged")
    }

    func testNewlyPaired() {
        let old = [(id: "a", paired: false), (id: "b", paired: true), (id: "c", paired: false)]
        let new = [(id: "a", paired: true), (id: "b", paired: true), (id: "c", paired: false), (id: "d", paired: true)]
        XCTAssertEqual(AppModel.newlyPaired(old: old, new: new), ["a"], "a computer that was already paired or was not known does not count")
        XCTAssertEqual(AppModel.newlyPaired(old: new, new: new), [])
    }

    /// iOS does not mirror the screen (docs/ios-plan.md, Phase 9), so the
    /// iPhone never tells a computer that it can.
    @MainActor
    func testTheIPhoneDoesNotAnnounceTheScreenMirror() {
        let plugins = PluginRegistry.make()
        XCTAssertFalse(plugins.flatMap(\.incoming).contains(PacketType.fluxScreen))
        XCTAssertFalse(plugins.flatMap(\.outgoing).contains(PacketType.fluxScreen))
        XCTAssertTrue(plugins.flatMap(\.outgoing).contains(PacketType.fluxWebcam), "the list is the one that the app registers")
    }

    func testUnlockLastsFiveMinutes() {
        var window = UnlockWindow(validFor: 300)
        XCTAssertFalse(window.isUnlocked(at: 1000), "locked at start")
        XCTAssertFalse(window.isUnlocked(at: -1), "locked at start, also before the start of the clock")
        window.unlock(at: 1000)
        XCTAssertTrue(window.isUnlocked(at: 1000))
        XCTAssertTrue(window.isUnlocked(at: 1299))
        XCTAssertFalse(window.isUnlocked(at: 1300), "the unlock ends after 5 minutes")
        window.unlock(at: 2000)
        XCTAssertTrue(window.isUnlocked(at: 2200), "a new unlock starts a new window")
        window.lock()
        XCTAssertFalse(window.isUnlocked(at: 2200), "a lock of the iPhone ends the unlock at once")
        XCTAssertFalse(window.isUnlocked(at: -1), "a lock ends the unlock at every time")
    }

    func testTheUnlockClockKeepsCounting() {
        let a = ElapsedTime.now
        let b = ElapsedTime.now
        XCTAssertGreaterThanOrEqual(a, 0)
        XCTAssertGreaterThanOrEqual(b, a, "the clock never goes back")
    }

    func testPairKeyGroups() {
        XCTAssertEqual(KeyView.grouped("5EE6825F974ED59A"), "5EE6 825F 974E D59A", "4 groups of 4, as on every device")
        XCTAssertEqual(KeyView.grouped("5BB22DB1"), "5BB2 2DB1", "a key of an earlier app still groups")
        XCTAssertEqual(KeyView.grouped(""), "")
    }

    func testThePairNotificationNeedsAnUnlockToAccept() throws {
        let actions = AppModel.pairActions()
        let accept = try XCTUnwrap(actions.first { $0.identifier == "accept" })
        XCTAssertTrue(accept.options.contains(.authenticationRequired), "a locked iPhone cannot accept a pairing")
        XCTAssertTrue(accept.options.contains(.foreground), "Accept opens Flux, which shows the key")
        let reject = try XCTUnwrap(actions.first { $0.identifier == "reject" })
        XCTAssertEqual(reject.options, [.destructive], "a locked iPhone can reject")
    }

    func testAppearanceStyles() {
        XCTAssertEqual(ThemeMode.system.style, .unspecified)
        XCTAssertEqual(ThemeMode.light.style, .light)
        XCTAssertEqual(ThemeMode.dark.style, .dark)
        XCTAssertEqual(ThemeMode(key: "automatic"), .computer, "the old Automatic reads as Computer")
        XCTAssertEqual(ThemeMode(key: "dark"), .dark, "the stored value is the raw value")
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

    func testCommandsSubtitle() {
        XCTAssertEqual(CommandsTile.subtitle(nil), "Run commands on the computer", "before the list arrives")
        XCTAssertEqual(CommandsTile.subtitle([]), "No commands yet")
        let lock = RemoteCommand(key: "a", name: "Lock", command: "omarchy-system-lock")
        XCTAssertEqual(CommandsTile.subtitle([lock]), "1 command")
        XCTAssertEqual(CommandsTile.subtitle([lock, lock]), "2 commands")
    }

    func testMediaSubtitle() {
        var player = RemotePlayer(name: "mpv")
        XCTAssertEqual(MediaTile.subtitle(player), "Paused · mpv", "a player without a title shows its name")
        player.title = "Song"
        player.playing = true
        XCTAssertEqual(MediaTile.subtitle(player), "Song")
    }

    func testTransferSizes() {
        XCTAssertEqual(TransferRow.bytes(0), ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
    }

    func testRingToneLoops() throws {
        let player = try AVAudioPlayer(data: RingTone.wav(), fileTypeHint: AVFileType.wav.rawValue)
        XCTAssertEqual(player.duration, 1.2, accuracy: 0.01, "AVAudioPlayer reads the tone that FluxKit builds")
    }
}
