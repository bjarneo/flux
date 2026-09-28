import CoreGraphics
import XCTest
@testable import FluxKit
#if os(iOS)
import UIKit
#endif

final class TouchInputTests: XCTestCase {
    typealias Action = TouchpadGesture.Action

    // MARK: Pointer speed

    func testPointerScaleGrowsWithSpeed() {
        XCTAssertEqual(RemoteInput.pointerScale(0), 1.3, accuracy: 1e-9, "a slow finger moves the pointer precisely")
        XCTAssertEqual(RemoteInput.pointerScale(5), 1.3 * 1.5, accuracy: 1e-9)
        XCTAssertEqual(RemoteInput.pointerScale(-5), 1.3 * 1.5, accuracy: 1e-9)
        XCTAssertEqual(RemoteInput.pointerScale(20), 1.3 * 3, accuracy: 1e-9)
        XCTAssertEqual(RemoteInput.pointerScale(200), 1.3 * 3, accuracy: 1e-9, "the boost stops at 2")
    }

    // MARK: Text edits

    func testTextEditBetween() {
        XCTAssertEqual(TextEdit.between("", "hello"), TextEdit(backspaces: 0, text: "hello"))
        XCTAssertEqual(TextEdit.between("hello", "hello "), TextEdit(backspaces: 0, text: " "))
        XCTAssertEqual(TextEdit.between("teh", "the"), TextEdit(backspaces: 2, text: "he"), "a correction replaces the end that changed")
        XCTAssertEqual(TextEdit.between("abc", "ab"), TextEdit(backspaces: 1, text: ""))
        XCTAssertEqual(TextEdit.between("abc", ""), TextEdit(backspaces: 3, text: ""))
        XCTAssertEqual(TextEdit.between("a👍🏽", "a"), TextEdit(backspaces: 2, text: ""), "a backspace per code point, as on Android")
        XCTAssertEqual(TextEdit.between("café", "cafe"), TextEdit(backspaces: 1, text: "e"))
    }

    func testTypeBufferSendsEachChange() {
        var b = TypeBuffer()
        XCTAssertEqual(b.change("h", composing: false, modsHeld: false), .edit(backspaces: 0, text: "h", clear: false))
        XCTAssertEqual(b.change("hi", composing: false, modsHeld: false), .edit(backspaces: 0, text: "i", clear: false))
        XCTAssertEqual(b.change("hi", composing: false, modsHeld: false), .edit(backspaces: 0, text: "", clear: false), "no change sends nothing")
        XCTAssertEqual(b.change("h", composing: false, modsHeld: false), .edit(backspaces: 1, text: "", clear: false))
        XCTAssertEqual(b.sent, "h")
    }

    func testTypeBufferHeldModifierMakesAShortcut() {
        var b = TypeBuffer()
        _ = b.change("ab", composing: false, modsHeld: false)
        XCTAssertEqual(b.change("abc", composing: false, modsHeld: true), .shortcut("c"))
        XCTAssertEqual(b.sent, "", "the letter of a shortcut does not stay in the field")
        XCTAssertEqual(b.change("x", composing: false, modsHeld: false), .edit(backspaces: 0, text: "x", clear: false))
        var c = TypeBuffer()
        _ = c.change("ab", composing: false, modsHeld: false)
        XCTAssertEqual(c.change("a", composing: false, modsHeld: true), .edit(backspaces: 1, text: "", clear: false),
                       "a backspace with a held modifier is no shortcut")
    }

    func testTypeBufferStartsAgainAfterALongLine() {
        var b = TypeBuffer()
        let long = String(repeating: "word ", count: 9)
        XCTAssertEqual(long.count, 45)
        _ = b.change(long, composing: false, modsHeld: false)
        XCTAssertEqual(b.change(long + "abcd", composing: false, modsHeld: false), .edit(backspaces: 0, text: "abcd", clear: false))
        XCTAssertEqual(b.change(long + "abcd ", composing: true, modsHeld: false), .edit(backspaces: 0, text: " ", clear: false),
                       "the field keeps its text while the keyboard composes")
        XCTAssertEqual(b.change(long + "abcd ", composing: false, modsHeld: false), .edit(backspaces: 0, text: "", clear: true))
        XCTAssertEqual(b.sent, "")
    }

    // MARK: Touchpad

    private func pad(_ steps: [(points: [Int: CGPoint], at: TimeInterval)]) -> [Action] {
        var g = TouchpadGesture()
        return steps.flatMap { g.touches($0.points, at: $0.at) }
    }

    func testTapsClickByFingerCount() {
        XCTAssertEqual(pad([([1: CGPoint(x: 10, y: 10)], 0), ([:], 0.1)]), [.click(.left)])
        XCTAssertEqual(pad([([1: CGPoint(x: 10, y: 10)], 0), ([1: CGPoint(x: 10, y: 10), 2: CGPoint(x: 50, y: 10)], 0.02),
                            ([2: CGPoint(x: 50, y: 10)], 0.1), ([:], 0.11)]), [.click(.right)])
        XCTAssertEqual(pad([([1: .zero, 2: CGPoint(x: 40, y: 0), 3: CGPoint(x: 80, y: 0)], 0), ([:], 0.1)]), [.click(.middle)])
    }

