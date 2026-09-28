import AppKit
import Foundation

/// The packets of kdeconnect.mousepad.request: this Mac moves the pointer,
/// clicks, scrolls, and types on the computer, like KDE Connect. A packet
/// holds 1 action. docs/remote-input.md describes the fields.
public enum RemoteInput {
    /// Special keys, with the numbers that KDE Connect uses.
    public enum Key: Int, CaseIterable, Sendable {
        case backspace = 1, tab = 2, left = 4, up = 5, right = 6, down = 7
        case pageUp = 8, pageDown = 9, home = 10, end = 11, enter = 12, delete = 13, escape = 14
        case f1 = 21, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    }

    /// The modifiers that a key or text holds on the computer.
    public struct Mods: Equatable, Sendable {
        public var ctrl = false
        public var alt = false
        public var shift = false
        /// The super key of the computer. Command on this Mac.
        public var meta = false

        public init(ctrl: Bool = false, alt: Bool = false, shift: Bool = false, meta: Bool = false) {
            self.ctrl = ctrl
            self.alt = alt
            self.shift = shift
            self.meta = meta
        }

        /// The modifiers of a Mac key: Control, Option, Shift, and Command.
        public init(_ flags: NSEvent.ModifierFlags) {
            self.init(ctrl: flags.contains(.control), alt: flags.contains(.option), shift: flags.contains(.shift), meta: flags.contains(.command))
        }

        public var any: Bool { ctrl || alt || shift || meta }

        public func union(_ other: Mods) -> Mods {
            Mods(ctrl: ctrl || other.ctrl, alt: alt || other.alt, shift: shift || other.shift, meta: meta || other.meta)
        }

        var fields: [String: Any?] {
            var body: [String: Any?] = [:]
            if ctrl { body["ctrl"] = true }
            if alt { body["alt"] = true }
            if shift { body["shift"] = true }
            if meta { body["super"] = true }
            return body
        }
    }

    /// The mouse buttons of a click.
    public enum Click: String, Sendable {
        case left = "singleclick", right = "rightclick", middle = "middleclick"
    }

    public static func move(dx: Double, dy: Double) -> Packet {
        Packet(PacketType.mousepadRequest, ["dx": round(dx), "dy": round(dy)])
    }

    /// A positive `dy` scrolls down, and a positive `dx` scrolls right.
    public static func scroll(dx: Double, dy: Double) -> Packet {
        Packet(PacketType.mousepadRequest, ["scroll": true, "dx": round(dx), "dy": round(dy)])
    }

    public static func click(_ c: Click) -> Packet { Packet(PacketType.mousepadRequest, [c.rawValue: true]) }

    /// Presses the left button for a drag, or releases it.
    public static func hold(_ down: Bool) -> Packet {
        Packet(PacketType.mousepadRequest, [down ? "singlehold" : "singlerelease": true])
    }

    public static func text(_ text: String, mods: Mods = Mods()) -> Packet {
        Packet(PacketType.mousepadRequest, mods.fields.merging(["key": text]) { $1 })
    }

    public static func key(_ k: Key, mods: Mods = Mods()) -> Packet {
        Packet(PacketType.mousepadRequest, mods.fields.merging(["specialKey": k.rawValue]) { $1 })
    }

    private static func round(_ v: Double) -> Double { v.isFinite ? (v * 100).rounded() / 100 : 0 }

    // MARK: Scrolling

    /// The scroll distance of 1 line of a mouse wheel, in the units of a
    /// finger on a touchpad.
    static let lineScroll = 15.0

    /// The scroll packet for a scroll event of this Mac, or nil for no
    /// motion. macOS applies the natural scrolling setting to the deltas,
    /// and a positive delta moves the content down or right. So the computer
    /// scrolls the way that this Mac scrolls. A trackpad reports points and
    /// a mouse wheel reports lines.
    public static func scroll(macDeltaX: Double, macDeltaY: Double, precise: Bool) -> Packet? {
        let scale = precise ? 1 : lineScroll
        let dx = round(-macDeltaX * scale), dy = round(-macDeltaY * scale)
        guard dx != 0 || dy != 0 else { return nil }
        return scroll(dx: dx, dy: dy)
    }

    // MARK: Keys

    /// The special key of a Mac virtual key code (the kVK_ values of
    /// Carbon), or nil. Fn with an arrow already arrives as Page Up, Page
    /// Down, Home, or End, and Fn with Delete as forward Delete.
    public static func key(macKeyCode code: UInt16) -> Key? {
        switch code {
        case 51: return .backspace
        case 48: return .tab
        case 123: return .left
        case 126: return .up
        case 124: return .right
        case 125: return .down
        case 116: return .pageUp
        case 121: return .pageDown
        case 115: return .home
        case 119: return .end
        case 36, 76: return .enter
        case 117: return .delete
        case 53: return .escape
        case 122: return .f1
        case 120: return .f2
        case 99: return .f3
        case 118: return .f4
        case 96: return .f5
        case 97: return .f6
        case 98: return .f7
        case 100: return .f8
        case 101: return .f9
        case 109: return .f10
        case 103: return .f11
        case 111: return .f12
        default: return nil
        }
    }

