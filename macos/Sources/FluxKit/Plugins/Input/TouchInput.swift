import CoreGraphics
import Foundation

extension RemoteInput {
    /// The factor from a finger motion to a pointer motion, for a motion of
    /// `distance` points in 1 touch event, as in Flux for Android. A slow
    /// finger moves the pointer precisely, and a fast finger moves it further.
    public static func pointerScale(_ distance: Double) -> Double {
        baseSpeed * (1 + min(maxBoost, abs(distance) / boostDistance))
    }

    private static let baseSpeed = 1.3
    private static let boostDistance = 10.0
    private static let maxBoost = 2.0
}

/// The keys that change the text `old` into `new`: backspaces for the end
/// of `old` that changed, then the new end. The phone keyboard edits a word
/// while it composes it, and a correction replaces the word. A backspace
/// removes 1 code point, as in Flux for Android.
public struct TextEdit: Equatable, Sendable {
    public var backspaces: Int
    public var text: String

    public init(backspaces: Int, text: String) {
        self.backspaces = backspaces
        self.text = text
    }

    public static func between(_ old: String, _ new: String) -> TextEdit {
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let removed = old.dropFirst(prefix)
        return TextEdit(backspaces: removed.unicodeScalars.count, text: String(new.dropFirst(prefix)))
    }
}

/// The type field of the phone: what the computer has, and what each
/// change of the field sends. The keyboard can change the text before the
/// cursor, so each change goes out as backspaces and new text. The app
/// leaves out the text that the keyboard still composes at the end.
public struct TypeBuffer: Sendable {
    /// A field with more characters than this empties after a word, so that it stays short.
    public static let restartLength = 48

    /// The text of the field that the computer has.
    public private(set) var sent = ""

    /// What a change of the field does.
    public enum Change: Equatable, Sendable {
        /// Press Backspace `backspaces` times, then type `text`. With
        /// `clear`, the field empties.
        case edit(backspaces: Int, text: String, clear: Bool)
        /// A modifier is held, so the new text goes as a shortcut, such as
        /// ctrl and c. The field empties.
        case shortcut(String)
    }

    public init() {}

    /// Handles the new text of the field, without the text that the
    /// keyboard composes. `composing` is true while the keyboard composes.
    public mutating func change(_ text: String, composing: Bool, modsHeld: Bool) -> Change {
        let edit = TextEdit.between(sent, text)
        if modsHeld && !edit.text.isEmpty {
            sent = ""
            return .shortcut(edit.text)
        }
        if !composing && text.count > Self.restartLength && text.hasSuffix(" ") {
            sent = ""
            return .edit(backspaces: edit.backspaces, text: edit.text, clear: true)
        }
        sent = text
        return .edit(backspaces: edit.backspaces, text: edit.text, clear: false)
    }

    /// Forgets the text, for example after Enter.
    public mutating func reset() { sent = "" }
}

/// The gestures of the touchpad on a phone, as in Flux for Android. 1
/// finger moves the pointer, and a tap clicks. 2 fingers scroll, and a tap
/// with 2 fingers clicks the right button. A tap with 3 fingers clicks the
/// middle button. A finger that holds still starts a drag, which ends when
/// the finger lifts. Positions and distances are in points.
public struct TouchpadGesture: Sendable {
    public enum Action: Equatable, Sendable {
        case move(dx: Double, dy: Double)
        /// A positive `dy` scrolls down.
        case scroll(dx: Double, dy: Double)
        case click(RemoteInput.Click)
        /// Presses the left button for a drag, or releases it.
        case hold(Bool)
    }

    /// A finger that stays still this long starts a drag.
    public static let holdDelay: TimeInterval = 0.45
    /// The motion after which a touch is no tap.
    public static let slop = 8.0
    /// The scroll units for 1 point of finger motion.
    public static let scrollSpeed = 1.2

    private var active = false
    private var points: [Int: CGPoint] = [:]
    private var holdAt: TimeInterval = 0
    /// The most fingers during the gesture.
    private var fingers = 0
    private var travel = 0.0
    private var holding = false
    /// The motion of 1 finger that did not go out yet.
    private var pendingX = 0.0
    private var pendingY = 0.0

    public init() {}

    /// The time at which a still finger starts a drag, or nil when no drag can start.
    public var holdDeadline: TimeInterval? { waitsForHold ? holdAt : nil }

    private var waitsForHold: Bool { active && !holding && fingers == 1 && travel < Self.slop }

    /// Handles the fingers on the pad after a touch event, by id. No
    /// fingers ends the gesture.
    public mutating func touches(_ now: [Int: CGPoint], at time: TimeInterval) -> [Action] {
        guard active else {
            guard !now.isEmpty else { return [] }
            self = TouchpadGesture()
            active = true
            holdAt = time + Self.holdDelay
            fingers = max(1, now.count)
            points = now
            return []
        }
        var out = holdIfDue(at: time)
        guard !now.isEmpty else { return out + end() }
        fingers = max(fingers, now.count)
        let deltas = now.map { id, p in points[id].map { CGVector(dx: p.x - $0.x, dy: p.y - $0.y) } ?? CGVector() }
        points = now
        if fingers == 1, let d = deltas.first {
            travel += hypot(d.dx, d.dy)
            pendingX += d.dx
            pendingY += d.dy
            if (travel >= Self.slop || holding) && (pendingX != 0 || pendingY != 0) {
                let scale = RemoteInput.pointerScale(hypot(pendingX, pendingY))
                out.append(.move(dx: pendingX * scale, dy: pendingY * scale))
                pendingX = 0
                pendingY = 0
            }
        } else if now.count >= 2 {
            let n = Double(now.count)
            let dx = deltas.reduce(0) { $0 + $1.dx } / n, dy = deltas.reduce(0) { $0 + $1.dy } / n
            travel += hypot(dx, dy)
            // Natural scrolling: the content follows the fingers.
            if travel >= Self.slop && (dx != 0 || dy != 0) {
                out.append(.scroll(dx: -dx * Self.scrollSpeed, dy: -dy * Self.scrollSpeed))
            }
        }
        return out
    }

    /// Starts the drag when the finger stayed still until its time.
    public mutating func holdIfDue(at time: TimeInterval) -> [Action] {
        guard waitsForHold, time >= holdAt else { return [] }
        holding = true
        return [.hold(true)]
    }

    /// Ends the gesture without a click, for example when iOS takes the
    /// touches. A drag releases the button.
    public mutating func cancel() -> [Action] {
        defer { self = TouchpadGesture() }
        return active && holding ? [.hold(false)] : []
    }

    private mutating func end() -> [Action] {
        defer { self = TouchpadGesture() }
        if holding { return [.hold(false)] }
        guard travel < Self.slop else { return [] }
        switch fingers {
        case 1: return [.click(.left)]
        case 2: return [.click(.right)]
        default: return [.click(.middle)]
        }
    }
}
