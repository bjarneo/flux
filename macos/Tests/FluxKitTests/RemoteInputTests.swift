import AppKit
import XCTest
@testable import FluxKit

@MainActor
final class RemoteInputTests: XCTestCase {
    private func roundTrip(_ p: Packet) throws -> Packet { try XCTUnwrap(Packet.parse(p.serialize())) }

    func testCapabilitiesMatchTheComputer() {
        let plugin = RemoteInputPlugin()
        XCTAssertEqual(plugin.outgoing, ["kdeconnect.mousepad.request"])
        XCTAssertEqual(plugin.incoming, ["flux.input"])
    }

    func testSupportNeedsTheMousepadCapability() {
        var d = DeviceSnapshot(id: "a", name: "roger", type: "desktop", ip: "", isFlux: true, paired: true, online: true,
                               pairState: .paired, pairKey: "", incoming: [PacketType.fluxTunnel], outgoing: [])
        XCTAssertFalse(RemoteInputPlugin.supported(d))
        d.incoming.append(PacketType.mousepadRequest)
        XCTAssertTrue(RemoteInputPlugin.supported(d))
    }

    func testMotionAndScrollBodies() throws {
        let move = try roundTrip(RemoteInput.move(dx: 3.14159, dy: -2))
        XCTAssertEqual(move.type, PacketType.mousepadRequest)
        XCTAssertEqual(move.double("dx"), 3.14)
        XCTAssertEqual(move.double("dy"), -2)
        XCTAssertFalse(move.has("scroll"))
        XCTAssertEqual(move.body.count, 2)

        let scroll = try roundTrip(RemoteInput.scroll(dx: 0, dy: 12.5))
        XCTAssertEqual(scroll.bool("scroll"), true)
        XCTAssertEqual(scroll.double("dy"), 12.5)
        XCTAssertEqual(RemoteInput.move(dx: .nan, dy: .infinity).double("dx"), 0)
    }

    func testClicksAndHold() {
        XCTAssertEqual(RemoteInput.click(.left).bool("singleclick"), true)
        XCTAssertEqual(RemoteInput.click(.right).bool("rightclick"), true)
        XCTAssertEqual(RemoteInput.click(.middle).bool("middleclick"), true)
        XCTAssertEqual(RemoteInput.hold(true).bool("singlehold"), true)
        XCTAssertEqual(RemoteInput.hold(false).bool("singlerelease"), true)
        XCTAssertEqual(RemoteInput.click(.left).body.count, 1)
    }

    func testKeysUseTheKdeNumbers() throws {
        let enter = try roundTrip(RemoteInput.key(.enter))
        XCTAssertEqual(enter.int("specialKey"), 12)
        XCTAssertEqual(enter.body.count, 1)
        let codes: [RemoteInput.Key: Int] = [.backspace: 1, .tab: 2, .left: 4, .up: 5, .right: 6, .down: 7, .pageUp: 8, .pageDown: 9,
                                             .home: 10, .end: 11, .delete: 13, .escape: 14, .f1: 21, .f12: 32]
        for (k, code) in codes { XCTAssertEqual(k.rawValue, code, "\(k)") }

        let tab = RemoteInput.key(.tab, mods: .init(ctrl: true, shift: true))
        XCTAssertEqual(tab.bool("ctrl"), true)
        XCTAssertEqual(tab.bool("shift"), true)
        XCTAssertFalse(tab.has("alt"))
        XCTAssertFalse(tab.has("super"))
    }

    func testTextWithSuper() throws {
        let p = try roundTrip(RemoteInput.text(" ", mods: .init(meta: true)))
        XCTAssertEqual(p.string("key"), " ")
        XCTAssertEqual(p.bool("super"), true)
        XCTAssertEqual(p.body.count, 2)
    }

    func testMacModifiersMapToTheComputer() {
        let m = RemoteInput.Mods([.control, .option, .shift, .command, .function])
        XCTAssertEqual(m, .init(ctrl: true, alt: true, shift: true, meta: true))
        XCTAssertFalse(RemoteInput.Mods([.capsLock, .function]).any)
        XCTAssertEqual(RemoteInput.Mods(ctrl: true).union(.init(meta: true)), .init(ctrl: true, meta: true))
    }

