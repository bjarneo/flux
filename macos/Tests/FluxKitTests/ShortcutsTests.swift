import XCTest
@testable import FluxKit

@MainActor
final class ShortcutsTests: XCTestCase {
    private let terminal = Shortcut(ref: "315", keys: "SUPER RETURN", description: "Terminal")
    private let browser = Shortcut(ref: "317", keys: "SUPER SHIFT RETURN", description: "Browser")
    private let close = Shortcut(ref: "68", keys: "SUPER W", description: "Close window")

    func testPackets() {
        XCTAssertEqual(DesktopShortcuts.request().type, PacketType.fluxShortcuts)
        XCTAssertEqual(DesktopShortcuts.request().bool("request"), true)
        XCTAssertTrue(DesktopShortcuts.refresh().body.isEmpty)
        XCTAssertEqual(DesktopShortcuts.run(terminal).string("run"), "315")
        XCTAssertEqual(DesktopShortcuts.action(.close).string("action"), "close")
        XCTAssertEqual(DesktopShortcuts.action(.nextWindow).string("action"), "nextWindow")
        XCTAssertEqual(DesktopShortcuts.action(.scratchpad).string("action"), "scratchpad")
        let ws = DesktopShortcuts.workspace(3)
        XCTAssertEqual(ws.string("action"), "workspace")
        XCTAssertEqual(ws.int("workspace"), 3)
        XCTAssertEqual(DesktopShortcuts.moveToWorkspace(10).string("action"), "moveToWorkspace")
        XCTAssertEqual(DesktopShortcuts.moveToWorkspace(10).int("workspace"), 10)
        let swap = DesktopShortcuts.swap(.left)
        XCTAssertEqual(swap.string("action"), "swap")
        XCTAssertEqual(swap.string("direction"), "l")
        XCTAssertEqual(DesktopShortcuts.focus(.up).string("direction"), "u")
        XCTAssertEqual(DesktopShortcuts.focus(.down).string("direction"), "d")
        XCTAssertEqual(DesktopShortcuts.focus(.right).string("direction"), "r")
    }

    func testSuperAndADigitSelectsAWorkspace() throws {
        let sup = RemoteInput.Mods(meta: true)
        XCTAssertEqual(DesktopShortcuts.forDigit("3", mods: sup)?.int("workspace"), 3)
        XCTAssertEqual(DesktopShortcuts.forDigit("3", mods: sup)?.string("action"), "workspace")
        // 0 is workspace 10, as on the keyboard.
        XCTAssertEqual(DesktopShortcuts.forDigit("0", mods: sup)?.int("workspace"), 10)
        let move = try XCTUnwrap(DesktopShortcuts.forDigit("5", mods: .init(shift: true, meta: true)))
        XCTAssertEqual(move.string("action"), "moveToWorkspace")
        XCTAssertEqual(move.int("workspace"), 5)
        XCTAssertNil(DesktopShortcuts.forDigit("a", mods: sup))
        XCTAssertNil(DesktopShortcuts.forDigit("12", mods: sup))
        XCTAssertNil(DesktopShortcuts.forDigit("٣", mods: sup))
        XCTAssertNil(DesktopShortcuts.forDigit("3", mods: .init(ctrl: true)))
        XCTAssertNil(DesktopShortcuts.forDigit("3", mods: .init(alt: true, meta: true)))
    }

    func testNumberRowKeysGiveDigits() {
        XCTAssertEqual(RemoteInput.digit(macKeyCode: 18), 1)
        XCTAssertEqual(RemoteInput.digit(macKeyCode: 23), 5)
        XCTAssertEqual(RemoteInput.digit(macKeyCode: 29), 0)
        XCTAssertNil(RemoteInput.digit(macKeyCode: 0))
        XCTAssertNil(RemoteInput.digit(macKeyCode: 83))
    }

    func testMergeKeepsTheListForAWorkspaceAnswer() {
        let first = DesktopShortcuts.merge(nil, Packet(PacketType.fluxShortcuts, [
            "shortcuts": [["ref": "315", "keys": "SUPER RETURN", "description": "Terminal"], ["ref": "9"]],
            "workspaces": [["id": 1, "windows": 2], ["id": 3, "windows": 0]],
            "active": 1,
        ]))
        XCTAssertTrue(first.loaded)
        XCTAssertEqual(first.shortcuts, [terminal])
        XCTAssertEqual(first.workspaces, [WorkspaceInfo(id: 1, windows: 2), WorkspaceInfo(id: 3, windows: 0)])
        XCTAssertEqual(first.active, 1)

        let next = DesktopShortcuts.merge(first, Packet(PacketType.fluxShortcuts, ["workspaces": [["id": 4, "windows": 1]], "active": 4]))
        XCTAssertEqual(next.shortcuts, [terminal])
        XCTAssertEqual(next.active, 4)

        let failed = DesktopShortcuts.merge(next, Packet(PacketType.fluxShortcuts, ["error": "Remote input is off"]))
        XCTAssertEqual(failed.error, "Remote input is off")
        XCTAssertEqual(failed.shortcuts, [terminal])
        XCTAssertNil(DesktopShortcuts.merge(failed, Packet(PacketType.fluxShortcuts, ["active": 2])).error)
        XCTAssertTrue(DesktopShortcuts.merge(nil, Packet(PacketType.fluxShortcuts, ["error": "no"])).loaded)
    }

    func testPinsKeepTheirOrderAndSkipMissingShortcuts() {
        let all = [close, terminal, browser]
        XCTAssertEqual(DesktopShortcuts.pinned(all, pins: ["Browser", "Music", "Terminal"]), [browser, terminal])
    }

    func testSearchMatchesEachWord() {
        let all = [close, terminal, browser]
        XCTAssertEqual(DesktopShortcuts.search(all, "  "), all)
        XCTAssertEqual(DesktopShortcuts.search(all, "brow"), [browser])
        XCTAssertEqual(DesktopShortcuts.search(all, "shift return"), [browser])
        XCTAssertEqual(DesktopShortcuts.search(all, "super w"), [close, browser])
        XCTAssertEqual(DesktopShortcuts.keysLabel("SUPER SHIFT RETURN"), "super shift return")
    }

    func testPinsToggle() {
        let model = DesktopModel()
        XCTAssertEqual(model.pins, DesktopShortcuts.defaultPins)
        model.togglePin(terminal)
        XCTAssertFalse(model.pins.contains("Terminal"))
        model.togglePin(terminal)
        XCTAssertEqual(model.pins.last, "Terminal")
    }
}