    /// What 1 key press on this Mac sends to the computer.
    public enum Press: Equatable, Sendable {
        /// A special key with the modifiers that the Mac holds.
        case key(Key, Mods)
        /// The text of a shortcut, such as Control-C, with its modifiers.
        case text(String, Mods)
        /// The text input system of macOS makes the text, so that dead keys
        /// and the Option characters of the layout work.
        case compose
        /// The key stays on this Mac.
        case ignore
    }

    /// Maps 1 key press. `plain` is the text of the key without modifiers
    /// except Shift (`charactersIgnoringModifiers`). Option types the
    /// characters of the layout, such as @ on a Nordic keyboard, unless
    /// `optionIsAlt` is on. With a special key, Control, or Command, Option
    /// is always Alt. Command is Super only when `commandIsSuper` is on, else
    /// the Mac keeps its shortcuts.
    public static func press(keyCode: UInt16, flags: NSEvent.ModifierFlags, plain: String?, optionIsAlt: Bool, commandIsSuper: Bool) -> Press {
        let held = Mods(flags)
        if held.meta && !commandIsSuper { return .ignore }
        if let k = key(macKeyCode: keyCode) { return .key(k, held) }
        guard held.ctrl || held.meta || (held.alt && optionIsAlt) else { return .compose }
        let text = printable(plain ?? "")
        return text.isEmpty ? .ignore : .text(text, held)
    }

    /// Removes control characters and the private characters that AppKit
    /// uses for function keys.
    static func printable(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
    }

    // MARK: Type field

    /// Splits the text of the type field into the words to send now, up to
    /// and including the last space, and the start of the word that stays
    /// in the field.
    public static func words(_ text: String) -> (send: String, keep: String) {
        guard let i = text.lastIndex(where: \.isWhitespace) else { return ("", text) }
        let end = text.index(after: i)
        return (String(text[..<end]), String(text[end...]))
    }
}

/// Turns the mouse buttons and motion of the touchpad into packets. A left
/// press that moves becomes a drag: singlehold, the motion, then
/// singlerelease. A left press that does not move is a click.
public struct PointerTracker: Sendable {
    /// The motion, in points, after which a press becomes a drag. A click
    /// on a trackpad moves a little.
    public static let dragSlop = 3.0

    private var pressed = false
    public private(set) var dragging = false
    private var travel = 0.0
    /// The motion of a press before it becomes a drag.
    private var pendingX = 0.0
    private var pendingY = 0.0

    public init() {}

    public mutating func leftDown() {
        self = PointerTracker()
        pressed = true
    }

    public mutating func leftUp() -> [Packet] {
        defer { self = PointerTracker() }
        guard pressed else { return [] }
        return [dragging ? RemoteInput.hold(false) : RemoteInput.click(.left)]
    }

    public mutating func move(dx: Double, dy: Double) -> [Packet] {
        guard pressed, !dragging else { return [RemoteInput.move(dx: dx, dy: dy)] }
        travel += (dx * dx + dy * dy).squareRoot()
        pendingX += dx
        pendingY += dy
        guard travel >= Self.dragSlop else { return [] }
        dragging = true
        defer { pendingX = 0; pendingY = 0 }
        return [RemoteInput.hold(true), RemoteInput.move(dx: pendingX, dy: pendingY)]
    }

    /// Ends a press without a click, for example when the pad gives the
    /// pointer back to this Mac. A drag releases the button.
    public mutating func cancel() -> [Packet] {
        defer { self = PointerTracker() }
        return dragging ? [RemoteInput.hold(false)] : []
    }
}

/// Detects Control and Option that go down together and come up with no
/// other key or click between. The touchpad then gives the pointer back to
/// this Mac. Shortcuts such as Control-Option-T still reach the computer.
public struct ReleaseChord: Sendable {
    private var armed = false

    public init() {}

    /// Handles a change of the modifier keys. It returns true when the chord
    /// is complete.
    public mutating func flags(_ flags: NSEvent.ModifierFlags) -> Bool {
        let control = flags.contains(.control), option = flags.contains(.option)
        let others = !flags.isDisjoint(with: [.shift, .command])
        if others {
            armed = false
        } else if control && option {
            armed = true
        } else if !control && !option {
            defer { armed = false }
            return armed
        }
        return false
    }

    /// A key or a click happened, so the modifiers belong to a shortcut.
    public mutating func interrupt() { armed = false }
}