    func testMacKeyCodes() {
        let codes: [UInt16: RemoteInput.Key] = [51: .backspace, 48: .tab, 123: .left, 126: .up, 124: .right, 125: .down,
                                                116: .pageUp, 121: .pageDown, 115: .home, 119: .end, 36: .enter, 76: .enter,
                                                117: .delete, 53: .escape, 122: .f1, 120: .f2, 99: .f3, 118: .f4, 96: .f5,
                                                97: .f6, 98: .f7, 100: .f8, 101: .f9, 109: .f10, 103: .f11, 111: .f12]
        for (code, k) in codes { XCTAssertEqual(RemoteInput.key(macKeyCode: code), k, "key code \(code)") }
        // A, Space, and Help (Insert) are not special keys.
        XCTAssertNil(RemoteInput.key(macKeyCode: 0))
        XCTAssertNil(RemoteInput.key(macKeyCode: 49))
        XCTAssertNil(RemoteInput.key(macKeyCode: 114))
    }

    func testPresses() {
        func press(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ plain: String?, optionIsAlt: Bool = false, commandIsSuper: Bool = true) -> RemoteInput.Press {
            RemoteInput.press(keyCode: code, flags: flags, plain: plain, optionIsAlt: optionIsAlt, commandIsSuper: commandIsSuper)
        }
        // Letters go through the text input system of macOS.
        XCTAssertEqual(press(0, [], "a"), .compose)
        XCTAssertEqual(press(0, .shift, "A"), .compose)
        // Option types the character of the layout, unless it is Alt.
        XCTAssertEqual(press(19, .option, "2"), .compose)
        XCTAssertEqual(press(3, .option, "f", optionIsAlt: true), .text("f", .init(alt: true)))
        // Special keys keep all modifiers.
        XCTAssertEqual(press(123, [.option, .function, .numericPad], "\u{F702}"), .key(.left, .init(alt: true)))
        XCTAssertEqual(press(48, .shift, "\t"), .key(.tab, .init(shift: true)))
        XCTAssertEqual(press(53, [], "\u{1B}"), .key(.escape, .init()))
        // Shortcuts send the plain text with the modifiers.
        XCTAssertEqual(press(8, .control, "c"), .text("c", .init(ctrl: true)))
        XCTAssertEqual(press(8, [.control, .shift], "C"), .text("C", .init(ctrl: true, shift: true)))
        XCTAssertEqual(press(49, .command, " "), .text(" ", .init(meta: true)))
        XCTAssertEqual(press(17, [.control, .option], "t"), .text("t", .init(ctrl: true, alt: true)))
        // The Mac keeps Command while the pad does not hold the pointer.
        XCTAssertEqual(press(13, .command, "w", commandIsSuper: false), .ignore)
        XCTAssertEqual(press(123, .command, "\u{F702}", commandIsSuper: false), .ignore)
        // A function key without a number, such as F13, stays on the Mac.
        XCTAssertEqual(press(105, .control, "\u{F710}"), .ignore)
    }

    func testMacScrollFollowsTheMac() throws {
        // macOS moves the content up for a negative delta, so the computer scrolls down.
        let down = try XCTUnwrap(RemoteInput.scroll(macDeltaX: 0, macDeltaY: -4.5, precise: true))
        XCTAssertEqual(down.bool("scroll"), true)
        XCTAssertEqual(down.double("dy"), 4.5)
        XCTAssertEqual(down.double("dx"), 0)
        let left = try XCTUnwrap(RemoteInput.scroll(macDeltaX: 2, macDeltaY: 0, precise: true))
        XCTAssertEqual(left.double("dx"), -2)
        // A mouse wheel reports lines.
        let wheel = try XCTUnwrap(RemoteInput.scroll(macDeltaX: 0, macDeltaY: 1, precise: false))
        XCTAssertEqual(wheel.double("dy"), -RemoteInput.lineScroll)
        XCTAssertNil(RemoteInput.scroll(macDeltaX: 0.001, macDeltaY: 0, precise: true))
    }