    func testMoveWaitsForTheSlopThenAccelerates() {
        var g = TouchpadGesture()
        XCTAssertEqual(g.touches([1: .zero], at: 0), [])
        XCTAssertEqual(g.touches([1: CGPoint(x: 3, y: 4)], at: 0.01), [], "5 points is under the slop")
        let first = g.touches([1: CGPoint(x: 6, y: 8)], at: 0.02)
        let scale = RemoteInput.pointerScale(10)
        XCTAssertEqual(first, [.move(dx: 6 * scale, dy: 8 * scale)], "the motion before the slop goes out with the first move")
        XCTAssertEqual(g.touches([1: CGPoint(x: 7, y: 8)], at: 0.03), [.move(dx: RemoteInput.pointerScale(1), dy: 0)])
        XCTAssertNil(g.holdDeadline, "a finger that moved does not hold")
        XCTAssertEqual(g.touches([:], at: 0.04), [], "a move does not click")
    }

    func testTwoFingersScrollNaturally() {
        var g = TouchpadGesture()
        _ = g.touches([1: CGPoint(x: 0, y: 100), 2: CGPoint(x: 40, y: 100)], at: 0)
        XCTAssertEqual(g.touches([1: CGPoint(x: 0, y: 95), 2: CGPoint(x: 40, y: 95)], at: 0.01), [], "under the slop")
        XCTAssertEqual(g.touches([1: CGPoint(x: 0, y: 90), 2: CGPoint(x: 40, y: 90)], at: 0.02), [.scroll(dx: 0, dy: 5 * 1.2)],
                       "fingers that move up scroll down")
        XCTAssertEqual(g.touches([1: CGPoint(x: 10, y: 90), 2: CGPoint(x: 40, y: 90)], at: 0.03), [.scroll(dx: -5 * 1.2, dy: 0)],
                       "the motion is the mean of the fingers")
        XCTAssertEqual(g.touches([:], at: 0.04), [])
    }

    func testHoldStillStartsADrag() {
        var g = TouchpadGesture()
        _ = g.touches([1: CGPoint(x: 10, y: 10)], at: 1)
        XCTAssertEqual(g.holdDeadline, 1.45)
        XCTAssertEqual(g.holdIfDue(at: 1.2), [])
        XCTAssertEqual(g.holdIfDue(at: 1.45), [.hold(true)])
        XCTAssertNil(g.holdDeadline)
        XCTAssertEqual(g.touches([1: CGPoint(x: 12, y: 10)], at: 1.5), [.move(dx: 2 * RemoteInput.pointerScale(2), dy: 0)],
                       "a drag moves at once, without the slop")
        XCTAssertEqual(g.touches([:], at: 1.6), [.hold(false)], "the drag ends when the finger lifts, without a click")
    }

    func testLateEventHoldsFirst() {
        var g = TouchpadGesture()
        _ = g.touches([1: .zero], at: 0)
        XCTAssertEqual(g.touches([1: CGPoint(x: 1, y: 0)], at: 0.5), [.hold(true), .move(dx: RemoteInput.pointerScale(1), dy: 0)])
    }

    func testHoldWithoutMotionReleases() {
        var g = TouchpadGesture()
        _ = g.touches([1: .zero], at: 0)
        _ = g.holdIfDue(at: 0.5)
        XCTAssertEqual(g.touches([:], at: 0.6), [.hold(false)])
    }

    func testCancelReleasesADragWithoutAClick() {
        var g = TouchpadGesture()
        _ = g.touches([1: .zero], at: 0)
        XCTAssertEqual(g.cancel(), [], "a canceled tap does not click")
        _ = g.touches([1: .zero], at: 1)
        _ = g.holdIfDue(at: 1.5)
        XCTAssertEqual(g.cancel(), [.hold(false)])
        XCTAssertEqual(g.touches([:], at: 2), [], "the gesture ended")
    }

    func testTwoFingersDoNotHold() {
        var g = TouchpadGesture()
        _ = g.touches([1: .zero, 2: CGPoint(x: 30, y: 0)], at: 0)
        XCTAssertNil(g.holdDeadline)
        XCTAssertEqual(g.holdIfDue(at: 1), [])
    }

    #if os(iOS)
    func testDigitsOfTheHIDNumberRow() {
        XCTAssertEqual(RemoteInput.digit(hidUsage: .keyboard1), 1)
        XCTAssertEqual(RemoteInput.digit(hidUsage: .keyboard9), 9)
        XCTAssertEqual(RemoteInput.digit(hidUsage: .keyboard0), 0)
        XCTAssertNil(RemoteInput.digit(hidUsage: .keyboardA))
        XCTAssertNil(RemoteInput.digit(hidUsage: .keypad1), "the keypad does not switch workspaces, as on the Mac")
    }
    #endif
}
