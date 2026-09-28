import XCTest
@testable import FluxKit
#if os(iOS)
import UIKit
#endif

final class RemoteInputKeysTests: XCTestCase {
    func testPressRules() {
        typealias Mods = RemoteInput.Mods
        func press(_ key: RemoteInput.Key?, _ mods: Mods, _ plain: String?, optionIsAlt: Bool = false, commandIsSuper: Bool = true) -> RemoteInput.Press {
            RemoteInput.press(special: key, mods: mods, plain: plain, optionIsAlt: optionIsAlt, commandIsSuper: commandIsSuper)
        }
        XCTAssertEqual(press(nil, Mods(), "a"), .compose)
        XCTAssertEqual(press(nil, Mods(alt: true), "2"), .compose, "Option types the character of the layout")
        XCTAssertEqual(press(nil, Mods(alt: true), "f", optionIsAlt: true), .text("f", Mods(alt: true)))
        XCTAssertEqual(press(.left, Mods(alt: true), nil), .key(.left, Mods(alt: true)))
        XCTAssertEqual(press(nil, Mods(ctrl: true), "c"), .text("c", Mods(ctrl: true)))
        XCTAssertEqual(press(nil, Mods(ctrl: true), "\u{F710}"), .ignore, "a key without text stays")
        XCTAssertEqual(press(nil, Mods(meta: true), "w", commandIsSuper: false), .ignore)
        XCTAssertEqual(press(.escape, Mods(meta: true), nil, commandIsSuper: false), .ignore)
    }

    #if os(iOS)
    func testHIDUsagesMatchTheMacKeys() {
        let pairs: [(UIKeyboardHIDUsage, UInt16)] = [
            (.keyboardReturnOrEnter, 36), (.keypadEnter, 76), (.keyboardEscape, 53),
            (.keyboardDeleteOrBackspace, 51), (.keyboardDeleteForward, 117), (.keyboardTab, 48),
            (.keyboardLeftArrow, 123), (.keyboardRightArrow, 124), (.keyboardUpArrow, 126), (.keyboardDownArrow, 125),
            (.keyboardHome, 115), (.keyboardEnd, 119), (.keyboardPageUp, 116), (.keyboardPageDown, 121),
            (.keyboardF1, 122), (.keyboardF2, 120), (.keyboardF3, 99), (.keyboardF4, 118),
            (.keyboardF5, 96), (.keyboardF6, 97), (.keyboardF7, 98), (.keyboardF8, 100),
            (.keyboardF9, 101), (.keyboardF10, 109), (.keyboardF11, 103), (.keyboardF12, 111),
        ]
        for (usage, code) in pairs {
            let key = RemoteInput.key(hidUsage: usage)
            XCTAssertNotNil(key, "HID usage \(usage.rawValue)")
            XCTAssertEqual(key, RemoteInput.key(macKeyCode: code), "HID usage \(usage.rawValue)")
        }
        XCTAssertEqual(Set(pairs.compactMap { RemoteInput.key(hidUsage: $0.0) }), Set(RemoteInput.Key.allCases))
    }

    func testUnmappedHIDUsages() {
        for usage in [UIKeyboardHIDUsage.keyboardA, .keyboardSpacebar, .keyboardInsert, .keyboardF13, .keyboard2] {
            XCTAssertNil(RemoteInput.key(hidUsage: usage), "HID usage \(usage.rawValue)")
        }
    }

    func testModifierFlags() {
        XCTAssertEqual(RemoteInput.Mods(UIKeyModifierFlags()), RemoteInput.Mods())
        XCTAssertEqual(RemoteInput.Mods(.control), RemoteInput.Mods(ctrl: true))
        XCTAssertEqual(RemoteInput.Mods(.alternate), RemoteInput.Mods(alt: true))
        XCTAssertEqual(RemoteInput.Mods(.shift), RemoteInput.Mods(shift: true))
        XCTAssertEqual(RemoteInput.Mods(.command), RemoteInput.Mods(meta: true))
        XCTAssertEqual(RemoteInput.Mods([.control, .alternate, .shift, .command, .alphaShift, .numericPad]),
                       RemoteInput.Mods(ctrl: true, alt: true, shift: true, meta: true))
    }
    #endif
}