    func testTypeFieldSendsWholeWords() {
        XCTAssertTrue(RemoteInput.words("hel") == ("", "hel"))
        XCTAssertTrue(RemoteInput.words("hello ") == ("hello ", ""))
        XCTAssertTrue(RemoteInput.words("hello wor") == ("hello ", "wor"))
        XCTAssertTrue(RemoteInput.words("æøå 😀 x") == ("æøå 😀 ", "x"))
        XCTAssertTrue(RemoteInput.words("") == ("", ""))
    }

    func testClickIsAPressThatDoesNotMove() {
        var t = PointerTracker()
        t.leftDown()
        XCTAssertTrue(t.move(dx: 1, dy: 1).isEmpty)
        let up = t.leftUp()
        XCTAssertEqual(up.count, 1)
        XCTAssertEqual(up.first?.bool("singleclick"), true)
        XCTAssertFalse(t.dragging)
        XCTAssertTrue(t.leftUp().isEmpty)
    }

    func testPressThatMovesIsADrag() {
        var t = PointerTracker()
        t.leftDown()
        XCTAssertTrue(t.move(dx: 1, dy: 0).isEmpty)
        let start = t.move(dx: 2, dy: 1)
        XCTAssertTrue(t.dragging)
        XCTAssertEqual(start.count, 2)
        XCTAssertEqual(start[0].bool("singlehold"), true)
        // The motion before the drag starts moves after the press.
        XCTAssertEqual(start[1].double("dx"), 3)
        XCTAssertEqual(start[1].double("dy"), 1)
        let next = t.move(dx: -4, dy: 0)
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].double("dx"), -4)
        let end = t.leftUp()
        XCTAssertEqual(end.count, 1)
        XCTAssertEqual(end[0].bool("singlerelease"), true)
        XCTAssertFalse(t.dragging)
    }

    func testMotionWithoutAPressMoves() {
        var t = PointerTracker()
        let p = t.move(dx: 0.5, dy: -7)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].double("dx"), 0.5)
        XCTAssertEqual(p[0].double("dy"), -7)
        XCTAssertFalse(p[0].has("singlehold"))
    }

    func testCancelReleasesADrag() {
        var t = PointerTracker()
        t.leftDown()
        XCTAssertTrue(t.cancel().isEmpty)
        t.leftDown()
        _ = t.move(dx: 10, dy: 0)
        let end = t.cancel()
        XCTAssertEqual(end.count, 1)
        XCTAssertEqual(end[0].bool("singlerelease"), true)
        // The up after a cancel sends nothing.
        XCTAssertTrue(t.leftUp().isEmpty)
    }

    func testReleaseChord() {
        var c = ReleaseChord()
        XCTAssertFalse(c.flags(.control))
        XCTAssertFalse(c.flags([.control, .option]))
        XCTAssertFalse(c.flags(.option))
        XCTAssertTrue(c.flags([]))
        // Control alone does nothing.
        XCTAssertFalse(c.flags(.control))
        XCTAssertFalse(c.flags([]))
        // A key between makes it a shortcut.
        XCTAssertFalse(c.flags([.control, .option]))
        c.interrupt()
        XCTAssertFalse(c.flags([]))
        // Shift or Command with the chord makes it a shortcut too.
        XCTAssertFalse(c.flags([.control, .option]))
        XCTAssertFalse(c.flags([.control, .option, .shift]))
        XCTAssertFalse(c.flags([]))
        // Caps Lock and Fn do not matter.
        XCTAssertFalse(c.flags([.control, .option, .capsLock]))
        XCTAssertTrue(c.flags(.capsLock))
    }

    func testStateFollowsTheComputer() {
        let model = RemoteInputModel()
        XCTAssertNil(model.enabled["a"])
        XCTAssertFalse(model.isOn("a"))
        model.set("a", true)
        XCTAssertTrue(model.isOn("a"))
        model.set("a", false)
        XCTAssertEqual(model.enabled["a"], false)
        XCTAssertFalse(model.isOn("a"))
    }
}
