import FluxKit
import XCTest
@testable import Flux

@MainActor
final class RemoteKeysTests: XCTestCase {
    private var sent: [Packet] = []

    private func keys(workspaceKeys: Bool = true) -> RemoteKeys {
        sent = []
        return RemoteKeys(workspaceKeys: workspaceKeys) { [unowned self] in self.sent.append($0) }
    }

    func testModifiersHoldForOneKey() {
        let k = keys()
        k.mods.ctrl = true
        k.text("c")
        XCTAssertEqual(sent.last?.string("key"), "c")
        XCTAssertEqual(sent.last?.bool("ctrl"), true)
        XCTAssertFalse(k.mods.any, "a modifier holds for the next key only")
        k.text("c")
        XCTAssertNil(sent.last?.bool("ctrl"))
        k.mods.shift = true
        k.key(.tab)
        XCTAssertEqual(sent.last?.int("specialKey"), RemoteInput.Key.tab.rawValue)
        XCTAssertEqual(sent.last?.bool("shift"), true)
        XCTAssertFalse(k.mods.any)
    }

    func testSuperAndADigitSwitchTheWorkspace() {
        let k = keys()
        k.mods.meta = true
        k.text("3")
        XCTAssertEqual(sent.last?.type, PacketType.fluxShortcuts)
        XCTAssertEqual(sent.last?.string("action"), "workspace")
        XCTAssertEqual(sent.last?.int("workspace"), 3)
        k.text("0", held: RemoteInput.Mods(shift: true, meta: true), digit: 0)
        XCTAssertEqual(sent.last?.string("action"), "moveToWorkspace")
        XCTAssertEqual(sent.last?.int("workspace"), 10)
        let old = keys(workspaceKeys: false)
        old.mods.meta = true
        old.text("3")
        XCTAssertEqual(sent.last?.type, PacketType.mousepadRequest, "an older fluxd gets the keys")
        XCTAssertEqual(sent.last?.bool("super"), true)
    }

    func testHardwarePresses() {
        let k = keys()
        XCTAssertTrue(k.press(.key(.escape, RemoteInput.Mods()), characters: "", digit: nil))
        XCTAssertEqual(sent.last?.int("specialKey"), RemoteInput.Key.escape.rawValue)
        XCTAssertTrue(k.press(.text("w", RemoteInput.Mods(meta: true)), characters: "w", digit: nil))
        XCTAssertEqual(sent.last?.string("key"), "w")
        XCTAssertEqual(sent.last?.bool("super"), true)
        XCTAssertTrue(k.press(.text("2", RemoteInput.Mods(meta: true)), characters: "2", digit: 2))
        XCTAssertEqual(sent.last?.int("workspace"), 2)
        XCTAssertTrue(k.press(.compose, characters: "@", digit: nil), "Option types the character of the layout")
        XCTAssertEqual(sent.last?.string("key"), "@")
        let count = sent.count
        XCTAssertFalse(k.press(.compose, characters: "", digit: nil), "a modifier alone stays")
        XCTAssertFalse(k.press(.compose, characters: "\u{1B}", digit: nil))
        XCTAssertFalse(k.press(.ignore, characters: "a", digit: nil))
        XCTAssertEqual(sent.count, count)
    }

    func testBackspaces() {
        let k = keys()
        k.backspaces(3)
        XCTAssertEqual(sent.count, 3)
        XCTAssertTrue(sent.allSatisfy { $0.int("specialKey") == RemoteInput.Key.backspace.rawValue })
        k.backspaces(0)
        XCTAssertEqual(sent.count, 3)
    }
}

@MainActor
final class DesktopViewTests: XCTestCase {
    func testTileSubtitle() {
        XCTAssertEqual(DesktopTile.subtitle(desktop: false, input: true), "Off")
        XCTAssertEqual(DesktopTile.subtitle(desktop: true, input: false), "View only")
        XCTAssertEqual(DesktopTile.subtitle(desktop: true, input: true), "Show and control the screen")
    }

    func testMaxSizeIsAndroids() {
        XCTAssertEqual(DesktopController.maxSize, 1920)
    }
}
